import SwiftUI

/// The form a user fills to report a bug or suggest a feature: their text
/// and, if they want, one screenshot.
///
/// Present it in a sheet: it brings its own navigation bar, with Cancel and
/// Send. Feedback that cannot leave the device right away is saved, then
/// sent once it can, even after the app restarts.
public struct DistilarFeedbackForm: View {
    private let kind: FeedbackKind
    private let onSubmit: @MainActor (Result<Void, DistilarError>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var screenshot: PreparedScreenshot?
    @State private var phase = Phase.editing
    @FocusState private var editing: Bool

    /// - Parameters:
    ///   - kind: What the feedback is about. It sets the title and the hint.
    ///   - onSubmit: Called with success once the feedback is sent, or saved
    ///     to send later, and with failure when it cannot be taken. The form
    ///     stays open either way, to thank the user or to say what went wrong.
    public init(kind: FeedbackKind, onSubmit: @escaping @MainActor (Result<Void, DistilarError>) -> Void = { _ in }) {
        self.kind = kind
        self.onSubmit = onSubmit
    }

    private enum Phase: Equatable {
        case editing
        case sending
        case sent
        case saved
        case failed(DistilarError)
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(kind.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbar }
        }
        .sensoryFeedback(.success, trigger: phase) { _, phase in phase == .sent || phase == .saved }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .sent, .saved:
            ContentUnavailableView {
                Label {
                    Text("Thank You!", bundle: .module)
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            } description: {
                if phase == .sent {
                    Text("Your feedback was sent.", bundle: .module)
                } else {
                    Text("Your feedback is saved and will be sent automatically.", bundle: .module)
                }
            }
        case .editing, .sending, .failed:
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField(text: $text, prompt: kind.prompt, axis: .vertical) {
                    kind.title
                }
                .lineLimit(8...)
                .focused($editing)
                .accessibilityIdentifier("distilar.text")
            } footer: {
                if length > ReportText.maxLength - 500 {
                    Text("\(length) of \(ReportText.maxLength) characters", bundle: .module)
                        .foregroundStyle(length > ReportText.maxLength ? .red : .secondary)
                }
            }
            Section {
                ScreenshotPicker(screenshot: $screenshot)
            } footer: {
                Text("The photo's location and other details stay on this device.", bundle: .module)
            }
            if case .failed(let error) = phase {
                Section {
                    Label {
                        message(for: error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .disabled(phase == .sending)
        .task { editing = true }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if phase == .sent || phase == .saved {
            ToolbarItem(placement: .confirmationAction) {
                Button { dismiss() } label: { Text("Done", bundle: .module) }
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Text("Cancel", bundle: .module) }
            }
            ToolbarItem(placement: .confirmationAction) {
                if phase == .sending {
                    ProgressView()
                } else {
                    Button { send() } label: { Text("Send", bundle: .module) }
                        .disabled(length == 0 || length > ReportText.maxLength)
                        .accessibilityIdentifier("distilar.send")
                }
            }
        }
    }

    private var length: Int {
        ReportText.length(text)
    }

    private func send() {
        guard let outbox = Runtime.shared.outbox else {
            fail(.notConfigured)
            return
        }
        let report = Runtime.shared.report(kind: kind, text: text, screenshot: screenshot)
        let image = screenshot?.data
        phase = .sending
        editing = false
        Task {
            do throws(DistilarError) {
                switch try await outbox.submit(report, image: image, within: .seconds(15)) {
                case .sent:
                    phase = .sent
                    onSubmit(.success(()))
                case .waiting:
                    phase = .saved
                    onSubmit(.success(()))
                case .refused(let reason):
                    fail(.rejected(reason))
                }
            } catch {
                fail(error)
            }
        }
    }

    private func fail(_ error: DistilarError) {
        phase = .failed(error)
        onSubmit(.failure(error))
    }

    private func message(for error: DistilarError) -> Text {
        switch error {
        case .notConfigured:
            Text("Feedback is not set up in this app yet.", bundle: .module)
        case .rejected:
            Text("This feedback could not be sent.", bundle: .module)
        case .queueFull:
            Text("Too much feedback is waiting for a connection. Try again once you are online.", bundle: .module)
        case .storage:
            Text("This feedback could not be saved on the device.", bundle: .module)
        }
    }
}

extension FeedbackKind {
    fileprivate var title: Text {
        switch self {
        case .bug: Text("Report a Bug", bundle: .module)
        case .feature: Text("Suggest a Feature", bundle: .module)
        }
    }

    fileprivate var prompt: Text {
        switch self {
        case .bug: Text("What went wrong? What did you expect?", bundle: .module)
        case .feature: Text("What would you like the app to do?", bundle: .module)
        }
    }
}
