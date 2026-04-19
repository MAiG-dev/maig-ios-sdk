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
/// ## Versioning
///
/// Prompts use semantic versioning (major.minor). A **major bump** (e.g. v1.0 → v2.0)
/// means a new `{{VARIABLE}}` was added to the prompt — your app code must handle it.
/// A **minor bump** (e.g. v1.0 → v1.1) is a safe content update with no new variables.
///
/// ## Version pinning
///
/// Pin a prompt to a major version so the SDK only ever receives minor updates within
/// that major. The SDK will never download a version beyond the pinned major until you
/// explicitly update the pin — protecting your app from breaking changes until you are
/// ready to handle the new variable.
///
/// ```swift
/// // Pin via JSON config file (maig-prompts.json in your app bundle):
/// // { "pinned": { "support-bot": 1, "onboarding": 2 } }
/// let store = PromptStore(apiKey: "maig_...", configFile: "maig-prompts")
///
/// // Or pin at runtime (overrides the JSON file):
/// store.pin("support-bot", majorVersion: 1)
/// ```
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

    /// Pinned major versions: name → major version number
    private var pinnedMajors: [String: Int] = [:]

    // MARK: - Internal models

    private struct CachedPromptSet: Codable {
        let name: String
        let majorVersion: Int
        let minorVersion: Int
        let contentHash: String
        let messages: [Message]

        // Migrate caches written before semver (had a single `version` Int field).
        enum CodingKeys: String, CodingKey {
            case name, majorVersion, minorVersion, contentHash, messages, version
        }

        init(name: String, majorVersion: Int, minorVersion: Int, contentHash: String, messages: [Message]) {
            self.name = name
            self.majorVersion = majorVersion
            self.minorVersion = minorVersion
            self.contentHash = contentHash
            self.messages = messages
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            contentHash = try c.decode(String.self, forKey: .contentHash)
            messages = try c.decode([Message].self, forKey: .messages)
            if let major = try c.decodeIfPresent(Int.self, forKey: .majorVersion) {
                majorVersion = major
                minorVersion = (try? c.decodeIfPresent(Int.self, forKey: .minorVersion)) ?? 0
            } else {
                // Legacy cache: treat old integer `version` as majorVersion, minor = 0.
                majorVersion = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
                minorVersion = 0
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(majorVersion, forKey: .majorVersion)
            try c.encode(minorVersion, forKey: .minorVersion)
            try c.encode(contentHash, forKey: .contentHash)
            try c.encode(messages, forKey: .messages)
        }
    }

    private struct SyncResponse: Decodable {
        let prompts: [PromptPayload]
        let deletedNames: [String]
    }

    private struct PromptPayload: Decodable {
        let name: String
        let majorVersion: Int
        let minorVersion: Int
        let contentHash: String
        let messages: [Message]
    }

    private struct PromptsConfig: Decodable {
        let pinned: [String: Int]?
    }

    // MARK: - Init

    /// Creates a `PromptStore` scoped to the given project API key.
    ///
    /// - Parameters:
    ///   - apiKey: Your project API key (begins with `maig_`).
    ///   - baseURL: Gateway base URL. Defaults to the production endpoint.
    ///   - configFile: Name of a JSON file in the main bundle (without the `.json` extension)
    ///     that specifies pinned major versions. Defaults to `"maig-prompts"`, so the SDK
    ///     automatically loads `maig-prompts.json` from your bundle if it exists.
    ///     Pass `nil` to disable config file loading entirely.
    ///     Format: `{ "pinned": { "my-prompt": 1, "other-prompt": 2 } }`
    ///     Runtime calls to `pin(_:majorVersion:)` override values from this file.
    public convenience init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.maig.dev")!,
        configFile: String? = "maig-prompts"
    ) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.init(apiKey: apiKey, baseURL: baseURL, session: URLSession(configuration: config), configFile: configFile)
    }

    init(apiKey: String, baseURL: URL, session: URLSession, configFile: String? = "maig-prompts") {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session

        // Derive a stable filename from the first 16 chars of a simple hash of the key.
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

        // Load pinned versions from JSON config file if provided.
        if let configFile,
           let url = Bundle.main.url(forResource: configFile, withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(PromptsConfig.self, from: data),
           let pinned = config.pinned {
            self.pinnedMajors = pinned
        }
    }

    // MARK: - Public API

    /// Pins a prompt to a major version so the SDK only receives minor updates within
    /// that major. Call this before `sync()` for the pin to take effect on the next sync.
    ///
    /// A major version bump (e.g. v1 → v2) indicates a new `{{VARIABLE}}` was added.
    /// Pinning to v1 ensures your app never receives v2+ content until you are ready to
    /// update your code to handle the new variable and bump the pin to 2.
    ///
    /// Runtime pins override values loaded from the JSON config file.
    ///
    /// - Parameters:
    ///   - name: The prompt name to pin.
    ///   - majorVersion: The major version to pin to (e.g. `1` for all v1.x updates).
    public func pin(_ name: String, majorVersion: Int) {
        pinnedMajors[name] = majorVersion
    }

    /// Fetches changed prompts from the server and updates the local cache.
    ///
    /// Only prompts whose content has changed since the last sync are transmitted.
    /// Pinned prompts are only updated within their pinned major version.
    ///
    /// Safe to call at app launch or whenever a refresh is needed.
    public func sync() async throws {
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

        var body: [String: Any] = [:]
        if !hashesDict.isEmpty { body["hashes"] = hashesDict }
        if !pinnedMajors.isEmpty { body["pinned"] = pinnedMajors }
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

        for payload in syncResponse.prompts {
            cache[payload.name] = CachedPromptSet(
                name: payload.name,
                majorVersion: payload.majorVersion,
                minorVersion: payload.minorVersion,
                contentHash: payload.contentHash,
                messages: payload.messages
            )
        }

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

        let tempURL = cacheFileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(cacheFileURL.lastPathComponent).tmp")
        try data.write(to: tempURL, options: .atomic)

        _ = try FileManager.default.replaceItemAt(cacheFileURL, withItemAt: tempURL)
    }
}
