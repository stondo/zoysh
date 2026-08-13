# Zoysh

LLM-powered shell assistant for zsh. Port of [yosh](https://github.com/pizlonator/yosh) (Fil Pizlo's LLM-enabled bash fork) to zsh.

Type `yo <natural language>` at your zsh prompt. Get a command prefilled for review, or an inline answer.

```
$ yo find all python files modified today
find . -type f -name "*.py" -newermt "$(date +%Y-%m-%d)"
# ↑ prefilled at your prompt — press Enter to run, or edit first

$ yo -c what does the -exec flag in find do?
The -exec flag runs a command on each matched file...
```

## Installation

### zinit

```zsh
zinit light stondo/zoysh
```

### antidote

```zsh
echo "stondo/zoysh" >> ~/.zsh_plugins.txt
```

### oh-my-zsh

```zsh
git clone https://github.com/stondo/zoysh.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zoysh
# Then add 'zoysh' to your plugins=(... zoysh) in ~/.zshrc
```

### zplug

```zsh
zplug "stondo/zoysh"
```

### manual

```zsh
echo 'source /path/to/zoysh.plugin.zsh' >> ~/.zshrc
```

## Dependencies

| Dependency | Required | Notes |
|------------|----------|-------|
| **zsh >= 5.8** | Yes | |
| **curl** | Yes | API calls |
| **jq** | One of | JSON parsing (preferred, faster) |
| **python3 >= 3.8** | One of | JSON parsing (fallback) |

The plugin auto-detects `jq` or `python3` at load time. `jq` is recommended (~3ms vs ~80ms per call).

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
```

If `~/.yoconf` doesn't exist, defaults to local model at `http://127.0.0.1:8001/v1/`.

### API key files

If no `key` in config, zoysh checks these files (mode 0600, single line):

| Provider | Key file |
|----------|----------|
| anthropic | `~/.anthropickey` |
| openai | `~/.openaikey` |
| kimi | `~/.kimikey` |
| deepseek | `~/.deepseekkey` |
| qwen | `~/.qwenkey` |
| zai | `~/.zaikey` |
| (fallback) | `~/.yoshkey` |

## Usage

| Command | Description |
|---------|-------------|
| `yo <query>` | Generate a shell command (prefilled at prompt) |
| `yo -c <question>` | Ask a question, get inline answer |
| `yo --clear` | Clear session memory |
| `yo --help` | Show help and current config |

## Features

- **Command generation** — natural language to zsh command, prefilled for review
- **Inline Q&A** — ask questions without leaving the terminal
- **Session memory** — remembers conversation context within a session
- **Multi-provider** — Anthropic, OpenAI, Kimi, DeepSeek, Qwen, z.ai, local models
- **Terminal-aware** — includes OS, shell version, pwd, git branch in context
- **Thinking-aware** — strips `<think>` blocks from local reasoning models
- **jq preferred** — fast JSON parsing when available, python3 fallback
- **Config-compatible with yosh** — same `~/.yoconf` format

## Roadmap

### Phase 1: Script Plugin (current)
- [x] `yo` command via zsh function
- [x] Command prefilling via `print -z`
- [x] Session memory
- [x] Multi-provider support
- [x] Config file (`~/.yoconf`)
- [x] jq + python3 JSON backends
- [x] Plugin manager compatibility (zinit, antidote, zplug, oh-my-zsh)
- [x] CI testing
- [ ] Session history with scrollback context
- [ ] Streaming responses

### Phase 2: C Loadable Module
- [ ] Port `yo.c` core (LLM API logic) from yosh
- [ ] ZLE widget registration
- [ ] PTY proxy for scrollback capture
- [ ] Multi-step task continuation
- [ ] Ctrl-C cancellation (self-pipe signal trick)

## Architecture

```
Phase 1 (current):
  zsh prompt -> yo() -> curl -> LLM API -> parse JSON -> print -z (prefill)

Phase 2 (planned):
  zsh prompt -> ZLE widget -> C module -> LLM API
                    ^                               v
                PTY proxy <- scrollback <- terminal I/O <-+
```

## Credits

- **Original concept and LLM logic**: [Fil Pizlo](https://github.com/pizlonator) — [yosh](https://github.com/pizlonator/yosh)
- **zsh port**: [Stefano Tondo](https://github.com/stondo)

## License

GPL-3.0 (inherited from yosh / GNU Bash / GNU Readline).
