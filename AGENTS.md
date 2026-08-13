# AGENTS.md

## Project Overview

**Zoysh** is a port of [yosh](https://github.com/pizlonator/yosh) (LLM-enabled bash fork) to zsh. It provides `yo <natural language>` → shell command generation at the zsh prompt.

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
- `src/cJSON.c` — JSON parser (MIT, from yosh/upstream)

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

`~/.yoconf` (identical to yosh):
```
provider qwen
model qwythos-9b-v2-mtp
base_url http://127.0.0.1:8001/v1/
key local
history_limit 10
token_budget 4096
```

## Testing

```bash
# Phase 1 test
make test

# Manual test
zsh -f -i -c 'ZOYSH_CONF=/dev/null; source zoysh.plugin.zsh; yo --help'
zsh -f -i -c 'source zoysh.plugin.zsh; yo list all python files'
```

## Conventions

- Config-compatible with yosh (`~/.yoconf` format)
- Default provider: local model (`http://127.0.0.1:8001/v1/`)
- No external zsh framework dependencies (no oh-my-zsh, no zinit required)
- GPL-3.0 license (inherited from yosh/bash/readline)
- cJSON is MIT licensed
