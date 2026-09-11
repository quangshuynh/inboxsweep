#if DEBUG
import Foundation

/// Synthetic unsubscribe metadata for the sample mailbox, and a one-click endpoint that is not
/// an endpoint.
///
/// ### Why the sample mailbox has this at all
///
/// The unsubscribe flow has five states, and none of them could be reached on synthetic mail
/// while every sample sender carried a bare "a header was present" Boolean. That left the whole
/// feature (the mechanism list, the destination line, the confirmation, the outcome wording,
/// the Activity row) coverable only against somebody's real mailbox, which is precisely what
/// this file exists to avoid.
///
/// ### Why the destinations cannot reach anybody
///
/// Every host below is under **`.example`**, which RFC 2606 reserves and which no registry will
/// ever delegate. It is not merely a domain nobody owns; it is a domain nobody *can* own. A bug
/// that sent a real request from a sample run would fail to resolve rather than arrive
/// somewhere.
///
/// And in the one place a sample run could send something (the one-click confirmation) it
/// does not reach the network at all: ``SampleUnsubscriber`` answers in-process. So the sample
/// mailbox can demonstrate a complete unsubscribe, including its Activity entry, with no socket
/// opened. `SafetyBoundaryTests` asserts that.
nonisolated enum SampleUnsubscribe {

    /// RFC 8058 one-click: an HTTPS URL and the header that declares it.
    static let oneClick = MessageUnsubscribeMetadata(
        targets: [
            .mail(MailtoUnsubscribeAddress(string: "mailto:unsubscribe@lists.digest.example")!),
            .web(HTTPSUnsubscribeURL(string: "https://lists.digest.example/u/one-click/sample")!),
        ],
        declaresOneClickPost: true,
        headerWasPresent: true
    )

    /// An ordinary unsubscribe page, with a mail address beside it. Two mechanisms, no
    /// one-click, which is what the selection rules have to choose between visibly.
    static let webPageAndMail = MessageUnsubscribeMetadata(
        targets: [
            .web(HTTPSUnsubscribeURL(string: "https://deals.storefront.example/preferences/unsubscribe")!),
            .mail(MailtoUnsubscribeAddress(string: "mailto:stop@deals.storefront.example?subject=unsubscribe")!),
        ],
        declaresOneClickPost: false,
        headerWasPresent: true
    )

    /// A mail-only unsubscribe, as plenty of older lists still are.
    static let mailOnly = MessageUnsubscribeMetadata(
        targets: [
            .mail(MailtoUnsubscribeAddress(string: "mailto:leave@frontend-weekly.example?subject=unsubscribe")!),
        ],
        declaresOneClickPost: false,
        headerWasPresent: true
    )

    /// A header that was present and yielded nothing usable.
    ///
    /// An `http` link and an unbracketed value: the two most common real-world shapes the
    /// parser refuses. This is the ambiguous state, and the sample mailbox has one so the
    /// screen that explains it can be looked at.
    static let malformed = MessageUnsubscribeMetadata(
        targets: [
            .unsupported(UnsupportedUnsubscribeValue(reason: .insecureScheme, scheme: "http")),
            .unsupported(UnsupportedUnsubscribeValue(reason: .notBracketed)),
        ],
        declaresOneClickPost: false,
        headerWasPresent: true
    )

    /// Launch argument that gives the sample session an in-process one-click boundary.
    ///
    /// Matches `UITestLaunchArgument.sampleUnsubscribe`. Off by default, so an ordinary sample
    /// run has no unsubscribe boundary at all and its confirmation is absent rather than
    /// disabled: the same posture the sample mailbox takes towards archiving.
    static let launchArgument = "--sample-unsubscribe"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// The boundary a sample session gets, or none.
    static func unsubscriber() -> (any MailUnsubscribing)? {
        isRequested ? SampleUnsubscriber() : nil
    }
}

/// A one-click boundary that answers without a network.
///
/// It has no transport, no `URLSession`, and no way to acquire one: the accepted answer is
/// constructed from the request it was handed. That is what makes the UI journey for a
/// *confirmed* one-click unsubscribe safe to run on any machine: there is nothing for it to
/// reach.
nonisolated struct SampleUnsubscriber: MailUnsubscribing {

    func unsubscribeCapability() async -> UnsubscribeCapability { .oneClickSupported }

    func submitOneClickUnsubscribe(
        _ request: OneClickUnsubscribeRequest
    ) async throws -> OneClickUnsubscribeReceipt {
        OneClickUnsubscribeReceipt(host: request.endpoint.host, statusCode: 200, redirectCount: 0)
    }
}

/// An opener that opens nothing.
///
/// The sample session's ``ExternalURLOpening``. A browser handoff on synthetic mail must not
/// actually launch Safari at a `.example` host during a UI test, so this reports success and
/// does nothing, which is enough for the outcome, the wording, and the Activity row to be
/// exercised, and is the only honest thing a synthetic mailbox can do with a synthetic URL.
nonisolated struct SampleURLOpener: ExternalURLOpening {

    func open(_ url: URL) async -> Bool { true }
}
#endif
