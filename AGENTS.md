# AGENTS.md

## Project Overview

**Zoysh** is a port and adaptation of [Yosh](https://github.com/pizlonator/yosh), created by Fil Pizlo, from Bash/Readline to zsh. It provides `yo <natural language>` → shell command generation at the zsh prompt. Yosh's `readline-8.2.13/yo.c` is Copyright (C) 2026 Epic Games, Inc.; preserve upstream notices in derived work.

## Architecture

### Phase 1 (current): Pure zsh script
- `zoysh.plugin.zsh` — the entire MVP. `yo()` function, config loading, API calls via curl, JSON handling via python3, bounded session context, and command prefill via `print -z`.
- No compilation needed. Source it in `.zshrc`.

### Phase 2 (planned): C loadable zsh module
- `src/zoysh.c` — zsh module boilerplate (widget registration, builtins, lifecycle)
- `src/yo_core.c` (planned) — ported from yosh's `readline-8.2.13/yo.c` (~5500 LOC)
  - LLM API calls (curl multi-handle)
  - Multi-provider support (Anthropic Messages, OpenAI Responses, Chat Completions)
  - Session memory
  - Config parsing (`~/.yoconf`)
  - PTY proxy for scrollback capture
  - Self-pipe Ctrl-C cancellation
  - Multi-step continuation
- `src/cJSON.c` (planned, not currently present) — JSON parser (MIT, from yosh/upstream)

### Key differences from yosh

| Aspect | yosh (bash) | zoysh (zsh) |
|--------|-------------|-------------|
| Line editor | GNU Readline | ZLE (Zsh Line Editor) |
| Command prefill | `rl_insert_text()` | `zle -U` / `print -z` |
| Continuation hook | `rl_startup_hook` | `precmd` hook / ZLE widget |
| Shell integration | Fork of bash 5.2.32 | Loadable module (no fork) |
| Build dependency | Fil-C toolchain | Standard gcc + zsh headers |

## Build

```bash
# Phase 1: no build needed
source zoysh.plugin.zsh

# Phase 1 checks and install
make check      # syntax + fixture tests
make install    # install the script plugin to ~/.local

# Phase 2: experimental, incomplete C module
make module     # requires zsh sources and the planned cJSON files
```

## Reference: yosh's yo.c structure

The source to port lives at `readline-8.2.13/yo.c` in the yosh repo (5553 LOC). Key functions:

| Function | Purpose | Port difficulty |
|----------|---------|-----------------|
| `rl_yo_enable()` | Entry point — sets up readline hooks | Rewrite for ZLE |
| `rl_yo_accept_line()` | Intercepts Enter key for "yo " prefix | ZLE widget |
| `yo_call_api()` | Multi-provider HTTP via curl | **Direct port** |
| `yo_build_messages()` | Constructs provider-specific JSON | **Direct port** |
| `yo_parse_response()` | Normalized tool_use parsing | **Direct port** |
| `yo_config_load()` | Parses ~/.yoconf | **Direct port** |
| `yo_pty_init()` | Forks PTY proxy for scrollback | Adapt for zsh |
| `yo_continuation_hook()` | Multi-step task continuation | `precmd` hook |
| `yo_history_*()` | Session memory | **Direct port** |
| `yo_sigint_*()` | Ctrl-C self-pipe cancellation | **Direct port** |

~70% of yo.c is provider/API logic with no readline dependency → direct port.
~20% needs readline→ZLE API translation.
~10% is new zsh-specific glue.

## Config format

`~/.yoconf` (all portable yosh directives; PTY scrollback remains Phase 2):
```
provider local
model qwythos-9b-v2-mtp
base_url http://127.0.0.1:8001/v1/
key local
history_limit 10
token_budget 4096
max_output_tokens 4096
timeout 30
server_web 1
```

## Testing

```bash
# Phase 1 test
make test

# Manual test
zsh -f -i -c 'ZOYSH_CONF=/dev/null; source zoysh.plugin.zsh; yo --help'
zsh -f -i -c 'source zoysh.plugin.zsh; yo "list all python files"'
```

## Conventions

- Compatible with yosh's portable `~/.yoconf` directives; PTY scrollback settings are recognized but unavailable in Phase 1
- Default provider: local model (`http://127.0.0.1:8001/v1/`)
- No external zsh framework dependencies (no oh-my-zsh, no zinit required)
- GPL-3.0-only license, selected for compatibility with Yosh's GPL-3.0-or-later source
- The current release does not bundle Bash, Readline, or cJSON
- cJSON is MIT licensed if it is added to the planned native module

<!-- cairnkeep:playbook:v1:start -->
## Cairnkeep Durable Context

At the start of a nontrivial task that may depend on existing project
decisions, conventions, constraints, recurring failures, or prior work,
make this retrieval the first tool or command. Do not run repository location,
inventory, or search commands such as `pwd`, `ls`, `rg --files`, `find`,
`tree`, or broad text searches first:

- If `memory_search` is available, derive one short query from the task and
  search `scope: project` once. Derive it from the user's task; do not inspect
  the repository first merely to formulate the query.
- Treat returned memory as a locator, not authority. Read and verify the
  maintained repository sources it references before implementing a result.
- If the tool is unavailable or no relevant result exists, continue with
  ordinary repository inspection. Do not repeat or broaden searches merely to
  force a result.
- Do not write, supersede, or approve durable memory unless the user or an
  applicable reviewed workflow explicitly requests capture.

## Cairnkeep Playbooks

Use Cairnkeep's bounded playbook policy to select workflow steps. It advises or
enforces existing capabilities; it does not execute a workflow for you.

- At task start, run `cairn playbook check start --session SESSION --complexity trivial|standard|complex --familiarity known|mixed|unfamiliar` with one value from each bounded set, and follow every applicable `must` action. Apply `should` actions unless there is a concrete reason to skip them; use judgment for `may` actions.
- Re-run `cairn playbook check check` when scope, familiarity, complexity, or risk changes materially.
- Before claiming completion, run `cairn playbook check finish --session SESSION --changed PATH... --risk low|normal|high|security --public-change --completed ACTION... --skipped ACTION=REASON... --enforce` with one bounded risk value and accurate signals and evidence.
- A non-zero enforcement result means applicable `must` evidence is missing. Perform the action and check again; do not relabel a skipped or failed action as completed.
- After a successful finish check, record only material outcomes with `cairn playbook record --policy POLICY_DIGEST --decision DECISION_DIGEST --event finish --action ACTION --outcome OUTCOME --session SESSION [--reason REASON]`, using one call per recorded action and the exact digests returned by the check. Run `cairn playbook record --help` for the bounded values. Actor identity is an unverified local assertion in this release.
- Existing approval and capability boundaries still apply. A playbook cannot enable a disabled capability, grant approval, write durable memory automatically, run arbitrary commands, or authorize destructive work.
- If the CLI or an applicable capability is unavailable, state that limitation and follow the policy intent manually; never invent a receipt or successful result.
<!-- cairnkeep:playbook:v1:end -->
