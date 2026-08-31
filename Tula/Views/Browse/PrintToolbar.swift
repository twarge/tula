import ERPNextKit
import QuickLook
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// Desk's Print button, native: a printer menu listing the DocType's print
/// formats ("Standard" plus enabled Print Format documents, server default
/// first). Selecting one downloads the server-rendered PDF and opens it —
/// Preview on macOS, Quick Look on iOS. Rendering is entirely server-side;
/// this stays a pure authenticated read.
struct PrintToolbar: ToolbarContent {
    let doctype: String
    let name: String

    @Environment(AppModel.self) private var model
    @State private var formats: [String] = []
    @State private var rendering = false
    @State private var previewURL: URL?
    @State private var errorMessage: String?

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if formats.isEmpty {
                    Text("Loading print formats…")
                } else {
                    ForEach(formats, id: \.self) { format in
                        Button(format) { render(format) }
                    }
                }
            } label: {
                if rendering {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Print", systemImage: "printer")
                }
            }
            .menuIndicator(.hidden)
            .disabled(rendering)
            .help("Open a print-format PDF")
            .task(id: doctype) {
                formats = await model.cache.printFormats(
                    for: doctype, using: model.dataSource)
            }
            .quickLookPreview($previewURL)
            .alert(
                "Couldn't Render PDF",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func render(_ format: String) {
        rendering = true
        Task {
            defer { rendering = false }
            do {
                let data = try await model.dataSource.renderPDF(
                    doctype: doctype, name: name, format: format)
                let safe = "\(name) – \(format)"
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(safe)
                    .appendingPathExtension("pdf")
                try data.write(to: url, options: .atomic)
                #if os(macOS)
                    NSWorkspace.shared.open(url)
                #else
                    previewURL = url
                #endif
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
