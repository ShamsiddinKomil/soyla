import Foundation
import Observation
import Speech

/// FE-3: the free engine's model state for the chosen locale. Read at launch, when the Engine page opens and at
/// hotkey-down (FE-4/FE-5 wire those calls); never polled. The Speech reads run off the main actor (`OnDeviceProbe`).
/// Never touches Apple's server recognition (V1): it only reads status, reserves, downloads and asks permission.
@MainActor @Observable
public final class OnDeviceModels {
    /// The app-wide instance: AppDelegate drives it, the Engine page, onboarding and Home read it.
    public static let shared = OnDeviceModels()
    /// nil until the first `refresh`.
    public private(set) var state: OnDeviceModelState?
    /// The last reserve/download failed (error class only, never shown verbatim). Cleared by the next attempt.
    public private(set) var lastFailure: String?
    /// Soyla's own running download (0...1), fed into the reducer while `AssetInventory` still says `supported`.
    private var progress: Double?
    private var installing = false
    private let defaults: UserDefaults
    private let osMajor: Int

    public init(defaults: UserDefaults = UserDefaults(suiteName: Soyla.defaultsSuite) ?? .standard,
                osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
        self.defaults = defaults
        self.osMajor = osMajor
    }

    /// Re-reads the real status (cheap; off main) and recomputes `state`.
    public func refresh(locale: String) async {
        let snap = await OnDeviceProbe.read(locale: locale)
        apply(snap)
    }

    /// macOS 26: reserve the locale (releasing only an older Soyla reservation if the slots are full), then download
    /// the model if it is still not installed, publishing progress. FE-0: inside the app, English is `supported`
    /// until reserved and then usable at once, so most calls end after the reserve. macOS 14–15: just a refresh
    /// (there is nothing to download; permission is `requestPermission`).
    public func ensureReady(locale: String) async {
        guard #available(macOS 26.0, *) else { await refresh(locale: locale); return }
        guard !installing else { return }
        installing = true
        defer { installing = false; progress = nil }
        lastFailure = nil
        do {
            let reserved = await OnDeviceProbe.reservedLocales()
            let owned = OnDeviceReservations.load(defaults)
            let plan = OnDeviceReservations.plan(wanted: locale, reserved: reserved, owned: owned,
                                                 max: OnDeviceProbe.maximumReservedLocales())
            switch plan {
            case .alreadyReserved:
                break
            case .full:
                state = .unavailable(.reservationsFull)
                return
            case .reserve, .releaseThenReserve:
                var released: String?
                if case .releaseThenReserve(let old) = plan, await OnDeviceProbe.release(old) { released = old }
                try await OnDeviceProbe.reserve(locale)
                OnDeviceReservations.save(OnDeviceReservations.owned(owned, released: released, reserved: locale), to: defaults)
            }
            await refresh(locale: locale)
            guard state == .needsDownload else { return }
            guard let request = try await OnDeviceProbe.installationRequest(locale: locale) else {
                await refresh(locale: locale)   // nil = nothing left to install
                return
            }
            progress = 0
            state = .downloading(0)
            try await download(request)
        } catch is CancellationError {
            // The caller went away; the next refresh re-reads the real status (no stuck "Downloading").
        } catch {
            lastFailure = String(describing: type(of: error))
        }
        progress = nil
        await refresh(locale: locale)
    }

    /// Progress publishing. `AssetInstallationRequest.progress` is a `Foundation.Progress`; KVO would need an
    /// NSKeyValueObservation whose callback runs on an arbitrary thread and must hop to the main actor. Sampling
    /// `fractionCompleted` every 250 ms instead keeps everything async/await, and the sampler exists only while
    /// `downloadAndInstall()` runs (an unstructured task cancelled the moment the download returns or throws), so nothing is
    /// polled at rest.
    @available(macOS 26.0, *)
    private func download(_ request: AssetInstallationRequest) async throws {
        let tracker = request.progress
        let sampler = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.publish(tracker.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { sampler.cancel() }
        // Nonisolated async: runs off main. Cancelling the caller cancels it (structured), and the defer stops the sampler.
        try await request.downloadAndInstall()
    }

    private func publish(_ fraction: Double) {
        progress = fraction
        if case .downloading = state { state = .downloading(min(1, max(0, fraction))) }
    }

    /// macOS 14–15: shows the system Speech Recognition prompt the first time (later calls return the saved answer),
    /// then refreshes.
    public func requestPermission(locale: String) async {
        _ = await OnDeviceProbe.requestSpeechAuthorization()
        await refresh(locale: locale)
    }

    private func apply(_ s: OnDeviceProbe.Snapshot) {
        state = OnDeviceAvailability.state(osMajor: osMajor, asset: s.asset, legacyOnDevice: s.legacyOnDevice,
                                           legacyAuth: s.legacyAuth, progress: progress)
    }
}

/// The impure Speech reads, mirrored into the reducer's plain enums. Every member is nonisolated, so the async ones
/// run on the global executor (off main); the synchronous ones are cheap enough for the permission poller.
/// API surface checked against the CLT SDK 26.5 Speech.swiftinterface and SFSpeechRecognizer.h.
public enum OnDeviceProbe {
    public struct Snapshot: Equatable, Sendable {
        public var asset: OnDeviceAssetStatus?
        public var legacyOnDevice: Bool
        public var legacyAuth: SpeechAuthorization
    }

    static func read(locale: String) async -> Snapshot {
        if #available(macOS 26.0, *) {
            return Snapshot(asset: await assetStatus(locale: locale), legacyOnDevice: false, legacyAuth: speechAuthorization())
        }
        return Snapshot(asset: nil, legacyOnDevice: legacyOnDevice(locale: locale), legacyAuth: speechAuthorization())
    }

    /// macOS 14–15: does the legacy recogniser have an on-device model for this locale? Never used to recognise here.
    public static func legacyOnDevice(locale: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: locale))?.supportsOnDeviceRecognition ?? false
    }

    public static func speechAuthorization() -> SpeechAuthorization {
        mirror(SFSpeechRecognizer.authorizationStatus())
    }

    /// The handler runs on an arbitrary queue. The closure is explicitly `@Sendable` and this function is
    /// nonisolated, so Swift 6 does not infer main-actor isolation for it (that would trap when the handler fires
    /// off main). Resumed exactly once.
    public static func requestSpeechAuthorization() async -> SpeechAuthorization {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable s in c.resume(returning: s) }
        }
        return mirror(status)
    }

    static func mirror(_ s: SFSpeechRecognizerAuthorizationStatus) -> SpeechAuthorization {
        switch s {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    @available(macOS 26.0, *)
    static func transcriber(_ locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, preset: .shortDictation)
    }

    @available(macOS 26.0, *)
    static func assetStatus(locale: String) async -> OnDeviceAssetStatus {
        guard let loc = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            return .unsupported
        }
        switch await AssetInventory.status(forModules: [transcriber(loc)]) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .supported
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    @available(macOS 26.0, *)
    static func maximumReservedLocales() -> Int { AssetInventory.maximumReservedLocales }

    @available(macOS 26.0, *)
    static func reservedLocales() async -> [String] { await AssetInventory.reservedLocales.map(\.identifier) }

    @available(macOS 26.0, *)
    static func reserve(_ locale: String) async throws {
        try await AssetInventory.reserve(locale: Locale(identifier: locale))
    }

    @available(macOS 26.0, *)
    static func release(_ locale: String) async -> Bool {
        await AssetInventory.release(reservedLocale: Locale(identifier: locale))
    }

    @available(macOS 26.0, *)
    static func installationRequest(locale: String) async throws -> AssetInstallationRequest? {
        let loc = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) ?? Locale(identifier: locale)
        return try await AssetInventory.assetInstallationRequest(supporting: [transcriber(loc)])
    }
}
