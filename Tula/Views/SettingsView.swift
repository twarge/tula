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

    private enum TestResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use demo data", isOn: $useDemo)
                } footer: {
                    Text("Demo mode shows bundled sample data and never touches the network.")
                }

                Section("ERPNext Server") {
                    TextField("Server URL", text: $serverURL, prompt: Text("https://erp.example.com"))
                        .autocorrectionDisabled()
                        #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        #endif
                    TextField("API Key", text: $apiKey)
                        .autocorrectionDisabled()
                        #if !os(macOS)
                            .textInputAutocapitalization(.never)
                        #endif
                    SecureField("API Secret", text: $apiSecret)
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
                            "Tula is read-only by construction: it can only issue GET requests, and only to whitelisted read APIs. For defense in depth, use an API key from an ERPNext user with read/report permissions only (generate one under User → Settings → API Access)."
                        )
                    }
                }
            }
            .formStyle(.grouped)
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
        #if os(macOS)
            .frame(minWidth: 480, minHeight: 420)
        #endif
        .onAppear {
            useDemo = model.useDemo
            serverURL = model.serverURLString
            apiKey = model.apiKey
            apiSecret = model.apiSecret
        }
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
}
