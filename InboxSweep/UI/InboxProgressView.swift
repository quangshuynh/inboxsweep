import SwiftUI

/// The shared progress screen for connecting, restoring, and loading.
///
/// Always cancellable. A load can take a while on a large mailbox, and a progress screen with
/// no way out is the fastest way to make an app feel like it has seized control.
struct InboxProgressView: View {

    let title: String
    let message: String
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.medium))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 420)

            if let onCancel {
                Button("Cancel", role: .cancel, action: onCancel)
                    .accessibilityIdentifier("progress.cancelButton")
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("progress.screen")
        .accessibilityElement(children: .contain)
    }
}

// Previews are development-only, and some of them run on the debug-only sample
// mailbox, so the whole block stays out of release builds.
#if DEBUG
#Preview {
    InboxProgressView(
        title: "Reading message details…",
        message: "Loading headers for sample.user@example.com. Nothing is being changed.",
        onCancel: {}
    )
    .frame(width: 720, height: 420)
}
#endif
