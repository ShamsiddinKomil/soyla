import Foundation
import AppKit

/// "Check for Updates": one GET to the GitHub releases API, nothing else is sent (no auth, no cookies, no cache).
public enum UpdateCheck {
    public static let repo = "ShamsiddinKomil/soyla"

    public struct Release: Equatable, Sendable {
        public let tag: String
        /// The release page (fallback: "Open download page").
        public let url: URL
        /// `Soyla-<tag>.zip` and its `.sha256`; nil when the release has no such assets (then only the page works).
        public var zip: URL? = nil
        public var sha256: URL? = nil
        /// Release notes (markdown as written); the card shows the first lines.
        public var notes: String = ""
    }

    /// Dev and test override (`SOYLA_UPDATE_API=http://127.0.0.1:8765`): a local server stands in for GitHub, so the
    /// whole update can be tried without publishing anything. Assets are then accepted from that host only.
    /// Also read from the defaults suite (`devUpdateAPI`) so a relaunched app (no env) keeps using the test server.
    /// Developer switch only (`DevOverrides`): an installed app always talks to api.github.com.
    public static let apiOverride: URL? = !DevOverrides.enabled ? nil : (DevOverrides.environment["SOYLA_UPDATE_API"]
        ?? UserDefaults(suiteName: Soyla.defaultsSuite)?.string(forKey: "devUpdateAPI")).flatMap(URL.init(string:))

    /// A download URL Soyla may fetch: this repo's release assets on github.com (GitHub then redirects to its CDN),
    /// or the override host in dev.
    static func isAllowedAsset(_ u: URL, repo: String, override: URL?) -> Bool {
        if let o = override { return u.host == o.host && u.port == o.port && (u.scheme == "http" || u.scheme == "https") }
        return u.scheme == "https" && u.host?.lowercased() == "github.com"
            && u.path.lowercased().hasPrefix("/\(repo.lowercased())/releases/download/")
    }
    public enum Failure: Error, Equatable { case notFound, network, badResponse }

    /// Numeric components of "v0.2", "0.2.1-beta.1" → [0, 2, 1]. Pre-release suffix is dropped.
    static func components(_ s: String) -> [Int]? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        if let i = t.firstIndex(where: { $0 == "-" || $0 == "+" }) { t = String(t[..<i]) }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }

    /// True when `tag` is a strictly newer release than `current`. Unparseable input → false.
    /// A pre-release of the same numbers (0.2.0-beta vs 0.2.0) is not newer; a final release beats its own pre-release.
    public static func isNewer(tag: String, current: String) -> Bool {
        guard var a = components(tag), var b = components(current) else { return false }
        while a.count < 3 { a.append(0) }
        while b.count < 3 { b.append(0) }
        if a != b { return a.lexicographicallyPrecedes(b) ? false : true }
        let curPre = current.contains("-"), tagPre = tag.contains("-")
        return curPre && !tagPre
    }

    static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 10
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }

    /// The Download button opens `html_url`, so it must be this repo's release page on github.com (R1).
    public static func parse(_ data: Data, repo: String = UpdateCheck.repo, override: URL? = nil) -> Release? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = o["tag_name"] as? String, let s = o["html_url"] as? String,
              let url = URL(string: s) else { return nil }
        if let ov = override {
            guard url.host == ov.host else { return nil }
        } else {
            guard url.scheme == "https", url.host?.lowercased() == "github.com",
                  url.path.lowercased().hasPrefix("/\(repo.lowercased())/releases/") else { return nil }
        }
        var r = Release(tag: tag, url: url)
        r.notes = o["body"] as? String ?? ""
        let assets = (o["assets"] as? [[String: Any]]) ?? []
        func asset(_ name: String) -> URL? {
            guard let a = assets.first(where: { ($0["name"] as? String) == name }),
                  let u = (a["browser_download_url"] as? String).flatMap(URL.init(string:)),
                  isAllowedAsset(u, repo: repo, override: override) else { return nil }
            return u
        }
        r.zip = asset("Soyla-\(tag).zip")
        r.sha256 = asset("Soyla-\(tag).zip.sha256")
        if r.zip == nil || r.sha256 == nil { r.zip = nil; r.sha256 = nil }
        return r
    }

    public static func fetchLatest(repo: String = UpdateCheck.repo) async -> Result<Release, Failure> {
        let base = apiOverride?.absoluteString ?? "https://api.github.com"
        guard let url = URL(string: "\(base)/repos/\(repo)/releases/latest") else { return .failure(.badResponse) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failure(.badResponse) }
            if http.statusCode == 404 { return .failure(.notFound) }
            guard http.statusCode == 200, let r = parse(data, repo: repo, override: apiOverride) else { return .failure(.badResponse) }
            return .success(r)
        } catch {
            return .failure(.network)
        }
    }

    /// Runs the check. `silent`: no UI at all (launch and daily check); a newer release goes to `onAvailable`, which
    /// shows the Update button. Returns true when the check reached GitHub and got a release (stamps `lastUpdateCheck`).
    /// `language`: the interface language of the alerts (English by default).
    @MainActor @discardableResult
    public static func run(silent: Bool, repo: String = UpdateCheck.repo, language: UILanguage = .en,
                           onAvailable: ((Release) -> Void)? = nil) async -> Bool {
        let d = AppStrings.for(language).d
        let result = await fetchLatest(repo: repo)
        switch result {
        case .success(let rel):
            if isNewer(tag: rel.tag, current: Soyla.version) {
                onAvailable?(rel)
                if !silent { info(d.upAvail(rel.tag), d.upAvailText, ok: d.upOK) }
            } else if !silent {
                info(d.upToDate, d.upToDateText(Soyla.version), ok: d.upOK)
            }
            return true
        case .failure(let f):
            if !silent {
                switch f {
                case .notFound: info(d.upNoneT, d.upNoneText, ok: d.upOK)
                case .network: info(d.upFailT, d.upNetText, ok: d.upOK)
                case .badResponse: info(d.upFailT, d.upBadText, ok: d.upOK)
                }
            }
            return false
        }
    }

    @MainActor private static func info(_ title: String, _ text: String, ok: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        a.addButton(withTitle: ok)
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// Daily auto check (owner, 2026-10-16) is due when enabled and never run or last run more than 24 h ago.
    public static func isDue(enabled: Bool, last: Date?, now: Date = Date()) -> Bool {
        guard enabled else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) > 86_400
    }
}
