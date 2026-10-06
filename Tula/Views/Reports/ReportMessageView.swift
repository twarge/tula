import ERPNextKit
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// A report's `message` rendered as Desk shows it above the grid: the
/// heading larger and bold, body lines in the primary color, `text-muted`
/// notes secondary, the `text-warning` review list in amber, and links
/// live — Desk form and report links open the native screen, others the
/// browser.
struct ReportMessageView: View {
    let message: HTMLRichText

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction(handler: open))
    }

    @ViewBuilder
    private func blockView(_ block: HTMLRichText.Block) -> some View {
        switch block {
        case .heading(let level, let runs):
            Text(attributed(runs))
                .font(Self.headingFont(level))
                .fontWeight(.bold)
                .padding(.bottom, 6)
        case .paragraph(let runs):
            Text(attributed(runs))
        case .listItem(let marker, let depth, let runs):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // Continuation lines keep the marker's width, unshown.
                Text(marker ?? "•")
                    .foregroundStyle(Self.color(for: runs.first?.tone) ?? .primary)
                    .opacity(marker == nil ? 0 : 1)
                Text(attributed(runs))
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func attributed(_ runs: [HTMLRichText.Run]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.bold { intent.insert(.stronglyEmphasized) }
            if run.italic { intent.insert(.emphasized) }
            if run.code { intent.insert(.code) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if let color = Self.color(for: run.tone) {
                piece.swiftUI.foregroundColor = color
            }
            if let href = run.link, let url = resolve(href) {
                piece.link = url
            }
            result += piece
        }
        return result
    }

    /// Relative hrefs (`/app/...`) resolve against the connected site; in
    /// demo mode they stay relative and only native targets open.
    private func resolve(_ href: String) -> URL? {
        guard let url = URL(string: href) else { return nil }
        guard url.scheme == nil, let base = model.webBaseURL else { return url }
        return URL(string: href, relativeTo: base)?.absoluteURL ?? url
    }

    private func open(_ url: URL) -> OpenURLAction.Result {
        switch DeskURL.target(of: url, base: model.webBaseURL) {
        case .queryReport(let name):
            model.pendingPush = .queryReport(name: name, extra: [:])
            return .handled
        case .document(let slug, let name):
            Task {
                let names = await model.cache.doctypeNames(using: model.dataSource)
                let doctype =
                    names.first { DeskURL.slug($0) == slug }
                    ?? slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined(separator: " ")
                model.pendingPush = .document(doctype: doctype, name: name)
            }
            return .handled
        case nil:
            return url.scheme == nil ? .discarded : .systemAction
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3, 4: return .title3
        default: return .headline
        }
    }

    /// Bootstrap's `text-*` classes in native colors.
    private static func color(for tone: HTMLRichText.Tone?) -> Color? {
        switch tone {
        case .muted: return .secondary
        case .warning: return .deskWarning
        case .danger: return .red
        case .success: return .green
        case .primary: return .blue
        case nil: return nil
        }
    }
}

extension Color {
    /// Desk's `text-warning`: amber on light backgrounds, yellow on dark.
    fileprivate static var deskWarning: Color {
        #if os(macOS)
            Color(
                nsColor: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? .systemYellow : .systemOrange
                })
        #else
            Color(
                uiColor: UIColor { traits in
                    traits.userInterfaceStyle == .dark ? .systemYellow : .systemOrange
                })
        #endif
    }
}
