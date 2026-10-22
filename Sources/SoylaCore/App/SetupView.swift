import SwiftUI

// OB-2: the setup window's content. Left: the lapis stage (SetupStage.swift). Right: one question (SetupPanes.swift).
// Built from DesignKit tokens and native controls; copy from SetupStrings.

/// Markdown `**bold**` with line breaks kept.
func setupText(_ s: String) -> Text {
    let a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    return Text(a)
}

/// `s` with `{key}` drawn as the hotkey ("🌐 fn" as a symbol, never an emoji).
func setupKeyLine(_ s: String, key: String) -> Text {
    guard let p = SetupStrings.around(s) else { return Text(s) }
    let keyText = key == "fn"
        ? Text(Image(systemName: "globe")) + Text(" fn").font(.system(size: SetupScale.type(13), weight: .medium, design: .rounded))
        : Text(key).font(.system(size: SetupScale.type(13), weight: .medium, design: .rounded))
    return Text(p.before) + keyText.foregroundStyle(Ink.text) + Text(p.after)
}

struct SetupView: View {
    let model: SetupModel
    @ObservedObject var panel: PanelModel
    @FocusState private var focus: SetupFocus?

    var body: some View {
        Group {
            if model.flow.step == .welcome {
                // v6: the full window is lapis, no rail, no stage split; the globe menu stays live top-right.
                ZStack(alignment: .topTrailing) {
                    WelcomeView(model: model, focus: $focus)
                    languageMenu(onLapis: true).padding(.top, SetupScale.pt(14)).padding(.trailing, SetupScale.pt(18))
                }
            } else {
                steps
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.paper)
        .ignoresSafeArea()
        .onChange(of: model.focusToken) { _, _ in moveFocus() }
        .onChange(of: panel.phase) { old, new in
            model.pipelinePhaseChanged(from: old, to: new, softFailure: panel.failure?.kind == .soft, failure: panel.failure)
        }
        .onPreferenceChange(SetupContentHeight.self) { h in
            MainActor.assumeIsolated { model.reportContentHeight(SetupScale.pt(72) + h + SetupScale.pt(20) + 32 + SetupScale.pt(32)) }
        }
    }

    private var steps: some View {
        HStack(spacing: 0) {
            SetupStage(model: model, panel: panel)
                .frame(width: SetupFlow.stageWidth)
                .frame(maxHeight: .infinity)
            ZStack(alignment: .topTrailing) {
                // The pane swaps at once; only the window height animates (a crossfade during the resize re-laid
                // out both panes every frame and made Back lag >1 s in the review).
                SetupPane(model: model, focus: $focus)
                    .id(model.flow.step)
                languageMenu(onLapis: false).padding(.top, SetupScale.pt(14)).padding(.trailing, SetupScale.pt(18))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// After a step change the target view may not exist yet; give SwiftUI a beat before focusing it.
    private func moveFocus() {
        let target = model.focusRequest
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            // Leave the practice field first: with keyboard navigation off a button can't take focus, and the
            // caret should not stay in the field after a dictation landed.
            if target == .primary { focus = nil; NSApp.keyWindow?.makeFirstResponder(nil) }
            focus = target == .title ? nil : target
        }
    }

    /// `onLapis`: light-on-lapis on Welcome; quiet grey on the panes.
    private func languageMenu(onLapis: Bool) -> some View {
        Menu {
            ForEach(UILanguage.allCases, id: \.self) { l in
                Button { model.setUILanguage(l) } label: {
                    if l == model.flow.uiLanguage { Label(l.nativeName, systemImage: "checkmark") } else { Text(l.nativeName) }
                }
            }
        } label: {
            // Quiet and grey like a borderless popup (v5), not an accent-tinted button.
            HStack(spacing: 4) {
                Image(systemName: "globe")
                Text(model.flow.uiLanguage.nativeName)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: SetupScale.type(8), weight: .medium))
            }
            .font(.system(size: SetupScale.type(12), weight: .regular))
            .foregroundStyle(onLapis ? Ink.onLapis2 : Ink.text2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(onLapis ? Ink.onLapis2 : Ink.text2)
        .fixedSize()
        .accessibilityLabel(model.strings.uiAria)
        .accessibilityValue(model.flow.uiLanguage.nativeName)
    }
}

struct SetupContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One shape for every pane: title (+ ⓘ), one short line, the controls, then the buttons pinned to the bottom.
struct PaneScaffold<Content: View, Footer: View>: View {
    let title: String
    var info: (label: String, paragraphs: [String])? = nil
    var sub: Text? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: SetupScale.pt(10)) {
                    Text(title).font(Ink.Font.setupTitle).tracking(-0.67).foregroundStyle(Ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let info { InfoButton(label: info.label, paragraphs: info.paragraphs) }
                }
                .padding(.trailing, SetupScale.pt(64))
                if let sub {
                    sub.font(Ink.Font.setupSub).foregroundStyle(Ink.text2).padding(.top, SetupScale.pt(10))
                        .fixedSize(horizontal: false, vertical: true)
                }
                content.padding(.top, SetupScale.pt(32))
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in Color.clear.preference(key: SetupContentHeight.self, value: g.size.height) })
            Spacer(minLength: 20)
            HStack(spacing: SetupScale.pt(10)) { footer }
                .controlSize(.large)
        }
        .padding(.top, SetupScale.pt(72)).padding(.horizontal, SetupScale.pt(64)).padding(.bottom, SetupScale.pt(32))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A sheet-coloured group with hairlines between rows (setup's row scale).
struct SetupGroup<Content: View>: View {
    @ViewBuilder var content: Content
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Ink.rCard, style: .continuous) }
    var body: some View {
        VStack(spacing: 0) { content }
            .background(shape.fill(Ink.sheet))
            .overlay(shape.strokeBorder(Ink.hairline))
            .clipShape(shape)
    }
}

/// One 54 pt row: optional bare symbol, label 14/500 over a 12.5 caption, the control on the right.
struct SetupRow<Control: View>: View {
    var symbol: String? = nil
    let label: String
    var caption: String? = nil
    var divider = true
    @ViewBuilder var control: Control
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SetupScale.pt(14)) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: SetupScale.type(17))).foregroundStyle(Ink.text2).frame(width: SetupScale.pt(24)).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(Ink.Font.setupLabel).foregroundStyle(Ink.text)
                    if let caption { Text(caption).font(Ink.Font.setupCaption).foregroundStyle(Ink.text2) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                control
            }
            .padding(.horizontal, SetupScale.pt(16)).padding(.vertical, SetupScale.pt(10))
            .frame(minHeight: Ink.setupRow)
            if divider { Hairline().padding(.leading, SetupScale.pt(16)) }
        }
    }
}

/// A dot and a word, in setup's caption size.
struct SetupStatus: View {
    var color: Color? = Ink.text3
    var spinning = false
    let text: String
    var body: some View {
        HStack(alignment: .center, spacing: SetupScale.pt(8)) {
            if spinning { ProgressView().controlSize(.small).frame(width: SetupScale.pt(12), height: SetupScale.pt(12)) }
            else if let color { Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true) }
            Text(text).font(Ink.Font.setupCaption).foregroundStyle(Ink.text2).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "● Allowed" on the right of a row.
struct SetupState: View {
    var color: Color = Ink.ok
    let text: String
    /// The main window's rows use `Ink.Font.appCaption` (14).
    var font: Font = .system(size: SetupScale.type(12))
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).font(font).foregroundStyle(Ink.text2).lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
