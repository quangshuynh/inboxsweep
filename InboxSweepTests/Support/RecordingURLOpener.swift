import Foundation
@testable import InboxSweep

/// An ``ExternalURLOpening`` that records what it was asked to open and opens nothing.
///
/// The other half of every browser- and mail-handoff test. Paired with a transport that would
/// have recorded any request, it is what lets a test assert the thing that matters about a
/// handoff: the URL went to the system and **no HTTP request was made**. A handoff that
/// quietly fetched the page first would show up as a request on the transport, and these two
/// recorders together are what would catch it.
final class RecordingURLOpener: ExternalURLOpening, @unchecked Sendable {

    private let lock = NSLock()
    private var opened: [URL] = []

    /// What ``open(_:)`` reports back. `false` stands in for "no app handled it".
    let succeeds: Bool

    init(succeeds: Bool = true) {
        self.succeeds = succeeds
    }

    var openedURLs: [URL] { lock.withLock { opened } }
    var openCount: Int { lock.withLock { opened.count } }

    func open(_ url: URL) async -> Bool {
        lock.withLock { opened.append(url) }
        return succeeds
    }
}

/// A one-click boundary that records requests and answers however a test asks it to.
///
/// Separate from ``RecordingHTTPTransport`` because some tests need to assert at the *boundary*
/// (that it was never called at all) rather than at the wire.
final class RecordingUnsubscriber: MailUnsubscribing, @unchecked Sendable {

    private let lock = NSLock()
    private var received: [OneClickUnsubscribeRequest] = []

    let capability: UnsubscribeCapability
    let response: @Sendable (OneClickUnsubscribeRequest) throws -> OneClickUnsubscribeReceipt

    init(
        capability: UnsubscribeCapability = .oneClickSupported,
        response: @escaping @Sendable (OneClickUnsubscribeRequest) throws -> OneClickUnsubscribeReceipt = { request in
            OneClickUnsubscribeReceipt(host: request.endpoint.host, statusCode: 200, redirectCount: 0)
        }
    ) {
        self.capability = capability
        self.response = response
    }

    /// One that always fails, for the failure-path cases.
    static func failing(_ failure: UnsubscribeFailure) -> RecordingUnsubscriber {
        RecordingUnsubscriber { _ in throw failure }
    }

    var requests: [OneClickUnsubscribeRequest] { lock.withLock { received } }
    var requestCount: Int { lock.withLock { received.count } }

    func unsubscribeCapability() async -> UnsubscribeCapability { capability }

    func submitOneClickUnsubscribe(
        _ request: OneClickUnsubscribeRequest
    ) async throws -> OneClickUnsubscribeReceipt {
        lock.withLock { received.append(request) }
        return try response(request)
    }
}
