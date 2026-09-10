import Foundation
import Testing
@testable import InboxSweep

@Suite("Email address normalization")
struct EmailAddressTests {

    @Test("A display name and angle address are separated and normalized", arguments: [
        ("\"The Daily Digest\" <Newsletter@Example.COM>", "The Daily Digest", "newsletter@example.com"),
        ("The Daily Digest <newsletter@example.com>", "The Daily Digest", "newsletter@example.com"),
        ("  Alerts  <  alerts@example.org  >  ", "Alerts", "alerts@example.org"),
        ("<person@example.net>", nil, "person@example.net"),
    ])
    func parsesNameAndAddress(header: String, expectedName: String?, expectedAddress: String) {
        let parsed = EmailAddressParser.parse(header)
        #expect(parsed.displayName == expectedName)
        #expect(parsed.address == expectedAddress)
    }

    @Test("Casing and surrounding whitespace never produce different senders")
    func normalizationIsCaseAndWhitespaceInsensitive() {
        let variants = [
            "newsletter@example.com",
            "NEWSLETTER@EXAMPLE.COM",
            "  Newsletter@Example.Com  ",
            "News <NewsLetter@example.COM>",
            "mailto:newsletter@example.com",
        ]

        let keys = Set(variants.map { EmailAddressParser.parse($0).groupingKey })
        #expect(keys == ["newsletter@example.com"])
    }

    @Test("Sub-addressing and dotted local parts stay distinct")
    func subAddressingIsPreserved() {
        // Gmail would treat these as one account, but other providers do not, and merging
        // them would silently combine senders the user sees as different.
        let plain = EmailAddressParser.parse("user@example.com")
        let tagged = EmailAddressParser.parse("user+news@example.com")
        let dotted = EmailAddressParser.parse("u.ser@example.com")

        #expect(plain.groupingKey != tagged.groupingKey)
        #expect(plain.groupingKey != dotted.groupingKey)
    }

    @Test("Malformed and missing senders resolve to the unknown bucket", arguments: [
        nil,
        "",
        "   ",
        "(no sender)",
        "Someone Without An Address",
        "<>",
        "@example.com",
        "user@",
        "user@@example.com",
    ] as [String?])
    func malformedSendersAreUnknown(header: String?) {
        let parsed = EmailAddressParser.parse(header)
        #expect(!parsed.hasAddress)
        #expect(parsed.groupingKey == EmailAddress.unknownGroupingKey)
        #expect(!parsed.displayValue.isEmpty, "Display must always have something to show")
    }

    @Test("Lenient shapes real mail actually uses are still parsed", arguments: [
        ("Jordan Avery person@example.net", "Jordan Avery", "person@example.net"),
        ("alerts@example.org (Build Alerts)", "Build Alerts", "alerts@example.org"),
    ])
    func parsesLenientShapes(header: String, expectedName: String, expectedAddress: String) {
        let parsed = EmailAddressParser.parse(header)
        #expect(parsed.displayName == expectedName)
        #expect(parsed.address == expectedAddress)
    }

    @Test("A header with words but no address keeps the words for display")
    func addresslessHeaderKeepsItsText() {
        let parsed = EmailAddressParser.parse("Mail Delivery Subsystem")
        #expect(parsed.displayName == "Mail Delivery Subsystem")
        #expect(parsed.displayValue == "Mail Delivery Subsystem")
        #expect(parsed.groupingKey == EmailAddress.unknownGroupingKey)
    }

    @Test("Display value falls back through name, address, then a placeholder")
    func displayValueFallsBack() {
        #expect(EmailAddress(displayName: "Alerts", address: "alerts@example.org").displayValue == "Alerts")
        #expect(EmailAddress(displayName: nil, address: "alerts@example.org").displayValue == "alerts@example.org")
        #expect(EmailAddress.unknown.displayValue == "Unknown sender")
    }

    @Test("An empty or whitespace-only display name is treated as absent")
    func blankDisplayNamesAreDropped() {
        #expect(EmailAddressParser.parse("\"\" <person@example.net>").displayName == nil)
        #expect(EmailAddressParser.parse("   <person@example.net>").displayName == nil)
    }

    @Test("Quoted display names are unquoted and unescaped")
    func quotedNamesAreUnwrapped() {
        let parsed = EmailAddressParser.parse("\"Avery, Jordan\" <person@example.net>")
        #expect(parsed.displayName == "Avery, Jordan")
        #expect(parsed.address == "person@example.net")
    }

    @Test("Encoded-word display names are decoded before display")
    func encodedNamesAreDecoded() {
        let parsed = EmailAddressParser.parse("=?UTF-8?Q?Caf=C3=A9_Bulletin?= <bulletin@example.org>")
        #expect(parsed.displayName == "Café Bulletin")
        #expect(parsed.address == "bulletin@example.org")
    }

    @Test("The address is shown as a secondary line only when it adds information")
    func secondaryDisplayValueIsInformative() {
        #expect(EmailAddress(displayName: "Alerts", address: "alerts@example.org").secondaryDisplayValue == "alerts@example.org")
        #expect(EmailAddress(displayName: nil, address: "alerts@example.org").secondaryDisplayValue == nil)
        #expect(EmailAddress.unknown.secondaryDisplayValue == nil)
    }
}

@Suite("RFC 2047 encoded-word decoding")
struct MIMEEncodedWordDecoderTests {

    @Test("Decodes base64 and quoted-printable words", arguments: [
        ("=?UTF-8?B?Q2Fmw6k=?=", "Café"),
        ("=?UTF-8?Q?Caf=C3=A9?=", "Café"),
        ("=?utf-8?q?hello_world?=", "hello world"),
        ("=?ISO-8859-1?Q?Gr=FC=DFe?=", "Grüße"),
    ])
    func decodesWords(input: String, expected: String) {
        #expect(MIMEEncodedWordDecoder.decode(input) == expected)
    }

    @Test("Whitespace between adjacent encoded words is removed, but literal text is kept")
    func joinsAdjacentWords() {
        #expect(MIMEEncodedWordDecoder.decode("=?UTF-8?Q?Caf=C3=A9?= =?UTF-8?Q?_Bulletin?=") == "Café Bulletin")
        #expect(MIMEEncodedWordDecoder.decode("Re: =?UTF-8?Q?Caf=C3=A9?= today") == "Re: Café today")
    }

    @Test("Undecodable input is passed through rather than dropped", arguments: [
        "=?UTF-8?X?unknown-encoding?=",
        "=?NOT-A-CHARSET?B?QQ==?=",
        "=?UTF-8?B?not valid base64!!?=",
        "=?incomplete",
        "no encoded words here",
    ])
    func passesThroughUndecodableInput(input: String) {
        #expect(MIMEEncodedWordDecoder.decode(input) == input)
    }

    @Test("Base64 words missing their padding still decode")
    func toleratesMissingPadding() {
        #expect(MIMEEncodedWordDecoder.decode("=?UTF-8?B?Q2Fmw6k?=") == "Café")
    }
}
