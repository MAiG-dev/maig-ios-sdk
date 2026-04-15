# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-01-01

### Added
- `AIGatewayClient` with async/await `generateText` and `AsyncStream`-based `streamText`
- `PromptStore` for local caching of server-side prompts with variable substitution
- Automatic retry with exponential backoff (2 retries: 1s, 2s delays)
- Typed error handling via `AIGatewayError` enum (`authFailure`, `serverError`, `networkError`)
- `GenerateOptions` supporting model, userId, maxTokens, temperature, topP, stop, frequencyPenalty, presencePenalty, seed, responseFormat
- iOS 16+ and macOS 13+ support
- Swift Package Manager distribution
- MIT License

[Unreleased]: https://github.com/maig-dev/maig-ios-sdk/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/maig-dev/maig-ios-sdk/releases/tag/v1.0.0
