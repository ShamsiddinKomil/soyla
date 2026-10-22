import Foundation
import os

/// Monotonic marks for one dictation run. Reference type so every stage can mark into the same object.
public final class RunTimeline: Sendable {
    public enum Mark: String, CaseIterable, Sendable {
        case keyDown = "t_key_down"
        case recStart = "t_rec_start"          // first audio buffer arrived
        case keyUp = "t_key_up"                // zero point for user-perceived latency
        case encodeDone = "t_encode_done"      // encoded + base64
        case requestSent = "t_request_sent"    // URLSession task resumed
        case firstByte = "t_first_byte"        // from URLSessionTaskMetrics (optional)
        case responseReceived = "t_response_received"
        case cleanupSent = "t_cleanup_sent"
        case cleanupDone = "t_cleanup_done"
        case pasted = "t_pasted"
        case clipboardRestored = "t_clipboard_restored"
    }

    /// Network split from URLSessionTaskMetrics, milliseconds. Filled by the provider.
    public struct Net: Codable, Sendable, Equatable {
        public var dns: Double?
        public var connect: Double?
        public var tls: Double?
        public var ttfb: Double?        // request end → response start
        public var reused: Bool?        // connection reused (pre-warm worked)
        public init(dns: Double? = nil, connect: Double? = nil, tls: Double? = nil, ttfb: Double? = nil, reused: Bool? = nil) {
            self.dns = dns; self.connect = connect; self.tls = tls; self.ttfb = ttfb; self.reused = reused
        }
    }

    private struct State: Sendable {
        var marks: [Mark: ContinuousClock.Instant] = [:]
        var net = Net()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let clock = ContinuousClock()
    /// Written by the provider, read by the run record; guarded like the marks (it was an unguarded var before).
    public var net: Net {
        get { state.withLock { $0.net } }
        set { state.withLock { $0.net = newValue } }
    }

    public init() {}

    public func mark(_ m: Mark) {
        let clock = clock
        state.withLock { $0.marks[m] = clock.now }
    }

    public func has(_ m: Mark) -> Bool { state.withLock { $0.marks[m] != nil } }

    /// Milliseconds between two marks, nil if either is missing.
    public func ms(from a: Mark, to b: Mark) -> Double? {
        guard let (ia, ib) = state.withLock({ s -> (ContinuousClock.Instant, ContinuousClock.Instant)? in
            guard let ia = s.marks[a], let ib = s.marks[b] else { return nil }
            return (ia, ib)
        }) else { return nil }
        let d = ia.duration(to: ib)
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// Derived durations for the JSONL row (§2.2). Only present when both marks exist.
    public func toMillis() -> [String: Double] {
        var out: [String: Double] = [:]
        func put(_ k: String, _ a: Mark, _ b: Mark) { if let v = ms(from: a, to: b) { out[k] = (v * 10).rounded() / 10 } }
        put("warmup", .keyDown, .recStart)
        put("recording", .keyDown, .keyUp)
        put("encode", .keyUp, .encodeDone)
        put("request_prep", .encodeDone, .requestSent)
        put("upload_to_first_byte", .requestSent, .firstByte)
        put("stt_request", .requestSent, .responseReceived)
        put("stt_total", .keyUp, .responseReceived)
        put("cleanup", .cleanupSent, .cleanupDone)
        if has(.cleanupDone) { put("paste", .cleanupDone, .pasted) } else { put("paste", .responseReceived, .pasted) }
        put("release_to_paste", .keyUp, .pasted)
        put("clipboard_restore", .pasted, .clipboardRestored)
        return out
    }
}
