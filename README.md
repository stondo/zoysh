# Zoysh

LLM-powered shell assistant for zsh. Port of [yosh](https://github.com/pizlonator/yosh) (Fil Pizlo's LLM-enabled bash fork) to zsh via ZLE.

Type `yo <natural language>` at your zsh prompt. Get a command prefilled for review, or an inline answer.

```
$ yo find all python files modified today
find . -name "*.py" -mtime 0
# ↑ prefilled at your prompt — press Enter to run, or edit first

$ yo -c what does the -exec flag in find do?
The -exec flag in find runs a command on each matched file...
```

## Quick Start

```zsh
# Source the plugin (Phase 1 — pure zsh, no compilation needed)
source ~/PARA/Projects/zoysh/zoysh.plugin.zsh
```

That's it. Uses your local model by default.

## Configuration

Config file: `~/.yoconf` (same format as yosh)

```conf
# Provider: qwen, kimi, deepseek, anthropic, openai, zai
provider qwen

# Model name
model qwythos-9b-v2-mtp

# Base URL (for local models)
base_url http://127.0.0.1:8001/v1/

# API key (or use key files: ~/.qwenkey, ~/.anthropickey, etc.)
key local

# Session memory
history_limit 10
token_budget 4096
```

If `~/.yoconf` doesn't exist, defaults to local model at `http://127.0.0.1:8001/v1/`.

## Usage

| Command | Description |
|---------|-------------|
| `yo <query>` | Generate a shell command (prefilled at prompt) |
| `yo -c <question>` | Ask a question, get inline answer |
| `yo --clear` | Clear session memory |
| `yo --help` | Show help |

## Features

- **Command generation** — natural language to zsh command, prefilled for review
- **Inline Q&A** — ask questions without leaving the terminal
- **Session memory** — remembers conversation context within a session
- **Multi-provider** — Anthropic, OpenAI, Kimi, DeepSeek, Qwen, z.ai, local
- **Terminal-aware** — includes OS, shell version, pwd, git branch in context
- **Config-compatible with yosh** — same `~/.yoconf` format

## Roadmap

### Phase 1: Script MVP (current)
- [x] `yo` command via zsh function
- [x] Command prefilling via `print -z`
- [x] Session memory
- [x] Multi-provider support (Chat Completions + Anthropic + OpenAI)
- [x] Config file (`~/.yoconf`)
- [x] Terminal-aware system prompt

### Phase 2: C Loadable Module
- [ ] Port `yo.c` core (LLM API logic, ~5500 LOC) from yosh
- [ ] ZLE widget registration
- [ ] PTY proxy for scrollback capture (LLM can see terminal output)
- [ ] Multi-step task continuation
- [ ] Ctrl-C cancellation (self-pipe signal trick)
- [ ] Markdown rendering for chat output
- [ ] ZLE keybinding (e.g., `Ctrl-O` to submit buffer to yo)

### Phase 3: Advanced
- [ ] Web search integration (Anthropic/OpenAI server-side tools)
- [ ] zsh-specific context (vcs_info, hooks, completions)
- [ ] Streaming responses
- [ ] Fuzzy command history

## Architecture

```
Phase 1 (current):
  zsh prompt → yo() function → curl → LLM API → parse JSON → print -z (prefill)

Phase 2 (planned):
  zsh prompt → ZLE widget → C module (ported yo.c) → LLM API
                    ↑                                          ↓
                PTY proxy ← scrollback buffer ← terminal I/O ←┘
```

## Credits

- **Original concept and LLM logic**: [Fil Pizlo](https://github.com/pizlonator) — [yosh](https://github.com/pizlonator/yosh)
- **zsh port**: Stefano Tondo
- **cJSON**: [Dave Gamble](https://github.com/DaveGamble/cJSON) (MIT)

## License

GPL-3.0 (inherited from yosh/GNU Bash/GNU Readline). cJSON is MIT.
