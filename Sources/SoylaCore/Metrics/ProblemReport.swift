import Foundation

/// BL-06 "Report a problem": the diagnostic block the user sees, edits and sends themselves. Pure: no I/O, no
/// system probes (the caller gathers the facts). It takes the last run only for its status and timing numbers;
/// transcript, audio, error text, API keys and the custom endpoint are never read, so they cannot leak.
public enum ProblemReport {
    public struct Facts: Sendable, Equatable {
        public var appVersion: String
        public var macOS: String
        public var keyboardLayout: String
        public var hotkey: String
        public var inputDevice: String
        /// Provider's label (generic: works for any `ProviderKind`) and the plain model id.
        public var provider: String
        public var model: String
        public var accessibility: Bool
        public var inputMonitoring: Bool
        public var microphone: String
        public var secureInput: Bool
        /// Latest live run, if any. Only `status`, `targetApp`, audio length and `timelineMs` are used.
        public var lastRun: RunRecord?

        public init(appVersion: String, macOS: String, keyboardLayout: String, hotkey: String, inputDevice: String,
                    provider: String, model: String, accessibility: Bool, inputMonitoring: Bool, microphone: String,
                    secureInput: Bool, lastRun: RunRecord?) {
            self.appVersion = appVersion; self.macOS = macOS; self.keyboardLayout = keyboardLayout
            self.hotkey = hotkey; self.inputDevice = inputDevice; self.provider = provider; self.model = model
            self.accessibility = accessibility; self.inputMonitoring = inputMonitoring; self.microphone = microphone
            self.secureInput = secureInput; self.lastRun = lastRun
        }
    }

    public static let repo = UpdateCheck.repo

    /// Removes what must never leave the Mac: the home folder (→ `~`) and anything shaped like an API key.
    public static func redact(_ s: String, home: String = NSHomeDirectory()) -> String {
        var t = s
        if home.count > 1 { t = t.replacingOccurrences(of: home, with: "~") }
        t = t.replacingOccurrences(of: #"/Users/[^/\s]+"#, with: "~", options: .regularExpression)
        // sk-…, AIza…, and any long unbroken token of key characters.
        for pattern in [#"sk-[A-Za-z0-9_\-]*"#, #"AIza[A-Za-z0-9_\-]*"#, #"[A-Za-z0-9_\-]{32,}"#] {
            t = t.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return t
    }

    private static func ms(_ r: RunRecord, _ key: String) -> String {
        r.timelineMs[key].map { String(format: "%.0f ms", $0) } ?? "n/a"
    }

    /// The editable text shown in the sheet. Every line is a fact about the setup, none is user content.
    public static func build(_ f: Facts, home: String = NSHomeDirectory()) -> String {
        var lines = [
            "Soyla version: \(f.appVersion)",
            "macOS: \(f.macOS)",
            "Keyboard layout: \(f.keyboardLayout)",
            "Hotkey: \(f.hotkey)",
            "Input device: \(f.inputDevice)",
            "Provider: \(f.provider)",
            "Model: \(f.model)",
            "Permissions: Accessibility \(f.accessibility ? "on" : "off"), "
                + "Input Monitoring \(f.inputMonitoring ? "on" : "off"), Microphone \(f.microphone)",
            "Secure Input: \(f.secureInput ? "on" : "off")",
        ]
        if let r = f.lastRun {
            lines.append("Last run: \(r.status.rawValue), target app: \(r.targetApp ?? "n/a"), "
                         + String(format: "audio %.1f s", r.audio.durationSec))
            lines.append("Last run timing: speech to text \(ms(r, "stt_total")), release to paste \(ms(r, "release_to_paste")), "
                         + "encode \(ms(r, "encode"))")
        } else {
            lines.append("Last run: none yet")
        }
        return redact(lines.joined(separator: "\n"), home: home)
    }

    /// The prefilled new-issue address. Opening it sends nothing: the user reviews and submits on GitHub.
    /// The form template ignores `body` but fills fields by id, so the short facts go to their own fields and the
    /// whole block goes to `log` (and `body`, for the non-form fallback). Kept under GitHub's ~8 KB URL limit by
    /// truncating the block.
    public static func issueURL(body: String, facts: Facts, repo: String = ProblemReport.repo, maxLength: Int = 7500) -> URL? {
        func make(_ block: String) -> URL? {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let pairs: [(String, String)] = [
                ("template", "bug.yml"), ("version", redact(facts.appVersion)), ("macos", redact(facts.macOS)),
                ("hotkey", redact(facts.hotkey)), ("layout", redact(facts.keyboardLayout)),
                ("mic", redact(facts.inputDevice)), ("log", block), ("body", block),
            ]
            // Everything but unreserved characters is percent-encoded, so "&", "+" and "=" stay inside their value.
            let query = pairs.map { $0.0 + "=" + ($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }
                .joined(separator: "&")
            return URL(string: "https://github.com/\(repo)/issues/new?\(query)")
        }
        // The user may have edited the block: redact again so nothing key-shaped or home-pathed goes in the URL.
        var block = redact(body)
        while let url = make(block), url.absoluteString.count > maxLength, block.count > 1 {
            block = String(block.prefix(Int(Double(block.count) * 0.8))) + "\n[truncated]"
            block = block.replacingOccurrences(of: "\n[truncated]\n[truncated]", with: "\n[truncated]")
            if block.count < 20 { break }
        }
        return make(block)
    }
}
