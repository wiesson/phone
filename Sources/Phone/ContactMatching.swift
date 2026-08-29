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
