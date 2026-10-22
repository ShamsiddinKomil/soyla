import Foundation

/// Providers that can open their TLS connection before the audio is ready.
public protocol PrewarmableProvider: TranscriptionProvider {
    func prewarm() async
}

extension OpenRouterSTTProvider: PrewarmableProvider {}
extension GoogleAIProvider: PrewarmableProvider {}

/// Builds the transcription provider and cleanup service for a `ProviderKind`. Keys come from `Secrets`
/// (A1 changes where `Secrets` looks; this file only asks it).
public enum ProviderFactory {
    /// OpenRouter → OPENROUTER_API_KEY, Google → GEMINI_API_KEY, custom → CUSTOM_API_KEY (optional: "" = no auth header).
    public static func apiKey(for kind: ProviderKind) throws -> String {
        switch kind {
        case .openRouter: return try Secrets.openRouterKey()
        case .google: return try Secrets.geminiKey()
        case .custom: return Secrets.find(.custom)?.value ?? ""   // optional: "" = no auth header
        case .apple: return ""   // on-device: no key, never throws (the hotkey-down prewarm path relies on it)
        }
    }

    /// `.apple` needs `onDeviceLocale` (`Settings.onDeviceLocale`); without it the call throws rather than guess a
    /// locale (R3: the locale has one source of truth).
    public static func transcriber(_ kind: ProviderKind, apiKey: String, customBaseURL: String? = nil,
                                   onDeviceLocale: String? = nil) throws -> any PrewarmableProvider {
        switch kind {
        case .openRouter: return OpenRouterSTTProvider(apiKey: apiKey)
        case .google: return GoogleAIProvider(apiKey: apiKey)
        case .custom: return OpenRouterSTTProvider(apiKey: apiKey, baseURL: try customBase(customBaseURL))
        case .apple:
            guard let loc = onDeviceLocale, !loc.isEmpty else { throw SoylaError.onDeviceUnavailable(reason: "no-locale") }
            return AppleSpeechProvider(localeID: loc)
        }
    }

    public static func cleaner(_ kind: ProviderKind, apiKey: String, customBaseURL: String? = nil) throws -> CleanupService {
        if kind == .apple { throw SoylaError.notImplemented("the on-device engine has no correction pass") }
        return CleanupService(apiKey: apiKey, provider: kind, baseURL: kind == .custom ? try customBase(customBaseURL) : nil)
    }

    /// Convenience for the pipeline: provider from the user's settings (reads the key).
    public static func transcriber(for s: Settings) throws -> any PrewarmableProvider {
        try transcriber(s.provider, apiKey: apiKey(for: s.provider), customBaseURL: s.customBaseURL,
                        onDeviceLocale: s.onDeviceLocale)
    }

    public static func cleaner(for s: Settings) throws -> CleanupService {
        try cleaner(s.provider, apiKey: apiKey(for: s.provider), customBaseURL: s.customBaseURL)
    }

    static func customBase(_ url: String?) throws -> String {
        guard let u = url?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty, URL(string: u)?.scheme != nil else {
            throw SoylaError.missingAPIKey("custom provider base URL (Settings.customBaseURL)")
        }
        guard URL(string: u, encodingInvalidCharacters: false) != nil, let comps = URLComponents(string: u), let scheme = comps.scheme?.lowercased(), let host = comps.host?.lowercased(),
              !host.isEmpty else {
            throw SoylaError.decode("custom base URL is not a valid URL")
        }
        if scheme != "https" && !(scheme == "http" && isLocalHost(host)) {
            throw SoylaError.decode("custom base URL must use https (http is allowed only for localhost)")
        }
        return u
    }

    /// Plain http is only safe on this machine / the local network name space (R1).
    static func isLocalHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h.hasSuffix(".local")
    }
}
