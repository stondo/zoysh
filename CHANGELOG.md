# Changelog

All notable changes to Zoysh are documented here. The project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.4.1] - 2026-08-26

### Fixed

- Stop the `command not found: user:zle-line-init` error that v0.4.0 printed
  on every prompt draw when another plugin or the user config had registered
  its own `zle-line-init` widget. The previous widget reference is now
  resolved to its bare function name before chaining, self-chaining is
  guarded, and the chain call is skipped if the target function no longer
  exists. Foreign hooks chained this way still run (regression tested).

## [0.4.0] - 2026-08-25

### Added

- Stream responses over SSE with per-provider delta decoding (Chat
  Completions, Anthropic Messages, OpenAI Responses). Chat answers print
  progressively, then the streamed text is replaced by the rendered
  Markdown, byte-identical to the non-streaming output. Thinking models
  stream with `<think>` blocks hidden, including tags split across chunk
  boundaries.
- Add the `streaming` config directive (default `1`); set `streaming 0`
  for the previous single blocking request. Non-SSE responses, including
  provider errors, fall back to the blocking path automatically. In
  streaming mode the `timeout` directive applies per chunk (idle timeout).
- Cancel in-flight requests with Ctrl-C. The streaming helper runs in its
  own session so one signal reaps python and curl together; partial chat
  answers are kept, a short `yo: cancelled` notice replaces the error,
  and the interrupt trap is verified not to leak into normal shell
  behavior.
- Add a ZLE widget: `M-y` on a typed buffer (or an empty buffer for an
  inline mini-prompt) generates the command directly into `BUFFER`
  without leaving the line editor. Results are assigned to BUFFER/CURSOR
  rather than pushed with `zle -U`, which would replay the command
  through the user keymap. Rebind with `bindkey`; opt out with
  `zstyle ':zoysh:widget' bind no`.
- Add opt-in multi-step plans: with `continuation 1`, the model may
  answer with a fenced `zoysh:plan` block (one command per line). zoysh
  prefills each step for review, advances when the prefilled command
  itself ran (tracked via preexec, since history is not committed when
  precmd fires), and drops the queue on any other command. `yo --skip`
  and `yo --abort` manage the queue; follow-up queries carry the plan
  plus completed steps as context. Defaults to off.
- Add opt-in scrollback capture for plan steps, designed in
  `doc/pty-design.md` before implementation: zpty hosting and a
  fork/exec PTY pair were both rejected for v1 (they amount to writing a
  terminal multiplexer). With `scrollback_enabled 1` steps prefill as
  `zoysh-run <command>`, which tees the command and its output into a
  ring bounded by `scrollback_bytes`, preserves the exit status, and
  feeds later queries as context. Ambient whole-terminal capture remains
  a Yosh-only feature and the README says so.
- Add the experimental native module: vendored MIT cJSON, a `zoysh-status`
  builtin with a C port of the `~/.yoconf` parser, and a `zoysh-call`
  streaming client speaking the identical NUL-record protocol as the
  python helper (incremental think suppression, wrap accounting, non-SSE
  fallback, SIGINT-driven cancellation). The script bridges to it with
  `zstyle ':zoysh:engine' engine module` and stays the default engine;
  gated module tests (`make check-module`) verify byte-identical output
  between engines, `make check` never requires the module, and the CI
  module job is allow-failure while experimental.
- Add `tests/stub_server.py`, a stdlib-only OpenAI-compatible stub with
  canned streaming and non-streaming scripts, plus zpty-driven
  interactive tests, so CI covers streaming, cancellation, plans, the
  widget, and capture without a model backend.

### Changed

- Prefill commands through a `zle-line-init` hook instead of `print -z`,
  whose input-stack semantics let already-queued terminal input (an Enter
  pressed while yo was still running) execute the pushed line before
  review. The line-init hook keeps the text in the editor buffer only;
  nothing runs without an explicit accept of the visible line.
- The Makefile no longer lets framework-provided `ZSH` environment values
  (oh-my-zsh exports `ZSH`) override the test runner.

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
- Accept z.ai's standard `ZAI_API_KEY` environment variable as a credential source.
- Add OpenRouter support with `OPENROUTER_API_KEY` and `z-ai/glm-5.2` defaults.

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
- Strengthen Yosh attribution and upstream copyright provenance throughout the project.

### Fixed

- Separated the history token budget from the per-response output limit.
- Preserved multiline responses instead of truncating at the first newline.
- Returned useful transport, HTTP, JSON, and provider errors.
- Avoided exposing API keys in curl process arguments.

## [0.2.0] - 2026-08-13

- Initial Phase 1 script-plugin release.

[Unreleased]: https://github.com/stondo/zoysh/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/stondo/zoysh/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/stondo/zoysh/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/stondo/zoysh/releases/tag/v0.2.0
