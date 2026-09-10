import Foundation

/// Wire types mirroring the subset of Gmail's JSON the app reads.
///
/// These are `fileprivate`-in-spirit: they are used by the adapter only, and are converted to
/// domain models by ``GmailMessageNormalizer`` before anything else sees them. Nothing outside
/// `Providers/Gmail` references these types.
nonisolated enum GmailDTO {

    struct Profile: Decodable, Sendable, Equatable {
        let emailAddress: String?
        let messagesTotal: Int?
    }

    struct MessageList: Decodable, Sendable, Equatable {
        let messages: [MessageReference]?
        let nextPageToken: String?
    }

    struct MessageReference: Decodable, Sendable, Equatable {
        let id: String
        let threadId: String?
    }

    struct Message: Decodable, Sendable, Equatable {
        let id: String
        let threadId: String?
        let labelIds: [String]?
        /// Milliseconds since the epoch, delivered as a string.
        let internalDate: String?
        let payload: Payload?
    }

    struct Payload: Decodable, Sendable, Equatable {
        let headers: [Header]?
    }

    struct Header: Decodable, Sendable, Equatable {
        let name: String
        let value: String?
    }

    /// Google's standard error envelope.
    struct ErrorEnvelope: Decodable, Sendable {
        struct Detail: Decodable, Sendable {
            let status: String?
            let message: String?
            let errors: [Reason]?
        }

        struct Reason: Decodable, Sendable {
            let reason: String?
        }

        let error: Detail?
    }
}
