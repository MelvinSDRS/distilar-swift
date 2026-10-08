import PhotosUI
import SwiftUI

/// The one screenshot a report may carry: a button that opens the photo
/// picker, then the chosen image with a way to remove it.
///
/// The picker runs outside the app, so it needs no access to the photo
/// library. The image is loaded and prepared off the main actor; only
/// `Data` and the prepared, Sendable result cross back.
struct ScreenshotPicker: View {
    @Binding var screenshot: PreparedScreenshot?
    @State private var item: PhotosPickerItem?
    @State private var loading = false
    @State private var unusable = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let screenshot {
                HStack(spacing: 16) {
                    Image(screenshot.preview, scale: displayScale, label: Text("Screenshot", bundle: .module))
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 88, maxHeight: 120)
                        .clipShape(.rect(cornerRadius: 8))
                    Spacer()
                    Button(role: .destructive) {
                        self.screenshot = nil
                        item = nil
                    } label: {
                        Text("Remove", bundle: .module)
                    }
                }
            } else {
                // The label closure is not on the main actor: it reads a copy.
                let loading = loading
                PhotosPicker(selection: $item, matching: .images) {
                    HStack {
                        Label {
                            Text("Attach a Screenshot", bundle: .module)
                        } icon: {
                            Image(systemName: "photo.badge.plus")
                        }
                        if loading {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(loading)
                if unusable {
                    Text("This image cannot be used. Try another one.", bundle: .module)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: item) { _, picked in
            Task { await load(picked) }
        }
    }

    private func load(_ picked: PhotosPickerItem?) async {
        guard let picked else { return }
        loading = true
        unusable = false
        let data = try? await picked.loadTransferable(type: Data.self)
        let prepared: PreparedScreenshot? = if let data { try? await ScreenshotEncoder.prepare(data) } else { nil }
        loading = false
        // A later pick replaced this one while it loaded.
        guard item == picked else { return }
        if let prepared {
            screenshot = prepared
        } else {
            unusable = true
            item = nil
        }
    }
}
