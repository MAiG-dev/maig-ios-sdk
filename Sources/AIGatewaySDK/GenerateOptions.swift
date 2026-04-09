import Foundation

public struct GenerateOptions {
    public let model: String?
    public let userId: String?
    public let maxTokens: Int?

    public init(model: String? = nil, userId: String? = nil, maxTokens: Int? = nil) {
        self.model = model
        self.userId = userId
        self.maxTokens = maxTokens
    }
}
