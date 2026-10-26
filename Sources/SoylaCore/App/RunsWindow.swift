import SwiftUI
import AppKit

extension RunRecord: Identifiable { public var id: String { runId } }

/// History (F4): every dictation with its status, searchable, with Copy / Play / Retry. Developer mode adds the lab
/// table (timings, phrase tag) and the Compare tab (latest run per model for a phrase).
@MainActor
final class RunsModel: ObservableObject {
    @Published var runs: [RunRecord] = []
    @Published var phrase: Int = 1
    @Published var query = ""
    @Published var showRaw = false
    @Published var developerMode = SettingsStore.shared.current.developerMode
    /// Short confirmation under the list ("Copied", "Retrying…").
    @Published var status: String?
    /// History → Retry (copy-only) through the pipeline; returns false when busy or the audio is gone. Wired by AppDelegate.
    var onRetry: ((RunRecord, String?, String?) -> Bool)?   // record, model, forced language (D26b)
    private var sound: NSSound?
    /// The row whose recording is playing (its button reads Stop).
    @Published var playingId: String?
    private let soundEnd = SoundEnd()
    private var observers: [NSObjectProtocol] = []
    private var statusToken = 0
    /// The status lines in the interface language (read when shown, so a switch applies at once).
    private var d: AppDStrings { AppStrings.for(SettingsStore.shared.current.uiLanguage).d }

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: RunLog.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        observers.append(nc.addObserver(forName: SettingsStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.developerMode = SettingsStore.shared.current.developerMode }
        })
    }

    func reload() {
        runs = ((try? RunLog.readAll()) ?? []).suffix(500).reversed()
        developerMode = SettingsStore.shared.current.developerMode
    }

    var filtered: [RunRecord] { Self.filter(runs, query: query) }

    /// Case- and diacritic-insensitive match on raw and cleaned text.
    static func filter(_ runs: [RunRecord], query: String) -> [RunRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return runs }
        return runs.filter { r in
            [r.rawText, r.cleanText].contains { $0?.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    func text(_ r: RunRecord) -> String? { showRaw ? (r.rawText ?? r.cleanText) : r.finalText }

    /// D26 (c): the cleaned view marks what cleanup changed against the raw transcript.
    func diff(_ r: RunRecord) -> AttributedString? { showRaw ? nil : diffs.styled(r) }
    private var diffs = DiffCache()

    func audioURL(_ r: RunRecord) -> URL? {
        guard let f = r.audio.file else { return nil }
        let u = RecordingStore.resolve(f)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Play, or Stop when this row is already playing.
    func togglePlay(_ r: RunRecord) {
        let wasThis = playingId == r.runId
        sound?.stop(); sound = nil; playingId = nil
        guard !wasThis else { return }
        guard let u = audioURL(r) else { flash(d.fNoRec); return }
        sound = NSSound(contentsOf: u, byReference: true)
        soundEnd.onEnd = { [weak self] in MainActor.assumeIsolated { if self?.playingId == r.runId { self?.playingId = nil } } }
        sound?.delegate = soundEnd
        if sound?.play() == true { playingId = r.runId }
    }

    func retry(_ r: RunRecord, model: String? = nil, language: String? = nil) {
        guard audioURL(r) != nil else { flash(d.fNoRecRetry); return }
        flash(onRetry?(r, model, language) == true ? d.fRetrying : d.fBusy)
    }

    /// D26(b): "Retry as" only where a forced language does something. A retry runs on the current engine (rows store
    /// no engine), so the rule is the chip's: hidden on the free engine.
    nonisolated static func showsRetryAs(_ s: Settings) -> Bool { LanguageSet.applies(s) }

    /// Models offered by "Retry with another model": the curated chat models plus the current one.
    var retryModels: [String] {
        let s = SettingsStore.shared.current
        let base = s.provider == .google ? ["gemini-3.5-flash", "gemini-3.5-flash-lite"] : ModelNames.curated(.openRouter)
        return Array(Set(base + [s.sttModel])).sorted()
    }

    private func flash(_ s: String) {
        statusToken += 1
        let tok = statusToken
        status = s
        Task { [weak self] in
            if await MainDelay.elapsed(2.5), self?.statusToken == tok { self?.status = nil }
        }
    }
}

/// NSSound's delegate (NSObject) for RunsModel: clears the Stop state when playback ends.
@MainActor final class SoundEnd: NSObject, NSSoundDelegate {
    var onEnd: (() -> Void)?
    nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) { Task { @MainActor in self.onEnd?() } }
}

extension RunStatus {
    var label: String { AppStrings.en.d.status(self) }
    var color: Color {
        switch self {
        case .pending: return Ink.lazur
        case .ok: return Ink.ok
        case .failed: return Ink.signal
        case .cancelled: return Ink.text4
        case .interrupted: return Ink.warn
        }
    }
}

/// History: a search well, Cleaned/Raw, then one note card per dictation (`NoteCard`).
struct RunsView: View {
    @ObservedObject var m: RunsModel
    /// The words in the interface language (APP-1 (c) shell, (d) the cards).
    var t: AppStrings = .en
    @State private var tab = 0

    /// V-18: Cleaned/Raw only means something while the correction pass runs and a card has a corrected text.
    private var showsVersions: Bool {
        SettingsStore.shared.current.cleanupLevel != .off && m.runs.contains { $0.cleanText != nil }
    }

    var body: some View {
        let empty = m.runs.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(t.navHistory).font(Ink.Font.appTitle).tracking(-0.74).foregroundStyle(Ink.text).accessibilityAddTraits(.isHeader)
                Text(t.hiSub).font(Ink.Font.appSub).foregroundStyle(Ink.text2).padding(.top, 10)
                if !empty {                                      // V-20: no toolbar for an empty list
                    HStack(spacing: Ink.s3) {
                        TextField(t.hiSearch, text: $m.query, prompt: Text(t.hiSearch)).well().frame(maxWidth: 280)
                            .accessibilityLabel(t.hiSearch)          // F-29
                        if showsVersions {
                            Picker("", selection: $m.showRaw) { Text(t.hiClean).tag(false); Text(t.hiRaw).tag(true) }
                                .pickerStyle(.segmented).fixedSize().help(t.d.hCleanH)
                                .tint(nil)                       // neutral: the one filled control is a primary
                                .accessibilityLabel(t.d.hVersionA)
                        }
                        Spacer()
                        if m.developerMode {
                            Picker("", selection: $tab) { Text("History").tag(0); Text("Lab").tag(1); Text("Compare").tag(2) }
                                .pickerStyle(.segmented).fixedSize().tint(nil)
                                .accessibilityLabel("History view")
                        }
                    }
                    .padding(.top, 28)
                }
            }
            .padding(.horizontal, Ink.appPaneSide).padding(.top, Ink.appPaneTop).padding(.bottom, Ink.s4)
            if empty { emptyState } else if !m.developerMode || tab == 0 { history } else if tab == 1 { labTable } else { compare }
            if !empty {
                Hairline()
                HStack {
                    Text(t.hiKeys).font(Ink.Font.appCaption).foregroundStyle(Ink.text2)
                    Spacer()
                    if let s = m.status { Text(s).font(Ink.Font.caption).foregroundStyle(Ink.text) }
                    Text(t.hiCount(m.filtered.count, m.runs.count)).font(Ink.Font.appCaption).foregroundStyle(Ink.text2).monospacedDigit()
                }
                .padding(.horizontal, Ink.appPaneSide).padding(.vertical, Ink.s3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { m.reload() }
        .onChange(of: showsVersions) { _, shows in if !shows { m.showRaw = false } }
    }

    /// V-20: how to make the first one, not a toolbar around "nothing".
    private var emptyState: some View {
        setupKeyLine(t.hiEmpty, key: SettingsStore.shared.current.hotkey.shortLabel)
            .font(Ink.Font.appSub).foregroundStyle(Ink.text2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Ink.appPaneSide).padding(.top, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var history: some View {
        DocsScrollView {
            LazyVStack(alignment: .leading, spacing: Ink.s3) {
                ForEach(m.filtered) { r in card(r) }
            }
            .padding(.horizontal, Ink.appPaneSide).padding(.bottom, Ink.s4)
        }
        .overlay {
            if m.filtered.isEmpty {
                Text(t.hiNoMatch).font(Ink.Font.appSub).foregroundStyle(Ink.text2)
            }
        }
    }

    /// One dictation as a note card: when · app · length, the text, then Copy / Play / Retry.
    private func card(_ r: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // V-37: the model's name is a developer's detail.
            NoteCard(meta: NoteMeta.line(r, engine: m.developerMode, t: t), status: r.status == .ok ? nil : (r.status.color, t.d.status(r.status)),
                     text: m.text(r), placeholder: Self.placeholder(r, canRetry: m.audioURL(r) != nil, t: t),
                     badge: DiffText.badge(r) ? t.hiClean : nil, badgeHelp: t.d.rsBadgeH,
                     styled: m.diff(r), note: r.cleanupFallback == nil ? nil : t.d.rsSkipped) {
                HStack(spacing: 2) {
                    if let text = m.text(r), !text.isEmpty { CopyButton(text: text, t: t) }
                    if m.audioURL(r) != nil {
                        let playing = m.playingId == r.runId
                        CardButton(icon: playing ? "stop.fill" : "play.fill", label: playing ? t.d.hStop : t.d.hPlay,
                                   tint: playing ? Ink.lazur : Ink.text2, help: playing ? t.d.hStopH : t.d.hPlayH) {
                            m.togglePlay(r)
                        }
                        CardButton(icon: "arrow.clockwise", label: t.d.hRetry, help: t.d.hRetryH) {
                            m.retry(r)
                        }
                        .contextMenu {
                            Section(t.d.hRetryModel) {
                                ForEach(m.retryModels, id: \.self) { id in Button(ModelNames.name(id)) { m.retry(r, model: id) } }
                            }
                            if RunsModel.showsRetryAs(SettingsStore.shared.current) { RetryAsMenu(t: t) { m.retry(r, language: $0) } }
                        }
                    }
                }
            }
            if m.developerMode {
                Text("\(r.model)\(r.phraseId.map { " · phrase \($0)" } ?? "")\(r.error.map { " · " + $0 } ?? "")")
                    .font(Ink.Font.caption).foregroundStyle(Ink.text2).lineLimit(1).padding(.leading, Ink.s4).padding(.top, 4)
            }
        }
    }

    static func placeholder(_ r: RunRecord, canRetry: Bool = true, t: AppStrings = .en) -> String {
        let d = t.d
        switch r.status {
        case .interrupted: return canRetry ? d.phInterruptedRetry(r.audio.durationSec) : d.phInterrupted(r.audio.durationSec)
        case .failed: return canRetry ? d.phFailedRetry : d.phFailed
        case .cancelled: return d.phCancelled         // V-19: the body says what happened, not the status again
        case .pending: return d.phPending
        case .ok: return d.phEmpty
        }
    }

    /// "Today 14:02" / "15 Oct 14:02" in local time, in the interface language.
    static func when(_ ts: String, t: AppStrings = .en) -> String {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = iso.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) else { return String(ts.prefix(16)) }
        let cal = Calendar.current
        let time = String(format: "%02d:%02d", cal.component(.hour, from: date), cal.component(.minute, from: date))
        if cal.isDateInToday(date) { return "\(t.metaToday) \(time)" }
        return "\(t.d.dayMonth(cal.component(.day, from: date), cal.component(.month, from: date))) \(time)"
    }

    // MARK: Developer mode

    private var labTable: some View {
        Table(m.filtered, selection: .constant(nil)) {
            TableColumn("Time") { r in Text(String(r.ts.dropFirst(11).prefix(8))) }.width(70)
            TableColumn("Status") { r in Text(r.status.label).foregroundStyle(r.status.color) }.width(70)
            TableColumn("Src") { r in Text(r.source) }.width(45)
            TableColumn("Ph") { r in Text(r.phraseId.map(String.init) ?? "–") }.width(25)
            TableColumn("Model") { r in Text(r.model.split(separator: "/").last.map(String.init) ?? r.model) }.width(150)
            TableColumn("Fmt") { r in Text(r.audio.format) }.width(35)
            TableColumn("Dur") { r in Text(String(format: "%.1f", r.audio.durationSec)) }.width(35)
            TableColumn("STT ms") { r in Text(r.timelineMs["stt_total"].map { String(format: "%.0f", $0) } ?? "–") }.width(55)
            TableColumn("Total ms") { r in Text(r.timelineMs["release_to_paste"].map { String(format: "%.0f", $0) } ?? "–") }.width(60)
            TableColumn("Text") { r in Text(r.error ?? (m.text(r) ?? "")).lineLimit(1).foregroundStyle(r.error == nil ? Ink.text : Ink.signal) }
        }
        .id(m.runs.count)
    }

    private var compare: some View {
        VStack(alignment: .leading) {
            Picker("Phrase", selection: $m.phrase) { ForEach(1...10, id: \.self) { Text("phrase \($0)").tag($0) } }.frame(width: 200)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(latestPerModel, id: \.runId) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(r.model) · \(r.audio.format) · \(r.timelineMs["stt_total"].map { String(format: "%.0f ms", $0) } ?? "–") · \(r.source)")
                                .font(Ink.Font.caption).foregroundStyle(Ink.text2)
                            Text(r.rawText ?? r.error ?? "").textSelection(.enabled)
                            if let c = r.cleanText { Text("↳ " + c).foregroundStyle(Ink.text2).textSelection(.enabled) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.horizontal, Ink.s8)
    }

    private var latestPerModel: [RunRecord] {
        var seen: [String: RunRecord] = [:]
        for r in m.runs where r.phraseId == m.phrase {   // runs are newest-first
            let k = "\(r.model)|\(r.audio.format)|\(r.cleanup)"
            if seen[k] == nil { seen[k] = r }
        }
        return seen.values.sorted { $0.model < $1.model }
    }
}

/// D26(b): History → Retry's context menu → "Retry as": one language forced, or the saved set. Copies, never pastes.
private struct RetryAsMenu: View {
    let t: AppStrings
    let retry: (String?) -> Void
    var body: some View {
        let ls = LanguageSetStrings.for(SettingsStore.shared.current.uiLanguage)   // like RunsModel.d
        Menu(ls.retryAs) {
            ForEach(LanguageSet.all, id: \.self) { code in
                Button(SpokenLanguage(rawValue: code).flatMap { t.n[$0] } ?? code) { retry(code) }
            }
            Divider()
            Button(ls.mine) { retry(nil) }
        }
    }
}
