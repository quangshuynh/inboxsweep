import SwiftUI

/// Explains a failure in the user's terms and offers the one action that can fix it.
///
/// The text comes entirely from ``MailProviderError``'s `LocalizedError` conformance, which is
/// written to be readable and carries no tokens, response bodies, or mailbox content.
struct InboxErrorView: View {

    let error: MailProviderError
    let account: MailAccount?
    let appModel: AppModel

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: symbolName)
                .font(.system(size: 38))
                .foregroundStyle(error == .cancelled ? Color.secondary : Color.orange)

            VStack(spacing: 8) {
                Text(error.errorDescription ?? "Something went wrong")
                    .font(.title3.weight(.medium))
                    .accessibilityIdentifier("error.title")

                if let reason = error.failureReason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 460)

            actions

            Text("Your mailbox was not changed.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("error.screen")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 12) {
            if account != nil, error.isRetryable {
                Button("Try again") { appModel.session.reload() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("error.retryButton")
            } else if error.requiresReauthentication || account == nil {
                Button(reconnectTitle) { appModel.session.connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appModel.isProviderConfigured)
                    .accessibilityIdentifier("error.connectButton")
            }

            Button("Start over") { appModel.session.disconnect() }
                .accessibilityIdentifier("error.startOverButton")
        }
    }

    private var reconnectTitle: String {
        account == nil ? "Connect Gmail" : "Reconnect Gmail"
    }

    private var symbolName: String {
        switch error {
        case .cancelled: "hand.raised"
        case .network: "wifi.exclamationmark"
        case .notConfigured: "wrench.and.screwdriver"
        case .authorizationExpired, .insufficientPermissions, .authenticationFailed: "lock"
        case .providerFailure, .malformedResponse: "exclamationmark.triangle"
        }
    }
}

// Previews are development-only, and some of them run on the debug-only sample
// mailbox, so the whole block stays out of release builds.
#if DEBUG
#Preview("Network") {
    InboxErrorView(
        error: .network(reason: "The Internet connection appears to be offline."),
        account: MailAccount(
            emailAddress: EmailAddress(displayName: nil, address: "sample.user@example.com"),
            providerDisplayName: "Gmail"
        ),
        appModel: AppModel()
    )
    .frame(width: 720, height: 520)
}

#Preview("Permissions") {
    InboxErrorView(
        error: .insufficientPermissions(reason: "Gmail declined the request."),
        account: nil,
        appModel: AppModel()
    )
    .frame(width: 720, height: 520)
}
#endif
