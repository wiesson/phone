import Testing
@testable import Phone

@Test func normalizesAndMatchesGermanPhoneNumberFormats() {
    #expect(normalizedPhoneNumber("+49 (2159) 698-7685") == "+4921596987685")
    #expect(normalizedPhoneNumber("02159 6987685") == "021596987685")
    #expect(phoneNumbersMatch("+49 2159 6987685", "02159 6987685"))
    #expect(phoneNumbersMatch("0049 2159 6987685", "+49 (2159) 698-7685"))
}

@Test func matchesInternationalAndExplicitExtensionFormats() {
    #expect(phoneNumbersMatch("+44 20 7946 0958", "020 7946 0958"))
    #expect(normalizedPhoneNumber("+49 2159 6987685 ext. 123") == "+4921596987685")
    #expect(phoneNumbersMatch("+49 2159 6987685 ext. 123", "02159 6987685"))
    #expect(phoneNumbersMatch("02159 6987685 Durchwahl 42", "+49 2159 6987685"))
    #expect(!phoneNumbersMatch("+49 2159 6987685", "+49 2159 6987000"))
}

@Test func existingContactResolutionTakesPrecedenceOverSystemContacts() {
    #expect(preferredContactDisplayName(existing: "Baresip Alice", system: "Address Book Alice") == "Baresip Alice")
    #expect(preferredContactDisplayName(existing: "  Managed Line  ", system: "Address Book Alice") == "Managed Line")
    #expect(preferredContactDisplayName(existing: nil, system: "Address Book Alice") == "Address Book Alice")
    #expect(preferredContactDisplayName(existing: " ", system: "Address Book Alice") == "Address Book Alice")
}

@Test func classifiesContactSearchInputSeparatelyFromDialTargets() {
    #expect(dialInputRequestsContactSearch("Alice"))
    #expect(dialInputRequestsContactSearch("  Müller  "))
    #expect(!dialInputRequestsContactSearch("+49 (2159) 698-7685"))
    #expect(!dialInputRequestsContactSearch("0049 2159 6987685"))
    #expect(!dialInputRequestsContactSearch("alice@example.com"))
    #expect(!dialInputRequestsContactSearch("   "))
}

@Test func aPeerIsShownAsOneIdentifier() {
    // baresip reports the display part next to the URI, so the same number
    // arrives twice.
    #expect(presentablePeer("015228461402 sip:015228461402") == "015228461402")
    #expect(presentablePeer("\"Arne\" <sip:4030108e0@sipgate.de>") == "4030108e0@sipgate.de")
    #expect(presentablePeer("+494482980303") == "+494482980303")
    // The URI wins over a display part; names come from the contact lookup.
    #expect(presentablePeer("+4915112345 sip:reception@hotel.example") == "reception@hotel.example")
    #expect(presentablePeer("") == "")
}
