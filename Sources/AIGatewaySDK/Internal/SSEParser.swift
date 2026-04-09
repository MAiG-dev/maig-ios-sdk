import Foundation

/// Parses Server-Sent Events (SSE) data lines and extracts content token chunks.
enum SSEParser {
    /// Parse a raw SSE data buffer and return content strings extracted from each event.
    /// - Parameter data: Raw bytes received from the server.
    /// - Returns: Array of content strings. Empty if no parseable content found.
    static func parse(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parseText(text)
    }

    static func parseText(_ text: String) -> [String] {
        var results: [String] = []
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data: ") else { continue }
            let payload = String(trimmed.dropFirst("data: ".count))
            guard payload != "[DONE]" else { continue }
            guard let chunkData = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(SSEChunk.self, from: chunkData),
                  let content = chunk.choices.first?.delta.content,
                  !content.isEmpty else { continue }
            results.append(content)
        }
        return results
    }
}

// MARK: - Decoding types

private struct SSEChunk: Decodable {
    let choices: [SSEChoice]
}

private struct SSEChoice: Decodable {
    let delta: SSEDelta
}

private struct SSEDelta: Decodable {
    let content: String?
}
