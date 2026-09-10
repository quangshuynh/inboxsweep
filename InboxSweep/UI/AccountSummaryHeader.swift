import SwiftUI

/// The header above the sender list: which account, how much was loaded, how many senders.
///
/// Phrased as "loaded" rather than "total" throughout, because the app has only seen a window
/// of the mailbox and it would be easy — and misleading — to imply otherwise.
struct AccountSummaryHeader: View {

    let snapshot: InboxSnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.account.emailAddress.displayValue)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityIdentifier("dashboard.accountLabel")

                Text("Connected to \(snapshot.account.providerDisplayName) · read-only")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let coverage = coverageDescription {
                    Text(coverage)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let cachedAt = snapshot.cachedAt {
                    Label {
                        Text("Restored from this Mac · read \(cachedAt, format: .relative(presentation: .named)). Reload for current mail.")
                    } icon: {
                        Image(systemName: "internaldrive")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("dashboard.cacheNotice")
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 20) {
                metric(value: snapshot.loadedMessageCount, label: "Messages loaded")
                metric(value: snapshot.senderCount, label: "Senders")
                metric(value: snapshot.unreadMessageCount, label: "Unread")
            }
            // Applied to the metric group rather than the whole header: SwiftUI pushes an
            // identifier down onto descendants, so a header-wide one would erase the
            // account label's own identifier.
            .accessibilityIdentifier("dashboard.metrics")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Says how far back the loaded window reaches, so the counts beside it are read in context.
    private var coverageDescription: String? {
        guard let oldest = snapshot.oldestLoadedDate, oldest > .distantPast else { return nil }
        return "Showing mail back to \(oldest.formatted(.dateTime.day().month().year()))"
    }

    private func metric(value: Int, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value, format: .number)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}
