import Foundation
import os

/// Collects URLSessionTaskMetrics for a single task (passed as the per-task delegate). Also the session delegate of
/// every `OpenRouterHTTP.makeSession` session, so prewarm, model listing and cleanup refuse redirects too.
final class MetricsCollector: NSObject, URLSessionTaskDelegate, Sendable {
    private let metrics = OSAllocatedUnfairLock<URLSessionTaskMetrics?>(initialState: nil)

    /// Refuse every redirect: a 3xx must never carry the Authorization / x-goog-api-key header to another URL (R1).
    /// The 3xx itself comes back as the response and fails as a non-200.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        self.metrics.withLock { $0 = metrics }
    }

    /// Metrics may land slightly after the async call returns; wait briefly.
    func waitForMetrics() async -> URLSessionTaskMetrics? {
        for _ in 0..<20 {
            if let m = current() { return m }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return current()
    }

    private func current() -> URLSessionTaskMetrics? { metrics.withLock { $0 } }

    /// Network split from the last transaction, milliseconds.
    static func net(from metrics: URLSessionTaskMetrics?) -> RunTimeline.Net {
        guard let t = metrics?.transactionMetrics.last else { return RunTimeline.Net() }
        func ms(_ a: Date?, _ b: Date?) -> Double? {
            guard let a, let b else { return nil }
            return ((b.timeIntervalSince(a)) * 10000).rounded() / 10
        }
        let reused = t.isReusedConnection
        return RunTimeline.Net(
            dns: ms(t.domainLookupStartDate, t.domainLookupEndDate) ?? (reused ? 0 : nil),
            connect: ms(t.connectStartDate, t.connectEndDate) ?? (reused ? 0 : nil),
            tls: ms(t.secureConnectionStartDate, t.secureConnectionEndDate) ?? (reused ? 0 : nil),
            ttfb: ms(t.requestEndDate, t.responseStartDate),
            reused: reused)
    }
}

enum OpenRouterHTTP {
    static let base = "https://openrouter.ai/api/v1"

    static func makeSession(timeout: Double = 60) -> URLSession {
        // Ephemeral: the default config has a disk URLCache that persists the Authorization header (found by review R3).
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpMaximumConnectionsPerHost = 1
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout + 5
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c, delegate: MetricsCollector(), delegateQueue: nil)
    }

    /// `baseURL` defaults to OpenRouter; a custom OpenAI-compatible server passes its own. An empty key sends no
    /// Authorization header (local servers often need none). A base URL that doesn't compose throws: never fall back
    /// to another host (that would send the custom server's key to OpenRouter, R1).
    static func request(_ pathAndQuery: String, method: String, apiKey: String, body: Data? = nil, timeout: Double = 60,
                        baseURL: String = base) throws -> URLRequest {
        let b = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: b + pathAndQuery, encodingInvalidCharacters: false), url.host != nil else {
            throw SoylaError.decode("custom base URL is not a valid URL")
        }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        if !apiKey.isEmpty { r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
        }
        return r
    }

    /// First 300 chars of a response body for error messages. `redacting` (the provider's own key) is replaced with
    /// "[key]" before cutting, so a server that echoes the key can't leak even part of it into History or logs.
    static func bodyPrefix(_ data: Data, redacting key: String = "") -> String {
        var s = String(decoding: data.prefix(300 + max(key.utf8.count, 0) + 64), as: UTF8.self)
        if !key.isEmpty { s = s.replacingOccurrences(of: key, with: "[key]") }
        return String(s.prefix(300))
    }
}
