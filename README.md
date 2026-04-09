# AIGatewaySDK

Swift SDK for the [MAIG (Mobile AI Gateway)](https://app.maig.dev) — a unified API gateway that routes AI inference requests to multiple providers from your mobile app.

## Requirements

- iOS 16+ / macOS 13+
- Swift 5.9+

## Installation

### Swift Package Manager

Add the package in Xcode via **File → Add Package Dependencies**, or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/maig-dev/maig-ios-sdk", from: "1.0.0")
]
```

Then add `AIGatewaySDK` as a dependency of your target.

## Getting Started

1. Sign in to [app.maig.dev](https://app.maig.dev) and create a project.
2. Copy your project API key from the dashboard.
3. Initialize the client with your key.

```swift
import AIGatewaySDK

let client = AIGatewayClient(apiKey: "your-api-key")
```

## Usage

### Non-streaming

```swift
let text = try await client.generateText(prompt: "Explain Swift concurrency in one sentence.")
print(text)
```

### Streaming

```swift
let stream = client.streamText(prompt: "Write a haiku about Swift.")
for await token in stream {
    print(token, terminator: "")
}
```

### Options

```swift
let options = GenerateOptions(
    model: "gpt-4o",   // omit to let MAIG route automatically
    userId: "user_123", // used for per-user analytics in the dashboard
    maxTokens: 512
)
let text = try await client.generateText(prompt: "Hello!", options: options)
```

## Error Handling

```swift
do {
    let text = try await client.generateText(prompt: "Hello!")
} catch AIGatewayError.authFailure {
    // Invalid or missing API key — check app.maig.dev for your key
} catch AIGatewayError.serverError(let code, let message) {
    print("Server error \(code): \(message ?? "")")
} catch AIGatewayError.networkError(let underlying) {
    print("Network error: \(underlying)")
}
```

The client automatically retries transient errors up to 2 times with exponential backoff before throwing.

## Dashboard

Monitor usage, manage API keys, and configure routing rules at [app.maig.dev](https://app.maig.dev).

## License

MIT — see [LICENSE](LICENSE).
