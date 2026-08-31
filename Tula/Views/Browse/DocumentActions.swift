import ERPNextKit
import SwiftUI

/// Read-only document actions, mirroring the safe subset of Desk's "…" menu.
///
/// Desk's View entries come from per-DocType client scripts (not metadata),
/// so the useful accounting ones are synthesized from ERPNext conventions:
/// party DocTypes get their ledger and receivable/payable reports, GL-posting
/// vouchers get their ledger. Everything that writes (Create/Email/Duplicate/
/// Rename/Delete/…) is deliberately absent.
struct DocumentAction: Identifiable {
    enum Kind {
        case route(Route)
        case copy(String)
        /// External hand-off (the Email action's mailto: with a Desk link —
        /// no server write involved).
        case url(URL)
    }

    var label: String
    var systemImage: String
    var kind: Kind

    var id: String { label }

    static func actions(doctype: String, name: String, webBase: URL?) -> [DocumentAction] {
        var actions: [DocumentAction] = []

        let partyReports: [String: String] = [
            "Customer": "Accounts Receivable",
            "Supplier": "Accounts Payable",
        ]
        let partyDoctypes = ["Customer", "Supplier", "Employee", "Shareholder"]
        let voucherDoctypes = [
            "Sales Invoice", "Purchase Invoice", "Journal Entry", "Payment Entry",
            "Delivery Note", "Purchase Receipt", "Stock Entry",
        ]

        if partyDoctypes.contains(doctype) {
            actions.append(
                DocumentAction(
                    label: "Accounting Ledger",
                    systemImage: "book.closed",
                    kind: .route(
                        .queryReport(
                            name: "General Ledger",
                            extra: [
                                "party_type": .string(doctype),
                                "party": .string(name),
                            ]))))
            if let report = partyReports[doctype] {
                actions.append(
                    DocumentAction(
                        label: report,
                        systemImage: "creditcard",
                        kind: .route(
                            .queryReport(
                                name: report,
                                extra: [doctype.lowercased(): .string(name)]))))
            }
        } else if voucherDoctypes.contains(doctype) {
            actions.append(
                DocumentAction(
                    label: "Accounting Ledger",
                    systemImage: "book.closed",
                    kind: .route(
                        .queryReport(
                            name: "General Ledger",
                            extra: ["voucher_no": .string(name)]))))
        }

        if let webBase {
            actions.append(
                DocumentAction(
                    label: "Copy Link",
                    systemImage: "link",
                    kind: .copy(
                        DeskURL.document(base: webBase, doctype: doctype, name: name)
                            .absoluteString)))
            // Desk's Email action, as the write map specifies it: a mailto:
            // hand-off carrying the Desk link — no server write.
            var mail = URLComponents()
            mail.scheme = "mailto"
            mail.queryItems = [
                URLQueryItem(name: "subject", value: "\(doctype) \(name)"),
                URLQueryItem(
                    name: "body",
                    value: DeskURL.document(base: webBase, doctype: doctype, name: name)
                        .absoluteString),
            ]
            if let mailURL = mail.url {
                actions.append(
                    DocumentAction(
                        label: "Email…", systemImage: "envelope", kind: .url(mailURL)))
            }
        }
        actions.append(
            DocumentAction(label: "Copy ID", systemImage: "doc.on.doc", kind: .copy(name)))

        return actions
    }
}

enum Pasteboard {
    static func copy(_ string: String) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        #else
            UIPasteboard.general.string = string
        #endif
    }
}

/// The actions cluster for the periphery bar: a row of buttons when the
/// window is wide enough, collapsing into a single overflow menu when narrow
/// (ViewThatFits picks whichever variant fits).
struct DocumentActionsCluster: View {
    let actions: [DocumentAction]

    var body: some View {
        if !actions.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(actions) { action in
                        actionButton(action) {
                            Label(action.label, systemImage: action.systemImage)
                                .font(.caption)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                    }
                }
                collapsedMenu
            }
        }
    }

    private var collapsedMenu: some View {
        Menu {
            ForEach(actions) { action in
                switch action.kind {
                case .route(let route):
                    NavigationLink(value: route) {
                        Label(action.label, systemImage: action.systemImage)
                    }
                case .copy(let value):
                    Button {
                        Pasteboard.copy(value)
                    } label: {
                        Label(action.label, systemImage: action.systemImage)
                    }
                case .url(let url):
                    Link(destination: url) {
                        Label(action.label, systemImage: action.systemImage)
                    }
                }
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }

    @ViewBuilder
    private func actionButton(
        _ action: DocumentAction, @ViewBuilder label: () -> some View
    ) -> some View {
        switch action.kind {
        case .route(let route):
            NavigationLink(value: route) { label() }
                .buttonStyle(.plain)
        case .copy(let value):
            Button {
                Pasteboard.copy(value)
            } label: {
                label()
            }
            .buttonStyle(.plain)
        case .url(let url):
            Link(destination: url) { label() }
                .buttonStyle(.plain)
        }
    }
}
