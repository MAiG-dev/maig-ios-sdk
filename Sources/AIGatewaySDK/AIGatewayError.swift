import Foundation

public enum AIGatewayError: Error, LocalizedError {
    case authFailure
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case .authFailure:
            return "Authentication failed. Check your project API key."
        case .networkError(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .serverError(let code, let message):
            return "Server error \(code)\(message.map { ": \($0)" } ?? "")"
        }
    }
}
