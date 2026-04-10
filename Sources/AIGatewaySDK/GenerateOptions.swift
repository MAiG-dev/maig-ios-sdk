import Foundation

public struct GenerateOptions: Sendable {
    public var model: String?
    public var userId: String?
    public var maxTokens: Int?
    public var temperature: Double?
    public var topP: Double?
    public var stop: [String]?
    public var frequencyPenalty: Double?
    public var presencePenalty: Double?
    public var seed: Int?
    public var responseFormat: ResponseFormat?

    public init(
        model: String? = nil,
        userId: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        stop: [String]? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        seed: Int? = nil,
        responseFormat: ResponseFormat? = nil
    ) {
        self.model = model
        self.userId = userId
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stop = stop
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.seed = seed
        self.responseFormat = responseFormat
    }
}

public enum ResponseFormat: String, Sendable {
    case text
    case jsonObject = "json_object"
}
