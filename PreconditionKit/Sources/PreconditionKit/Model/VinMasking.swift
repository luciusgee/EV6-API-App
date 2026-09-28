import Foundation

/// VINs appear in the UI and logs only as their last four characters: `*************0123`.
public func maskVin(_ vin: String) -> String {
    guard vin.count > 4 else { return vin }
    return String(repeating: "*", count: vin.count - 4) + vin.suffix(4)
}

/// VIN alphabet: 17 characters, no I, O or Q.
private let vinPattern = try! NSRegularExpression(pattern: "\\b[A-HJ-NPR-Z0-9]{17}\\b", options: [.caseInsensitive])

/// Masks `vin`, and anything else shaped like a VIN, in `text`. Used before logging raw Kia responses.
public func redactVin(_ text: String, vin: String?) -> String {
    var result = text
    if let vin, !vin.trimmingCharacters(in: .whitespaces).isEmpty {
        result = result.replacingOccurrences(of: vin, with: maskVin(vin), options: .caseInsensitive)
    }
    let ns = result as NSString
    let matches = vinPattern.matches(in: result, range: NSRange(location: 0, length: ns.length))
    for match in matches.reversed() {
        let found = ns.substring(with: match.range)
        result = (result as NSString).replacingCharacters(in: match.range, with: maskVin(found))
    }
    return result
}
