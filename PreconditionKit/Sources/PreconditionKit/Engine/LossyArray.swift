import Foundation

/// An array that decodes every element it can and skips the ones it can't, so one bad or newer-format
/// entry doesn't lose the whole file. Encodes as a plain array.
public struct LossyArray<Element: Codable>: Codable {
    public var elements: [Element]

    public init(_ elements: [Element]) {
        self.elements = elements
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !c.isAtEnd {
            if let element = try? c.decode(Element.self) {
                out.append(element)
            } else {
                // Step over the element that failed; stop if even that can't move on.
                guard (try? c.decode(Skip.self)) != nil else { break }
            }
        }
        elements = out
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(elements)
    }

    /// Decodes from any value, reading nothing: moves the container past one element.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

extension LossyArray: Equatable where Element: Equatable {}
extension LossyArray: Sendable where Element: Sendable {}

extension LossyArray where Element: Identifiable {
    /// A `JSONFileStore` merge: everything in `mine`, plus the file's items whose ids `mine` lacks
    /// (file's first, in their order). In-memory items win by id.
    public static func mergingByID(file: LossyArray, mine: LossyArray) -> LossyArray {
        let ids = Set(mine.elements.map(\.id))
        return LossyArray(file.elements.filter { !ids.contains($0.id) } + mine.elements)
    }
}
