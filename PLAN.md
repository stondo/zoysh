# Zoysh Feature Plan: close every Yosh gap

> Written 2026-08-25 by the previous session. This file is the handoff brief for a
> fresh opencode session in this repo. Execute top to bottom. Do not skip ahead:
> features are ordered by dependency, and each one merges before the next starts.

## Context you need before touching anything

- Zoysh is a port of Yosh (Fil Pizlo) from Bash/Readline to zsh. Read `AGENTS.md`
  first: it maps every Yosh mechanism to its zsh equivalent
  (`rl_insert_text` -> `zle -U` / `print -z`, `rl_startup_hook` -> `precmd`/ZLE, etc.).
- The upstream reference is yosh's `readline-8.2.13/yo.c` (~5500 LOC, Epic Games
  copyright, GPL). Clone https://github.com/pizlonator/yosh next to this repo when
  working on `feat/native-module` and `feat/pty-scrollback`; preserve upstream
  notices in any derived code (see `NOTICE`).
- Current state: v0.3.0, pure script plugin, `zoysh.plugin.zsh` (897 lines),
  JSON via python3 helper, curl for HTTP, `make check` = syntax + tests
  (`tests/test.zsh`, 323 lines). CI runs on push.
- Live local endpoint for manual testing: an OpenAI-compatible server on
  `http://127.0.0.1:8001/v1/` (served by the AIOS router; if down, any llama.cpp /
  vLLM instance works; the python test stub below avoids the dependency).
- Repo commit style: short imperative subject ("Add OpenRouter provider support").

## Ground rules (every feature)

1. One branch per feature, branched from `main`: `git checkout -b feat/<name>`.
2. Definition of done, all mandatory before merge:
   - Feature works interactively in a real zsh (manual smoke test, describe it in the PR/commit body).
   - `make check` green, including NEW tests covering the feature.
   - `README.md` updated: usage, roadmap checkbox ticked, feature section if needed.
   - `CHANGELOG.md` entry under a new version bump (semver: minor for features).
   - No em dashes in user-facing strings or docs (house style).
3. Merge to `main` with `git merge --no-ff` and a one-line summary. Then delete the
   branch and start the next feature. SERIAL execution: never two features in flight.
4. If a feature turns out to need a design change to an earlier one, do it as part
   of the current branch, not by reopening merged work.
5. GSD is available in this environment (`/gsd-quick` for small, full GSD for big).
   For each feature, plain implementation with atomic commits is fine; the
   acceptance criteria below are the contract.

## The test stub (build first, reuse everywhere)

`tests/stub_server.py`: a stdlib-only OpenAI-compatible streaming server on
127.0.0.1:9199 that serves `/v1/models` and `/v1/chat/completions` with
canned SSE chunks (configurable script via env var: plain answer, think-block
answer, multi-command answer, slow stream). All new tests point `ZOYSH_CONF`
at a temp config using this stub so CI never needs a GPU. This unblocks honest
tests for streaming, cancellation, and multi-step.

Branch: `feat/test-stub` (infrastructure, merge before feature 1).

## Feature 1: streaming responses

Branch: `feat/streaming`

Today the python helper blocks until the full JSON response arrives, then prints.
Convert to SSE streaming:

- python helper reads the response incrementally, emits content deltas as they
  arrive (one line per delta, length-prefixed or NUL-delimited so zsh can read
  them with `read -d`).
- zsh side: render each delta as it arrives. Reuse the existing Markdown
  renderer on the accumulated text at the end; during streaming print raw deltas
  (rendering partial Markdown live is a stretch goal, not required).
- Thinking models: stream but hide `<think>...</think>` incrementally
  (state machine: suppress until close tag seen). The final rendered answer must
  be byte-identical to the non-streaming path (test this against the stub).
- `streaming 0|1` config directive, default 1, falls back to the old path
  when the server sends non-SSE (some providers do on error).
- Timeout handling: the existing `timeout` directive now applies per-chunk
  (idle timeout), not total.

Acceptance: run `yo -c <question>` against the stub with a slow script; output
appears progressively; final text matches non-streaming output; `make check`
includes a streaming test (stub with 3 delayed chunks); plain command mode
(`yo <intent>`) still prefills via `print -z` only after the full response.

## Feature 2: Ctrl-C cancellation

Branch: `feat/cancel`

- While yo is waiting on the network, Ctrl-C must: kill the python/curl child
  process group cleanly (no zombies, no orphaned stub connections), restore the
  prompt, and print a short `yo: cancelled` notice.
- Implementation: run the helper in its own process group (`setopt monitor` +
  `kill -- -PGID` or `posix_spawn` via python), install a zsh `TRAPINT` during
  the wait loop that is removed afterwards. zsh signal handling is quirky: test
  that the trap does not leak into normal shell behavior after yo returns.
- With streaming merged, cancellation must keep whatever partial text already
  printed, then newline + notice.
- `Ctrl-C during prefill review` already works (normal ZLE); do not break it.

Acceptance: stub server with a 30s delay; issue `yo -c ...`; hit Ctrl-C;
observe instant return, partial/no output preserved, `pgrep -f stub_server`
children reaped; test scripted via `zpty` (zsh's pty tool in tests) sending
^C and asserting prompt returns.

## Feature 3: ZLE widget

Branch: `feat/zle-widget`

Pure zsh, no C needed:

- `zle -N zoysh-widget` + `bindkey` defaults: `M-y` opens a mini-prompt
  (or reuses BUFFER as the query when called with prefix arg).
- Widget flow: read query (via `read -k` overlay or BUFFER), call the existing
  `yo` machinery WITHOUT forking the visible prompt, insert result with
  `zle -U` (the ZLE-safe equivalent of `print -z`; keep `print -z` for the
  function path). Cursor stays in ZLE the whole time: this is the point of the
  feature, the user never sees a sub-prompt flicker.
- Document `bindkey` customization; do NOT bind anything by default except M-y
  (opt-out via `zstyle :zoysh:widget bind no`).

Acceptance: interactive test described in commit; scripted test using zpty
that sources the plugin, fakes the stub response, calls the widget, asserts
BUFFER contains the generated command; `make check` green.

## Feature 4: multi-step task continuation

Branch: `feat/multi-step`

Yosh chains several commands for one intent. Script-honest design:

- Protocol: extend the system prompt so the model may return multiple commands,
  each on its own line inside a fenced block tagged `zoysh:plan`. The python
  helper parses the plan into a queue: N commands + a final natural-language
  summary line.
- Execution model (safety invariant: zoysh NEVER auto-executes):
  1. Prefill command 1 via `print -z`/`zle -U`. User presses Enter (or edits).
  2. A `precmd` hook installed by yo notices the queued plan, and after the
     command's execution (i.e., next prompt), prefills command 2. And so on.
  3. `yo --skip` prefills the next without running the current; `yo --abort`
     (and any new non-derived command typed by the user) drops the queue.
  4. Queue state in `${ZOYSH_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/zoysh}/plan`.
- Context: on each step, send the plan + the commands already run (not their
  output; output capture is Feature 6) so the model can adjust remaining steps.
- Config: `continuation 0|1`, default 0 (conservative), because it changes the
  feel of the tool. Document loudly in README.

Acceptance: stub script returning a 3-command plan; zpty test drives Enter
three times, asserts the three commands appear in BUFFER in order and the
queue file is cleaned up; `--abort` clears it; single-command answers behave
exactly as before (regression test).

## Feature 5: native module scaffold with ported core

Branch: `feat/native-module`

The big one. Goal for this branch is NOT the full 5500 LOC port; it is the
module skeleton plus the first real ported subsystem, proving the pipeline:

- Build system: `make module` becomes real. Vendor cJSON (MIT, from yosh tree)
  into `src/vendor/cJSON/` with license file. Module builds against zsh headers:
  document the dependency (`zsh/zsh.h` from a zsh source tree or `zsh-devel`),
  guard the target so `make check` never requires it (CI stays script-only;
  module build runs in a separate CI job marked allow-failure initially).
- Port order inside this branch (atomic commits):
  1. module lifecycle: load/unload, `zmodload zsh/zoysh` prints version,
     registers builtin `zoysh-status`.
  2. config parser: C port of `~/.yoconf` reading (reuse Yosh's parsing code
     from yo.c where portable; keep Epic Games notices).
  3. API client: curl multi-handle GET `/models` + one chat completion,
     streaming via the same line protocol as the python helper.
  4. bridge: script falls back to the module when `zmodload` succeeds
     (`zstyle :zoysh:engine module|script`, default script until proven).
- Self-pipe Ctrl-C trick ports here for the module path (Feature 2 behavior
  must be preserved through the bridge).

Acceptance: `make module && zmodload ./zoysh.so && zoysh-status` prints config
summary; streaming one completion through the module against the stub in a
test marked `ZMODULE=1`-gated; script path untouched and all old tests green.

## Feature 6: PTY scrollback capture

Branch: `feat/pty-scrollback`

Last, because it is the most invasive and everything else is already stable.

- Investigate FIRST (timebox 1h): zsh's own `zpty` module for hosting the
  proxy vs a fork/exec pty pair from the C module. Record the decision and
  rationale in `doc/pty-design.md` before writing code.
- v1 scope (be honest in README): capture is opt-in per session, not a
  transparent always-on wrapper. `scrollback_enabled 1` starts a capture ring
  (bounded by `scrollback_bytes`) of commands run through the continuation
  queue and their output; that ring is added to the context of subsequent yo
  calls. Full ambient scrollback of the user's terminal stays a Yosh-only
  feature unless the design doc proves otherwise; say so in the README.
- Privacy note update: captured output is sent to the configured API when yo
  is used; document it next to `scrollback_enabled`.

Acceptance: with capture on, run a 2-step plan whose step 1 prints known
output; `yo -c what did the last command print` answers using the ring
(assert against stub expectations); ring respects byte cap; capture off by
default and zero overhead when off (no hooks registered).

## After all six

- Bump to v0.4.0 (or higher if native module lands, consider v1.0.0 discussion
  with the owner first; do not decide unilaterally).
- Update the DRAFT blog post `zoysh-yosh-zsh-port.md` in
  `~/PARA/Projects/stondo.github.io/content/posts/` with the new capabilities
  (the owner will review and publish; coordinate before flipping draft).
- Update the roadmap section of README (all boxes ticked), CHANGELOG for the
  release, and tag `vX.Y.Z`.

## Known pitfalls from the last session, so you do not rediscover them

- zsh quoting: any eval-heavy code must pass `make syntax`; prefer associative
  arrays and `zformat`/`printf` over nested quoting tricks.
- `print -z` inserts into the NEXT prompt: tests must run under `zpty` to see it.
- python helper must stay stdlib-only (no pip deps; CI is bare).
- Never put API keys in curl argv (current design passes them via fd-backed
  header source; keep that invariant in the C port too).
- The plugin must remain loadable multiple times (zinit reload) without
  duplicating hooks: guard all hook/widget registrations.
- House style: no em dashes in docs or user-facing strings.
