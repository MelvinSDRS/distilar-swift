import Distilar
import SwiftUI

/// A harness for the SDK: it opens the form, and can point the SDK at a
/// closed port to show reports waiting on the device.
///
/// The server and key are typed in once, or passed as launch arguments:
/// `-server http://127.0.0.1:8080 -key dpk_…`. `-open bug` or
/// `-open feature` opens the form at launch.
@main
struct DistilarExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @AppStorage("server") private var server = "http://127.0.0.1:8080"
    @AppStorage("key") private var key = ""
    @State private var offline = false
    @State private var form: FeedbackKind?
    @State private var lastResult = "None yet"

    var body: some View {
        NavigationStack {
            Form {
                Section("Feedback") {
                    Button("Report a Bug") { form = .bug }
                    Button("Suggest a Feature") { form = .feature }
                }
                Section {
                    Toggle("Simulate No Connection", isOn: $offline)
                } footer: {
                    Text("Sends to a closed port, so reports wait on the device. Turn it off and they go out.")
                }
                Section("Server") {
                    TextField("URL", text: $server)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Project key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Last result") {
                    Text(lastResult)
                        .accessibilityIdentifier("last-result")
                }
            }
            .navigationTitle("Distilar")
            .sheet(item: $form) { kind in
                DistilarFeedbackForm(kind: kind) { result in
                    lastResult = switch result {
                    case .success: "Taken"
                    case .failure(let error): "Failed: \(error)"
                    }
                }
            }
        }
        .task(id: [server, key, String(offline)]) {
            let url = offline ? URL(string: "http://127.0.0.1:9")! : URL(string: server) ?? .distilarDefault
            Distilar.configure(projectKey: key, baseURL: url)
        }
        .onAppear {
            form = UserDefaults.standard.string(forKey: "open").flatMap(FeedbackKind.init(rawValue:))
        }
    }
}
