# Changelog

All notable changes to Zoysh are documented here. The project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Removed the background thinking spinner so interactive zsh does not print job start and termination notices around every request.
- Automatically detect models served by local OpenAI-compatible backends before each request and explain how to recover when the server is unavailable or has no model loaded.
- Clarified missing-config status in `yo --help`; `~/.yoconf` remains optional.

## [0.3.0] - 2026-08-13

### Added

- Real bounded session context in provider requests.
- Multiline-safe command and chat response handling.
- Configurable request timeout and tested request/response fixtures.
- Portable Phase 1 install target and Linux/macOS CI coverage.

### Changed

- Made Python 3 an explicit dependency instead of advertising an incomplete jq path.
- Made the unfinished C module an opt-in `make module` target.
- Defaulted Anthropic and OpenAI providers to their official endpoints.
- Disabled server-side storage for OpenAI Responses requests.

### Fixed

- Honored `token_budget` instead of hard-coding 1024 output tokens.
- Preserved multiline responses instead of truncating at the first newline.
- Returned useful transport, HTTP, JSON, and provider errors.
- Avoided exposing API keys in curl process arguments.

## [0.2.0] - 2026-08-13

- Initial Phase 1 script-plugin release.

[Unreleased]: https://github.com/stondo/zoysh/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/stondo/zoysh/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/stondo/zoysh/releases/tag/v0.2.0
