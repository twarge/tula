import ERPNextKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var useDemo = true
    @State private var serverURL = ""
    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var testResult: TestResult?
    @State private var isTesting = false
    @FocusState private var focusedField: Field?

    private enum TestResult {
        case success(String)
        case failure(String)
    }

    private enum Field {
        case serverURL, apiKey, apiSecret
    }

    var body: some View {
        #if os(macOS)
            // A Mac settings window has no Save or Cancel: a change applies as it is
            // made. Text applies when editing ends (Return, or leaving the field)
            // rather than per keystroke, since applying rebuilds the connection,
            // empties the caches and relocks writes.
            form
                .onSubmit(applyIfChanged)
                .onChange(of: useDemo) { applyIfChanged() }
                .onChange(of: focusedField) { oldField, _ in
                    if oldField != nil { applyIfChanged() }
                }
                .onDisappear(perform: applyIfChanged)
                .frame(minWidth: 480, minHeight: 420)
                .onAppear(perform: load)
        #else
            NavigationStack {
                form
                    .navigationTitle("Settings")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                save()
                                dismiss()
                            }
                        }
                    }
            }
            .onAppear(perform: load)
        #endif
    }

    private var form: some View {
        Form {
            Section {
                Toggle("Use demo data", isOn: $useDemo)
            } footer: {
                Text("Demo mode shows bundled sample data and never touches the network.")
            }

            Section("ERPNext Server") {
                TextField("Server URL", text: $serverURL, prompt: Text("https://erp.example.com"))
                    .focused($focusedField, equals: .serverURL)
                    .autocorrectionDisabled()
                    #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
                TextField("API Key", text: $apiKey)
                    .focused($focusedField, equals: .apiKey)
                    .autocorrectionDisabled()
                    #if !os(macOS)
                        .textInputAutocapitalization(.never)
                    #endif
                SecureField("API Secret", text: $apiSecret)
                    .focused($focusedField, equals: .apiSecret)
            }
            .disabled(useDemo)

            if !useDemo {
                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        if isTesting {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Testing…")
                            }
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(isTesting || configuration == nil)

                    switch testResult {
                    case .success(let message):
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let message):
                        Label(message, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    case nil:
                        EmptyView()
                    }
                } footer: {
                    Text(
                        "Tula reads with GET requests to a fixed list of ERPNext's read APIs. It writes only while the toolbar lock is open, which lasts until Tula quits or these settings change, and only through a fixed list of ERPNext methods. For defense in depth, use an API key from an ERPNext user with read and report permissions only, so the server refuses any write even with the lock open. Generate one under User → Settings → API Access."
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    private func load() {
        useDemo = model.useDemo
        serverURL = model.serverURLString
        apiKey = model.apiKey
        apiSecret = model.apiSecret
    }

    private var configuration: ServerConfiguration? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !apiKey.isEmpty, !apiSecret.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), url.host() != nil else { return nil }
        return ServerConfiguration(baseURL: url, apiKey: apiKey, apiSecret: apiSecret)
    }

    private func testConnection() async {
        guard let configuration else { return }
        isTesting = true
        defer { isTesting = false }
        let source = LiveDataSource(client: ReadOnlyClient(configuration: configuration))
        do {
            try await source.ping()
            let companies = try await source.companies()
            testResult = .success(
                companies.isEmpty
                    ? "Connected (no companies visible — check permissions)"
                    : "Connected — \(companies.count) company(ies) visible")
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }

    private func save() {
        model.useDemo = useDemo
        model.serverURLString = serverURL
        model.apiKey = apiKey
        model.apiSecret = apiSecret
        model.applySettings()
    }

    /// Applies only what differs from the model, so loading the window's values,
    /// or leaving a field untouched, doesn't reconnect.
    private func applyIfChanged() {
        guard
            useDemo != model.useDemo || serverURL != model.serverURLString
                || apiKey != model.apiKey || apiSecret != model.apiSecret
        else { return }
        save()
    }
}
