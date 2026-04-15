import Foundation

/// The result of a `getPrompt(named:variables:)` call, carrying substituted messages
/// alongside diagnostics about any placeholder/variable mismatches.
public struct PromptResult: Sendable {
    /// Messages with all matched `{{VAR}}` placeholders replaced by the supplied values.
    /// Unmatched placeholders are left as-is in the content.
    public let messages: [Message]
    /// Placeholder names found in the template that were not supplied in `variables`.
    /// These appear verbatim (e.g. `{{USER}}`) in the returned message content.
    public let missingVariables: [String]
    /// Keys in `variables` that did not correspond to any placeholder in the template.
    public let extraVariables: [String]
}

/// Manages a local cache of server-side prompt sets for a project.
///
/// Create a `PromptStore` with your project API key, call `sync()` at app launch
/// to fetch any changed prompts, then use `getPrompt(named:)` at inference time
/// to retrieve the cached messages — no network call required.
///
/// Prompt names are immutable after creation on the server. Renaming a prompt
/// is a delete + create operation; clients will receive the deletion on next sync.
public final class PromptStore: @unchecked Sendable {

    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession
    private let cacheFileURL: URL

    /// In-memory cache: name → CachedPromptSet
    private var cache: [String: CachedPromptSet] = [:]

    private struct CachedPromptSet: Codable {
        let name: String
        let version: Int
        let contentHash: String
        let messages: [Message]
    }

    private struct SyncResponse: Decodable {
        let prompts: [PromptPayload]
        let deletedNames: [String]
    }

    private struct PromptPayload: Decodable {
        let name: String
        let version: Int
        let contentHash: String
        let messages: [Message]
    }

    // MARK: - Init

    /// Creates a `PromptStore` scoped to the given project API key.
    ///
    /// - Parameters:
    ///   - apiKey: Your project API key (begins with `maig_`).
    ///   - baseURL: Gateway base URL. Defaults to the production endpoint.
    public convenience init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.maig.dev")!
    ) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.init(apiKey: apiKey, baseURL: baseURL, session: URLSession(configuration: config))
    }

    init(apiKey: String, baseURL: URL, session: URLSession) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session

        // Derive a stable filename from the first 16 chars of a simple hash of the key.
        // Using the key prefix directly would leak it; hashing keeps the filename opaque.
        var hash: UInt64 = 14695981039346656037
        for byte in apiKey.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        let suffix = String(format: "%016llx", hash)
        let filename = "maig_prompts_\(suffix).json"

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.cacheFileURL = appSupport.appendingPathComponent(filename)

        // Load persisted cache synchronously so getPrompt(named:) works immediately.
        if let data = try? Data(contentsOf: cacheFileURL),
           let loaded = try? JSONDecoder().decode([String: CachedPromptSet].self, from: data) {
            self.cache = loaded
        }
    }

    // MARK: - Public API

    /// Fetches changed prompts from the server and updates the local cache.
    ///
    /// Safe to call at app launch or whenever a refresh is needed.
    /// Only prompts whose content has changed since the last sync are transmitted.
    public func sync() async throws {
        // Build the hashes map from the current cache.
        var hashesDict: [String: String] = [:]
        for (name, entry) in cache {
            hashesDict[name] = entry.contentHash
        }

        guard let url = URL(string: "/v1/prompts/sync", relativeTo: baseURL)?.absoluteURL else {
            throw AIGatewayError.networkError(URLError(.badURL))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = hashesDict.isEmpty ? [:] : ["hashes": hashesDict]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }

        switch http.statusCode {
        case 200...299:
            break
        case 401:
            throw AIGatewayError.authFailure
        default:
            let message = String(data: data, encoding: .utf8)
            throw AIGatewayError.serverError(statusCode: http.statusCode, message: message)
        }

        let syncResponse = try JSONDecoder().decode(SyncResponse.self, from: data)

        // Merge returned prompts (upsert by name).
        for payload in syncResponse.prompts {
            cache[payload.name] = CachedPromptSet(
                name: payload.name,
                version: payload.version,
                contentHash: payload.contentHash,
                messages: payload.messages
            )
        }

        // Remove deleted prompts.
        for name in syncResponse.deletedNames {
            cache.removeValue(forKey: name)
        }

        try persistCache()
    }

    /// Returns the cached messages for a prompt by name.
    ///
    /// Returns `nil` if the prompt has never been synced (i.e. `sync()` has not
    /// yet run successfully, or the named prompt does not exist on the server).
    public func getPrompt(named name: String) -> [Message]? {
        cache[name]?.messages
    }

    /// Returns the cached messages for a prompt with `{{VARIABLE}}` placeholders replaced.
    ///
    /// - Parameters:
    ///   - name: The prompt name.
    ///   - variables: A dictionary mapping variable names to replacement values.
    ///     Keys are case-sensitive and must match the placeholder names exactly.
    /// - Returns: A `PromptResult` containing the substituted messages and diagnostics,
    ///   or `nil` if the prompt has never been synced or does not exist.
    ///
    /// Any placeholder whose key is absent from `variables` is left unchanged in the
    /// returned content. Inspect `missingVariables` and `extraVariables` to detect mismatches.
    public func getPrompt(named name: String, variables: [String: String]) -> PromptResult? {
        guard let cached = cache[name] else { return nil }

        let pattern = try! NSRegularExpression(pattern: #"\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}"#)
        var templateVars = Set<String>()
        for msg in cached.messages {
            let range = NSRange(msg.content.startIndex..., in: msg.content)
            for match in pattern.matches(in: msg.content, range: range) {
                if let r = Range(match.range(at: 1), in: msg.content) {
                    templateVars.insert(String(msg.content[r]))
                }
            }
        }

        let suppliedKeys = Set(variables.keys)
        let missing = templateVars.subtracting(suppliedKeys).sorted()
        let extra = suppliedKeys.subtracting(templateVars).sorted()

        let substituted = cached.messages.map { msg -> Message in
            var content = msg.content
            for (key, value) in variables {
                content = content.replacingOccurrences(of: "{{\(key)}}", with: value)
            }
            return Message(role: msg.role, content: content)
        }

        return PromptResult(messages: substituted, missingVariables: missing, extraVariables: extra)
    }

    // MARK: - Persistence

    private func persistCache() throws {
        let data = try JSONEncoder().encode(cache)

        // Atomic write: write to a temp file, then replace the target.
        let tempURL = cacheFileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(cacheFileURL.lastPathComponent).tmp")
        try data.write(to: tempURL, options: .atomic)

        _ = try FileManager.default.replaceItemAt(cacheFileURL, withItemAt: tempURL)
    }
}
