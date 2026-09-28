import Foundation

/// Everything that can go wrong talking to the car. The engine switches on these (HANDOVER.md §3.9, §4.4).
public enum ApiError: Error, Equatable, Sendable {
    /// No credentials saved yet; no request was made.
    case notConfigured
    /// Refused locally: the rate budget has nothing left for this kind of request.
    case budgetExhausted(RequestKind)
    /// Kia rejected the refresh token or the PIN. Stops all automation until the user fixes it.
    case loginFailed(reason: String)
    case vehicleNotFound(code: String?)
    /// Kia `4005`. The engine disables the rule.
    case operationNotSupported(code: String?)
    /// Kia `5091`: the account's daily request limit.
    case rateLimited(retryAfter: TimeInterval?)
    /// Kia `5031`, `4081`, `9999`, `4004`: the car is busy, asleep or timed out.
    case vehicleNotAcceptingRequests(retryAfter: TimeInterval?)
    case server(httpCode: Int, code: String?)
    case http(httpCode: Int, code: String?)
    /// No response arrived. Still costs a request.
    case network(String)
    case badResponse(httpCode: Int, cause: String)

    public var isAuthFailure: Bool {
        if case .loginFailed = self { return true }
        return false
    }

    public var httpCode: Int? {
        switch self {
        case .loginFailed: return 401
        case .vehicleNotFound: return 404
        case .operationNotSupported: return 422
        case .rateLimited, .vehicleNotAcceptingRequests: return 429
        case .server(let code, _), .http(let code, _), .badResponse(let code, _): return code
        case .notConfigured, .budgetExhausted, .network: return nil
        }
    }

    public var message: String {
        switch self {
        case .notConfigured:
            return "Kia Connect refresh token not set"
        case .budgetExhausted(let kind):
            return "rate budget exhausted for \(kind.rawValue) requests"
        case .loginFailed(let reason):
            return reason
        case .vehicleNotFound:
            return "vehicle not found — check the VIN"
        case .operationNotSupported:
            return "operation not supported by this vehicle"
        case .rateLimited(let retryAfter):
            return "rate limit reached" + (retryAfter.map { ", retry after \(Self.duration($0))" } ?? "")
        case .vehicleNotAcceptingRequests:
            return "vehicle not accepting requests"
        case .server(let code, let detail):
            return "server error \(code)" + (detail.map { " (\($0))" } ?? "")
        case .http(let code, let detail):
            return "HTTP \(code)" + (detail.map { " (\($0))" } ?? "")
        case .network(let cause):
            return "network error: \(cause)"
        case .badResponse(_, let cause):
            return "could not read response: \(cause)"
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s % 3600 == 0 { return "\(s / 3600)h" }
        if s % 60 == 0 { return "\(s / 60)m" }
        return "\(s)s"
    }
}

extension ApiError: LocalizedError {
    public var errorDescription: String? { message }
}
