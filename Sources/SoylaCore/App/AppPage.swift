import AppKit
import SwiftUI

// APP-1 (c): the shell every Settings page shares at the app scale (docs/DESIGN.md "Main window"): a title (with an
// optional ⓘ), one subtitle line, then sections of 60 pt rows. Captions are 2–4 words; anything longer is an ⓘ.

typealias InfoText = (label: String, paragraphs: [String])

enum AppPageLayout {
    /// D24 / R-14: with legacy scroll bars (a mouse attached) the scroller takes its width from the content, so a page
    /// that scrolls gives that width back from its right margin and its groups end where the other pages' do.
    static func scrollTrailing(side: CGFloat, legacy: Bool, scroller: CGFloat) -> CGFloat { legacy ? side - scroller : side }
    /// The right margin of a page inside its ScrollView, for the scroller style in use now.
    @MainActor static var scrollTrailing: CGFloat {
        scrollTrailing(side: Ink.appPaneSide, legacy: NSScroller.preferredScrollerStyle == .legacy,
                       scroller: NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
    }
}

struct AppPage<Content: View>: View {
    let title: String
    var sub: String? = nil
    var info: InfoText? = nil
    @ViewBuilder var content: Content

    @State private var legacyScrollers = NSScroller.preferredScrollerStyle == .legacy

    /// Unscrolled whenever it fits (also what `--snapshot` can draw); a scroll view only when it doesn't.
    var body: some View {
        ViewThatFits(in: .vertical) {
            inner()
            ScrollView {
                inner(trailing: legacyScrollers ? AppPageLayout.scrollTrailing : Ink.appPaneSide)
            }
        }
        .tint(nil)      // secondary buttons stay neutral; switches and the primary set their own lazur
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            legacyScrollers = NSScroller.preferredScrollerStyle == .legacy
        }
    }

    private func inner(trailing: CGFloat = Ink.appPaneSide) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(Ink.Font.appTitle).tracking(-0.74).foregroundStyle(Ink.text).accessibilityAddTraits(.isHeader)
                if let info { InfoButton(label: AppStrings.current.about(info.label), paragraphs: info.paragraphs, width: 320) }
            }
            if let sub { Text(sub).font(Ink.Font.appSub).foregroundStyle(Ink.text2).padding(.top, 10) }
            VStack(alignment: .leading, spacing: 32) { content }.padding(.top, 36)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Ink.appPaneTop).padding(.leading, Ink.appPaneSide).padding(.trailing, trailing).padding(.bottom, Ink.appPaneBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A section: its title (and ⓘ), one status at most on the right, then a group of rows.
struct AppSection<Content: View>: View {
    var title: String? = nil
    var status: (color: Color, text: String)? = nil
    var info: InfoText? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || status != nil {
                HStack(spacing: 8) {
                    if let title { Text(title).font(Ink.Font.appSection).foregroundStyle(Ink.text).accessibilityAddTraits(.isHeader) }
                    if let info { InfoButton(label: AppStrings.current.about(info.label), paragraphs: info.paragraphs, width: 320, size: SetupScale.type(13)) }
                    Spacer(minLength: 12)
                    if let status { SetupState(color: status.color, text: status.text, font: Ink.Font.appCaption) }
                }
                .frame(minHeight: 28)
            }
            SetupGroup { content }
        }
    }
}

/// One 60 pt row: an optional symbol, the label (with an optional ⓘ) over a short caption, the control on the right.
struct AppRow<Control: View>: View {
    var symbol: String? = nil
    let label: String
    var caption: String? = nil
    var info: InfoText? = nil
    var divider = true
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SetupScale.pt(14)) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: SetupScale.type(17))).foregroundStyle(Ink.text2)
                        .frame(width: SetupScale.pt(24)).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(label).font(Ink.Font.appLabel).foregroundStyle(Ink.text)
                        if let info { InfoButton(label: AppStrings.current.about(info.label), paragraphs: info.paragraphs, width: 320, size: SetupScale.type(12)) }
                    }
                    if let caption { Text(caption).font(Ink.Font.appCaption).foregroundStyle(Ink.text2).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                control.layoutPriority(1)
            }
            .padding(.horizontal, SetupScale.pt(16)).padding(.vertical, SetupScale.pt(10))
            .frame(minHeight: Ink.appRow)
            if divider { Hairline().padding(.leading, SetupScale.pt(16)) }
        }
    }
}

extension View {
    /// Menu pickers and switches in app rows: no label, natural size, lazur tint, the app's control size.
    func appControl() -> some View { labelsHidden().fixedSize().tint(Ink.lazur) }
}
