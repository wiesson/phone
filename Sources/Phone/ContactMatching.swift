/// Returns a stable, dialable representation while deliberately ignoring an
/// explicitly labeled extension.
func normalizedPhoneNumber(_ value: String) -> String {
    let lowercased = value.lowercased()
    let extensionMarkers = [";ext=", ",ext=", " extension ", " durchwahl ", " ext. ", " ext ", " x"]
    let end = extensionMarkers.compactMap { lowercased.range(of: $0)?.lowerBound }.min() ?? value.endIndex
    let core = value[..<end]
    var normalized = ""
    for character in core {
        if character == "+", normalized.isEmpty {
            normalized.append(character)
        } else if let digit = character.wholeNumberValue {
            normalized.append(String(digit))
        }
    }
    return normalized
}

/// Reduces a stored peer to the one identifier worth showing. baresip reports
/// a display part next to a URI, so the raw value often repeats the same number
/// twice ("015228461402 sip:015228461402") or carries a name the caller lookup
/// has already handled.
func presentablePeer(_ value: String) -> String {
    let trimmed = value.trimmingWhitespace()
    guard !trimmed.isEmpty else { return trimmed }

    var identifiers: [String] = []
    var uriIdentifiers: [String] = []
    for part in trimmed.split(separator: " ").map(String.init) {
        var value = part
        for bracket in ["<", ">", "\"", "'"] { value = value.replacingOccurrences(of: bracket, with: "") }
        var isURI = value.contains("@")
        for scheme in ["sip:", "sips:", "tel:"] where value.lowercased().hasPrefix(scheme) {
            value.removeFirst(scheme.count)
            isURI = true
        }
        value = value.trimmingWhitespace()
        guard !value.isEmpty else { continue }
        if !identifiers.contains(value) { identifiers.append(value) }
        if isURI, !uriIdentifiers.contains(value) { uriIdentifiers.append(value) }
    }

    // A URI is authoritative; anything beside it is a display name, and the
    // caller lookup already owns names.
    let preferred = uriIdentifiers.isEmpty ? identifiers : uriIdentifiers
    return preferred.isEmpty ? trimmed : preferred.joined(separator: " ")
}

func phoneNumbersMatch(_ lhs: String, _ rhs: String) -> Bool {
    let left = normalizedPhoneNumber(lhs)
    let right = normalizedPhoneNumber(rhs)
    guard !left.isEmpty, !right.isEmpty else { return false }
    if left == right { return true }

    let leftDigits = left.filter(\.isNumber)
    let rightDigits = right.filter(\.isNumber)
    guard leftDigits.count >= 9, rightDigits.count >= 9 else { return false }
    return leftDigits.suffix(9) == rightDigits.suffix(9)
}

func dialInputRequestsContactSearch(_ input: String) -> Bool {
    let value = input.trimmingWhitespace()
    return !value.isEmpty && !value.contains("@") && value.contains(where: \.isLetter)
}

func preferredContactDisplayName(existing: String?, system: String?) -> String? {
    for candidate in [existing, system] {
        let value = candidate?.trimmingWhitespace() ?? ""
        if !value.isEmpty { return value }
    }
    return nil
}

private extension String {
    func trimmingWhitespace() -> String {
        String(drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
    }
}
