# Changelog

All notable changes to Zoysh are documented here. The project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Add a ZLE widget: `M-y` on a typed buffer (or on an empty buffer for an
  inline mini-prompt) generates the command directly into `BUFFER` without
  leaving the line editor. Results are assigned to BUFFER/CURSOR rather
  than pushed with `zle -U`, which would replay the command through the
  user keymap. Rebind with `bindkey`, or set `zstyle ':zoysh:widget' bind
  no` to keep M-y untouched.
- Cancel in-flight requests with Ctrl-C. The streaming helper now runs in
  its own session, so one signal to its process group reaps python and curl
  together; chat answers keep whatever text already streamed, and a short
  `yo: cancelled` notice replaces the error. The interrupt trap is scoped to
  the request and verified not to leak into normal shell behavior (the
  plugin must arm it against the sticky `localtraps` of its emulation).
- Stream responses over SSE with per-provider delta decoding (Chat
  Completions, Anthropic Messages, OpenAI Responses). Chat answers print
  progressively, then the streamed text is replaced by the rendered Markdown,
  byte-identical to the non-streaming output. Thinking models stream with
  `<think>` blocks hidden, including tags split across chunk boundaries.
- Add the `streaming` config directive (default `1`); set `streaming 0` for
  the previous single blocking request. Non-SSE responses, including provider
  errors, fall back to the blocking path automatically.
- In streaming mode the `timeout` directive now applies per chunk (idle
  timeout) instead of capping the whole request.
- Add `tests/stub_server.py`, a stdlib-only OpenAI-compatible stub server
  with canned streaming and non-streaming scripts, plus end-to-end tests
  against it, so CI covers network behavior without a model backend.
- Accept z.ai's standard `ZAI_API_KEY` environment variable as a credential source.
- Add OpenRouter support with `OPENROUTER_API_KEY` and `z-ai/glm-5.2` defaults.

### Changed

- Strengthen Yosh attribution and upstream copyright provenance throughout the project.
- Refresh contributor, release, and issue documentation for the current provider set.

## [0.3.0] - 2026-08-14

### Added

- Real bounded session context in provider requests.
- Multiline-safe command and chat response handling.
- Terminal Markdown rendering with configurable yosh-compatible styles.
- Hosted Anthropic web-search/web-fetch and OpenAI web-search request tools.
- `max_output_tokens` configuration, separating generation limits from the history budget.
- Parsing and validation for all portable yosh configuration directives.
- Automatic local-model discovery through OpenAI-compatible `/models` endpoints.
- Configurable request timeout and tested request/response fixtures.
- Portable Phase 1 install target and Linux/macOS CI coverage.

### Changed

- Re-read `~/.yoconf` before every command so edits apply without restarting zsh.
- Prune session history according to yosh's `token_budget` semantics.
- Use provider-specific default endpoints and models for Anthropic, OpenAI, Kimi, DeepSeek, Qwen, and z.ai.
- Report missing local servers, unloaded models, and missing hosted API keys with actionable messages.
- Removed the background thinking spinner so interactive zsh does not print job-control notices.
- Clarified missing-config status in `yo --help`; `~/.yoconf` remains optional.
- Warn when PTY-only scrollback capture is requested from the script plugin.
- Made Python 3 an explicit dependency instead of advertising an incomplete jq path.
- Made the unfinished C module an opt-in `make module` target.
- Disabled server-side storage for OpenAI Responses requests.

### Fixed

- Separated the history token budget from the per-response output limit.
- Preserved multiline responses instead of truncating at the first newline.
- Returned useful transport, HTTP, JSON, and provider errors.
- Avoided exposing API keys in curl process arguments.

## [0.2.0] - 2026-08-13

- Initial Phase 1 script-plugin release.

[Unreleased]: https://github.com/stondo/zoysh/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/stondo/zoysh/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/stondo/zoysh/releases/tag/v0.2.0
