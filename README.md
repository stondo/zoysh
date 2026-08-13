# Zoysh

LLM-powered shell assistant for zsh. Port of [yosh](https://github.com/pizlonator/yosh) (Fil Pizlo's LLM-enabled bash fork) to zsh.

Type `yo <natural language>` at your zsh prompt. Get a command prefilled for review, or an inline answer.

> Zoysh never executes generated commands. It places them in the prompt so you can inspect and edit them first.

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
| **python3 >= 3.8** | Yes | Safe JSON request/response handling |

No zsh framework or compiled extension is required.

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

# Maximum output tokens and HTTP timeout in seconds
token_budget 4096
timeout 30
```

If `~/.yoconf` doesn't exist, zoysh defaults to the local OpenAI-compatible API at `http://127.0.0.1:8001/v1/`. Before each request it reads `/models`, uses the configured model when it is loaded, or automatically selects the first model reported by the server. If the server is unavailable or reports no loaded models, `yo` stops with instructions to start the server and load one.
For `anthropic` and `openai`, omitting `base_url` selects the provider's official API endpoint.

### Changing the model

For a local server, `model` is optional because zoysh detects the loaded model automatically. Set it when the server exposes multiple models and you want to prefer a specific one:

```conf
provider qwen
model qwythos-9b-v2-mtp
base_url http://127.0.0.1:8001/v1/
key local
```

For an OpenAI-compatible local server, list its available model IDs with:

```sh
curl -s http://127.0.0.1:8001/v1/models | python3 -m json.tool
```

Zoysh reads `~/.yoconf` when the plugin loads. After changing it, start a new shell with `exec zsh`, then verify the selected backend with `yo --help`. `yo --help` and normal requests refresh local model detection in the running shell; they do not rewrite `~/.yoconf`.

You can also ignore the config file and override the model for one new zsh process:

```sh
ZOYSH_CONF=/dev/null ZOYSH_MODEL=another-model zsh
```

### API key files

If no `key` is configured, zoysh checks these single-line files. Set their mode to `0600`.

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
| `yo --version` | Show the installed version |
| `yo --help` | Show help and current config |

## Features

- **Command generation** — natural language to zsh command, prefilled for review
- **Inline Q&A** — ask questions without leaving the terminal
- **Session memory** — remembers conversation context within a session
- **Multi-provider** — Anthropic, OpenAI, Kimi, DeepSeek, Qwen, z.ai, local models
- **Terminal-aware** — includes OS, shell version, pwd, git branch in context
- **Thinking-aware** — strips `<think>` blocks from local reasoning models
- **Private OpenAI requests** — sets `store: false` on Responses API calls
- **Multiline-safe** — preserves multiline answers and generated commands
- **Config-compatible with yosh** — same `~/.yoconf` format

## Privacy and safety

The query, current directory, operating system, zsh version, git branch, and bounded in-memory session history are sent to the configured API endpoint. Zoysh does not collect telemetry or persist conversation history. API keys are read from config or provider key files and are passed to curl through a file-descriptor-backed header source, keeping them out of curl's process arguments.

Generated commands are untrusted model output. Zoysh only prefills the prompt; review every command before pressing Enter, especially commands that modify files, permissions, packages, or remote systems.

## Release status and roadmap

### Phase 1: Script plugin (v0.3.0)
- [x] `yo` command via zsh function
- [x] Command prefilling via `print -z`
- [x] Session memory
- [x] Multi-provider support
- [x] Config file (`~/.yoconf`)
- [x] Python JSON request/response handling
- [x] Plugin manager compatibility (zinit, antidote, zplug, oh-my-zsh)
- [x] CI testing

The following are future Phase 1 enhancements, not missing v0.3.0 release requirements:

- [ ] Session history with scrollback context
- [ ] Streaming responses

Session memory currently includes earlier `yo` queries and responses only; it does not capture arbitrary terminal output.

### Phase 2: C loadable module (planned)

Phase 2 is experimental and is not part of the script-plugin release. The repository currently contains module boilerplate only.

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

## Development

Run all release checks:

```sh
make check
```

Install the script plugin under `PREFIX` (defaults to `~/.local`):

```sh
make install
```

The experimental C module is not part of the Phase 1 release. `make module` is opt-in and requires a configured zsh source tree plus the planned cJSON sources.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution workflow and [SECURITY.md](SECURITY.md) for private vulnerability reporting.

## Credits

- **Original concept and LLM logic**: [Fil Pizlo](https://github.com/pizlonator) — [yosh](https://github.com/pizlonator/yosh)
- **zsh port**: [Stefano Tondo](https://github.com/stondo)

## License

GPL-3.0-only. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
