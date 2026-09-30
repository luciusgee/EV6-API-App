import Foundation

/// Telling motorway services apart from any business with "Services" in its name.
public enum ServiceStations {
    /// Operators whose names start a services' name: "Moto Rugby", "Welcome Break Newport Pagnell".
    static let operators = ["moto ", "welcome break", "roadchef", "extra ", "euro garages"]
    /// Words that mean a business, not a place to stop.
    static let businesses = [
        "locksmith", "clean", "plumb", "electric", "financ", "legal", "care", "dental", "medical", "funeral",
        "build", "property", "taxi", "security", "pest", "computer", "it services", "customer", "social",
        "health", "council", "support", "consult", "repair", "print", "hair", "beauty", "vet", "pet ",
        "garden", "roof", "window", "drain", "removal", "courier", "recruit", "account", "insurance", "tyre",
    ]

    /// "Rugby Services", "Moto Rugby", "Watford Gap Services (M1)": yes. "Grahams Locksmith Services": no.
    public static func isMotorwayServices(_ name: String) -> Bool {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        if businesses.contains(where: { n.contains($0) }) { return false }
        if operators.contains(where: { n.hasPrefix($0) }) { return true }
        guard let range = n.range(of: #"\bservices?\b|\bservice area\b"#, options: .regularExpression) else { return false }
        // The place name comes first and is short: "Rugby Services", "Leicester Forest East Services".
        let before = n[..<range.lowerBound].split(separator: " ")
        return !before.isEmpty && before.count <= 3
    }
}
