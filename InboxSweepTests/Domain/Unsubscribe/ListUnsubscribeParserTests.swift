import Foundation
import Testing
@testable import InboxSweep

/// What the parser does with the shapes real mail actually carries.
///
/// Every destination below is under `.example`: RFC 2606's reserved TLD, which no registry
/// will delegate, so not one of these strings could reach anybody even if something in the app
/// tried to. No value here came from a real message.
@Suite("List-Unsubscribe parsing")
struct ListUnsubscribeParserTests {

    // MARK: - The ordinary shapes

    @Test("A single bracketed HTTPS value parses to a web destination")
    func singleHTTPSValue() {
        let targets = ListUnsubscribeParser.targets(in: "<https://lists.example/u/abc>")

        #expect(targets.count == 1)
        #expect(targets[0].webURL?.host == "lists.example")
        #expect(targets[0].webURL?.absoluteString == "https://lists.example/u/abc")
    }

    @Test("Several values parse in header order, and order is what selection breaks ties on")
    func multipleValuesKeepHeaderOrder() {
        let targets = ListUnsubscribeParser.targets(
            in: "<https://first.example/u>, <https://second.example/u>, <https://third.example/u>"
        )

        #expect(targets.compactMap { $0.webURL?.host } == ["first.example", "second.example", "third.example"])
    }

    @Test("A mailto and an HTTPS value are kept distinct, never collapsed into each other")
    func mailtoAndHTTPSStayDistinct() {
        let targets = ListUnsubscribeParser.targets(
            in: "<mailto:leave@lists.example>, <https://lists.example/u/abc>"
        )

        #expect(targets.count == 2)
        #expect(targets[0].mailAddress?.address == "leave@lists.example")
        #expect(targets[0].webURL == nil)
        #expect(targets[1].webURL?.host == "lists.example")
        #expect(targets[1].mailAddress == nil)
    }

    @Test("A mailto's subject and body are carried for the mail client to prefill")
    func mailtoCarriesSubjectAndBody() {
        let targets = ListUnsubscribeParser.targets(
            in: "<mailto:leave@lists.example?subject=unsubscribe&body=please%20remove%20me>"
        )

        let address = targets[0].mailAddress
        #expect(address?.address == "leave@lists.example")
        #expect(address?.subject == "unsubscribe")
        #expect(address?.body == "please remove me")
        #expect(address?.domain == "lists.example")
    }

    // MARK: - One-click

    @Test("The exact RFC 8058 value declares one-click; anything else does not")
    func oneClickPostValue() {
        #expect(ListUnsubscribeParser.declaresOneClick(post: "List-Unsubscribe=One-Click"))
        // Casing and internal whitespace vary between senders and are tolerated.
        #expect(ListUnsubscribeParser.declaresOneClick(post: "list-unsubscribe=one-click"))
        #expect(ListUnsubscribeParser.declaresOneClick(post: "  List-Unsubscribe = One-Click  "))

        // Everything else is not a declaration, and is not read as one.
        #expect(!ListUnsubscribeParser.declaresOneClick(post: "One-Click"))
        #expect(!ListUnsubscribeParser.declaresOneClick(post: "List-Unsubscribe=Two-Click"))
        #expect(!ListUnsubscribeParser.declaresOneClick(post: "List-Unsubscribe=One-Click, extra"))
        #expect(!ListUnsubscribeParser.declaresOneClick(post: ""))
        #expect(!ListUnsubscribeParser.declaresOneClick(post: nil))
    }

    @Test("One-click needs both headers: the Post header alone declares nothing")
    func oneClickNeedsBothHeaders() {
        let withBoth = ListUnsubscribeParser.metadata(
            listUnsubscribe: "<https://lists.example/u/abc>",
            listUnsubscribePost: "List-Unsubscribe=One-Click"
        )
        #expect(withBoth.oneClickURL?.host == "lists.example")

        // Missing List-Unsubscribe-Post: an https URL, and no one-click.
        let withoutPost = ListUnsubscribeParser.metadata(
            listUnsubscribe: "<https://lists.example/u/abc>",
            listUnsubscribePost: nil
        )
        #expect(withoutPost.oneClickURL == nil)
        #expect(withoutPost.webURLs.count == 1)

        // A Post header with no List-Unsubscribe beside it declares nothing about anything.
        let postOnly = ListUnsubscribeParser.metadata(
            listUnsubscribe: nil,
            listUnsubscribePost: "List-Unsubscribe=One-Click"
        )
        #expect(postOnly == .absent)
        #expect(!postOnly.headerWasPresent)
    }

    @Test("Contradictory metadata, one-click declared over a mailto, is neither honoured nor lost")
    func contradictoryOneClickMetadata() {
        let metadata = ListUnsubscribeParser.metadata(
            listUnsubscribe: "<mailto:leave@lists.example>",
            listUnsubscribePost: "List-Unsubscribe=One-Click"
        )

        // There is nothing for the declaration to apply to, so there is no one-click endpoint.
        #expect(metadata.oneClickURL == nil)
        #expect(metadata.declaresOneClickPost)
        #expect(metadata.declaresOneClickWithoutHTTPSURL)
        // And the mailto is still perfectly usable: the contradiction narrows the offer rather
        // than discarding the sender's own working mechanism.
        #expect(metadata.mailAddresses.count == 1)
    }

    @Test("One-click picks the first HTTPS value when a sender lists several")
    func oneClickPicksFirstHTTPSValue() {
        let metadata = ListUnsubscribeParser.metadata(
            listUnsubscribe: "<mailto:a@lists.example>, <https://first.example/u>, <https://second.example/u>",
            listUnsubscribePost: "List-Unsubscribe=One-Click"
        )

        #expect(metadata.oneClickURL?.host == "first.example")
    }

    // MARK: - Malformed input

    @Test("An unbracketed value is refused even when it would have parsed as a URL")
    func unbracketedValueIsRefused() {
        let targets = ListUnsubscribeParser.targets(in: "https://lists.example/u/abc")

        #expect(targets.count == 1)
        #expect(targets[0].webURL == nil)
        #expect(targets[0].unsupportedValue?.reason == .notBracketed)
        #expect(!targets[0].isActionable)
    }

    @Test("Half-bracketed values are refused, in both directions")
    func halfBracketedValuesAreRefused() {
        for raw in ["<https://lists.example/u", "https://lists.example/u>", "<>", "<   >"] {
            let targets = ListUnsubscribeParser.targets(in: raw)
            #expect(targets.allSatisfy { !$0.isActionable }, "Should not act on \(raw)")
        }
    }

    @Test("Mixed casing in the scheme is normal mail and parses")
    func mixedCaseSchemes() {
        #expect(ListUnsubscribeParser.targets(in: "<HTTPS://Lists.Example/u>")[0].isActionable)
        #expect(ListUnsubscribeParser.targets(in: "<MailTo:leave@lists.example>")[0].mailAddress != nil)
    }

    @Test("Whitespace and folding inside a header are tolerated rather than treated as damage")
    func whitespaceIsTolerated() {
        let targets = ListUnsubscribeParser.targets(
            in: "  < https://lists.example/u/abc >  ,\n\t<mailto:leave@lists.example>  "
        )

        #expect(targets.count == 2)
        #expect(targets[0].webURL?.host == "lists.example")
        #expect(targets[1].mailAddress?.address == "leave@lists.example")
    }

    @Test("A duplicated value is listed once, so a sheet cannot show one destination twice")
    func duplicateValuesCollapse() {
        let targets = ListUnsubscribeParser.targets(
            in: "<https://lists.example/u>, <https://lists.example/u>, <mailto:a@lists.example>"
        )

        #expect(targets.count == 2)
        #expect(targets.compactMap { $0.webURL?.host } == ["lists.example"])
    }

    @Test("A comma inside a URL's query does not split the value")
    func commasInsideBracketsDoNotSplit() {
        let targets = ListUnsubscribeParser.targets(in: "<https://lists.example/u?ids=1,2,3>")

        #expect(targets.count == 1)
        #expect(targets[0].webURL?.absoluteString == "https://lists.example/u?ids=1,2,3")
    }

    @Test("A value that is not a URL at all is refused as malformed")
    func nonURLValue() {
        let targets = ListUnsubscribeParser.targets(in: "<click here to unsubscribe>")

        #expect(targets[0].unsupportedValue?.reason == .malformed)
        #expect(!targets[0].isActionable)
    }

    @Test("A header with an absurd number of values is bounded rather than trusted")
    func valueCountIsBounded() {
        let header = (1...50).map { "<https://host\($0).example/u>" }.joined(separator: ", ")
        let targets = ListUnsubscribeParser.targets(in: header)

        #expect(targets.count == ListUnsubscribeParser.maximumValues)
        // The values kept are the first ones, which are the ones selection would have chosen.
        #expect(targets[0].webURL?.host == "host1.example")
    }

    // MARK: - Schemes that are refused

    @Test("An http:// value is refused and never upgraded to https")
    func insecureSchemeIsRefused() {
        let targets = ListUnsubscribeParser.targets(in: "<http://lists.example/u/abc>")

        #expect(targets[0].webURL == nil)
        #expect(targets[0].unsupportedValue?.reason == .insecureScheme)
        #expect(targets[0].unsupportedValue?.scheme == "http")
    }

    @Test("javascript:, file:, data:, and custom schemes are refused outright")
    func dangerousSchemesAreRefused() {
        let cases: [(String, String)] = [
            ("<javascript:alert(1)>", "javascript"),
            ("<file:///etc/passwd>", "file"),
            ("<data:text/html,hello>", "data"),
            ("<ftp://lists.example/u>", "ftp"),
            ("<inboxsweep://unsubscribe>", "inboxsweep"),
            ("<tel:+15550100>", "tel"),
        ]

        for (raw, scheme) in cases {
            let targets = ListUnsubscribeParser.targets(in: raw)
            #expect(targets.count == 1)
            #expect(!targets[0].isActionable, "Should refuse \(raw)")
            #expect(targets[0].unsupportedValue?.reason == .disallowedScheme, "Should refuse \(raw)")
            #expect(targets[0].unsupportedValue?.scheme == scheme)
        }
    }

    @Test("The typed destinations cannot be constructed from anything but their own scheme")
    func typedDestinationsRefuseOtherSchemes() {
        // The structural half of the promise: even with the parser out of the picture, there is
        // no way to make one of these hold something it should not.
        #expect(HTTPSUnsubscribeURL(string: "http://lists.example/u") == nil)
        #expect(HTTPSUnsubscribeURL(string: "javascript:alert(1)") == nil)
        #expect(HTTPSUnsubscribeURL(string: "mailto:a@lists.example") == nil)
        #expect(HTTPSUnsubscribeURL(string: "https:///nohost") == nil)
        #expect(HTTPSUnsubscribeURL(string: "/relative/path") == nil)
        #expect(HTTPSUnsubscribeURL(string: "") == nil)

        #expect(MailtoUnsubscribeAddress(string: "https://lists.example/u") == nil)
        #expect(MailtoUnsubscribeAddress(string: "mailto:") == nil)
        #expect(MailtoUnsubscribeAddress(string: "mailto:notanaddress") == nil)
        #expect(MailtoUnsubscribeAddress(string: "mailto:a@b") == nil)
        #expect(MailtoUnsubscribeAddress(string: "mailto:a b@lists.example") == nil)
    }

    @Test("A refused value keeps its reason and its scheme, and never the sender's text")
    func refusedValuesKeepNoSenderText() {
        // The raw value can carry a per-recipient identifier. Only the reason and the scheme are
        // kept, which is enough to explain the refusal and not enough to leak anything.
        let value = ListUnsubscribeParser
            .targets(in: "<http://lists.example/u/recipient-token-12345>")[0]
            .unsupportedValue

        let properties = Set(Mirror(reflecting: value!).children.compactMap(\.label))
        #expect(properties == ["reason", "scheme"])
        #expect(value?.scheme == "http")
    }

    // MARK: - Whole-message metadata

    @Test("No header at all and a header that yielded nothing are different states")
    func absentAndUnusableAreDifferent() {
        let absent = ListUnsubscribeParser.metadata(listUnsubscribe: nil, listUnsubscribePost: nil)
        #expect(absent == .absent)
        #expect(!absent.headerWasPresent)
        #expect(!absent.hasActionableTarget)

        let unusable = ListUnsubscribeParser.metadata(
            listUnsubscribe: "<http://lists.example/u>",
            listUnsubscribePost: nil
        )
        #expect(unusable.headerWasPresent)
        #expect(!unusable.hasActionableTarget)
        #expect(unusable.unsupportedValues.count == 1)
    }

    @Test("A mixed header keeps what works and records what does not")
    func mixedHeaderKeepsBoth() {
        let metadata = ListUnsubscribeParser.metadata(
            listUnsubscribe: "<javascript:alert(1)>, <https://lists.example/u>, <http://lists.example/u>",
            listUnsubscribePost: nil
        )

        #expect(metadata.webURLs.count == 1)
        #expect(metadata.webURLs[0].host == "lists.example")
        #expect(metadata.unsupportedValues.map(\.reason) == [.disallowedScheme, .insecureScheme])
        #expect(metadata.hasActionableTarget)
    }
}
