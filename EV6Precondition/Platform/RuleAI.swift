import Foundation
import PreconditionKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence, on the device, for rewording a request the built-in parser didn't follow.
enum RuleAI {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// The request rewritten in the form `RuleComposer` reads, or nil when unavailable.
    static func rewrite(_ request: String, placeNames: [String]) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let places = placeNames.isEmpty ? "none saved" : placeNames.joined(separator: ", ")
            let session = LanguageModelSession(instructions: RuleComposer.rewriteInstructions + "\nThe driver's saved places: \(places).")
            do {
                let response = try await session.respond(to: request)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
                return text.isEmpty ? nil : text
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }
}
