#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Stefano Tondo
# zoysh.plugin.zsh — LLM-powered shell assistant for zsh
# Port and adaptation of Yosh by Fil Pizlo:
# https://github.com/pizlonator/yosh
# Yosh readline-8.2.13/yo.c is Copyright (C) 2026 Epic Games, Inc.
#
# Install (plugin managers):
#   zinit:   zinit light stondo/zoysh
#   antidote: echo "stondo/zoysh" >> ~/.zsh_plugins.txt
#   manual:  source /path/to/zoysh.plugin.zsh
#
# Config in ~/.yoconf (same format as yosh):
#   provider local
#   model qwythos-9b-v2-mtp
#   base_url http://127.0.0.1:8001/v1/

# ─── Idempotency ──────────────────────────────────────────────────────────────

(( ${+_ZOYSH_LOADED} )) && return
typeset -g _ZOYSH_LOADED=1

emulate -L zsh

# ─── Non-interactive safety ──────────────────────────────────────────────────

[[ -o interactive ]] || return 0

# ─── Dependency checks ───────────────────────────────────────────────────────

for _dep in curl; do
    command -v "$_dep" >/dev/null 2>&1 || {
        printf 'zoysh: dependency not found: %s\n' "$_dep" >&2
        return 1
    }
done
unset _dep

if ! command -v python3 >/dev/null 2>&1; then
    printf 'zoysh: dependency not found: python3\n' >&2
    return 1
fi

# ─── Constants ────────────────────────────────────────────────────────────────

typeset -g ZOYSH_VERSION="0.4.0"
typeset -g ZOYSH_CONF="${ZOYSH_CONF:-${HOME}/.yoconf}"
typeset -gi ZOYSH_DEBUG=0

# Preserve environment-provided values as reload defaults. The config file is
# re-read for every yo invocation, matching yosh.
typeset -gr _ZOYSH_DEFAULT_PROVIDER="${ZOYSH_PROVIDER:-local}"
typeset -gr _ZOYSH_DEFAULT_MODEL="${ZOYSH_MODEL:-}"
typeset -gr _ZOYSH_DEFAULT_BASE_URL="${ZOYSH_BASE_URL:-}"
typeset -gr _ZOYSH_DEFAULT_API_KEY="${ZOYSH_API_KEY:-}"
typeset -gr _ZOYSH_DEFAULT_HISTORY_LIMIT="${ZOYSH_HISTORY_LIMIT:-10}"
typeset -gr _ZOYSH_DEFAULT_TOKEN_BUDGET="${ZOYSH_TOKEN_BUDGET:-4096}"
typeset -gr _ZOYSH_DEFAULT_MAX_OUTPUT_TOKENS="${ZOYSH_MAX_OUTPUT_TOKENS:-4096}"
typeset -gr _ZOYSH_DEFAULT_TIMEOUT="${ZOYSH_TIMEOUT:-30}"
typeset -gr _ZOYSH_DEFAULT_STREAMING="${ZOYSH_STREAMING:-1}"
typeset -gr _ZOYSH_DEFAULT_CONTINUATION="${ZOYSH_CONTINUATION:-0}"
typeset -gr _ZOYSH_DEFAULT_SERVER_WEB="${ZOYSH_SERVER_WEB:-1}"
typeset -gr _ZOYSH_DEFAULT_CHAT_PREFIX=${ZOYSH_CHAT_PREFIX:-$'\033[1;36myo\033[0m\n'}
typeset -gr _ZOYSH_DEFAULT_COLOR_PREFIX=${ZOYSH_COLOR_PREFIX:-$'\033[0m'}
typeset -gr _ZOYSH_DEFAULT_COLOR_RESET=${ZOYSH_COLOR_RESET:-$'\033[0m'}
typeset -gr _ZOYSH_DEFAULT_ENABLE_ITALIC=${ZOYSH_ENABLE_ITALIC:-$'\033[3m'}
typeset -gr _ZOYSH_DEFAULT_DISABLE_ITALIC=${ZOYSH_DISABLE_ITALIC:-$'\033[23m'}
typeset -gr _ZOYSH_DEFAULT_ENABLE_BOLD=${ZOYSH_ENABLE_BOLD:-$'\033[1m'}
typeset -gr _ZOYSH_DEFAULT_DISABLE_BOLD=${ZOYSH_DISABLE_BOLD:-$'\033[22m'}
typeset -gr _ZOYSH_DEFAULT_ENABLE_STRIKETHROUGH=${ZOYSH_ENABLE_STRIKETHROUGH:-$'\033[9m'}
typeset -gr _ZOYSH_DEFAULT_DISABLE_STRIKETHROUGH=${ZOYSH_DISABLE_STRIKETHROUGH:-$'\033[29m'}
typeset -gr _ZOYSH_DEFAULT_CODE_DELIMITER=${ZOYSH_CODE_DELIMITER:-$'\033[38;5;109m'}

# Session memory
typeset -ga ZOYSH_HISTORY_QUERIES
typeset -ga ZOYSH_HISTORY_TYPES
typeset -ga ZOYSH_HISTORY_RESPONSES

# Runtime config
typeset -g ZOYSH_PROVIDER
typeset -g ZOYSH_MODEL
typeset -g ZOYSH_BASE_URL
typeset -g ZOYSH_API_KEY
typeset -g ZOYSH_HISTORY_LIMIT
typeset -g ZOYSH_TOKEN_BUDGET
typeset -g ZOYSH_MAX_OUTPUT_TOKENS
typeset -g ZOYSH_TIMEOUT
typeset -g ZOYSH_STREAMING
typeset -g ZOYSH_CONTINUATION
typeset -g ZOYSH_SERVER_WEB
typeset -g ZOYSH_CHAT_PREFIX
typeset -g ZOYSH_COLOR_PREFIX
typeset -g ZOYSH_COLOR_RESET
typeset -g ZOYSH_ENABLE_ITALIC
typeset -g ZOYSH_DISABLE_ITALIC
typeset -g ZOYSH_ENABLE_BOLD
typeset -g ZOYSH_DISABLE_BOLD
typeset -g ZOYSH_ENABLE_STRIKETHROUGH
typeset -g ZOYSH_DISABLE_STRIKETHROUGH
typeset -g ZOYSH_CODE_DELIMITER
typeset -g ZOYSH_SCROLLBACK_ENABLED=0
typeset -g ZOYSH_SCROLLBACK_BYTES=1048576
typeset -g ZOYSH_SCROLLBACK_LINES=1000
typeset -g _ZOYSH_BACKEND_ERROR=""
typeset -g _ZOYSH_STREAM_ERROR=""
typeset -g _ZOYSH_RAW_RESPONSE=""
typeset -gi _ZOYSH_CANCELLED=0
typeset -g _ZOYSH_HELPER_PGID=""
typeset -g _ZOYSH_OLD_TRAPINT=""
typeset -gi _ZOYSH_TRAP_DEPTH=0
typeset -gi _ZOYSH_ZLE_MODE=0
typeset -g _ZOYSH_LAST_COMMAND=""
typeset -g _ZOYSH_PENDING_CMD=""
typeset -g _ZOYSH_LINE_INIT_PREV_FUNC=""
typeset -gi _ZOYSH_SCROLLBACK_WARNED=0
typeset -gi _ZOYSH_MODEL_EXPLICIT=0

_zoysh_reset_config() {
    ZOYSH_PROVIDER="$_ZOYSH_DEFAULT_PROVIDER"
    ZOYSH_MODEL="$_ZOYSH_DEFAULT_MODEL"
    [[ -n "$_ZOYSH_DEFAULT_MODEL" ]] && _ZOYSH_MODEL_EXPLICIT=1 || _ZOYSH_MODEL_EXPLICIT=0
    ZOYSH_BASE_URL="$_ZOYSH_DEFAULT_BASE_URL"
    ZOYSH_API_KEY="$_ZOYSH_DEFAULT_API_KEY"
    ZOYSH_HISTORY_LIMIT="$_ZOYSH_DEFAULT_HISTORY_LIMIT"
    ZOYSH_TOKEN_BUDGET="$_ZOYSH_DEFAULT_TOKEN_BUDGET"
    ZOYSH_MAX_OUTPUT_TOKENS="$_ZOYSH_DEFAULT_MAX_OUTPUT_TOKENS"
    ZOYSH_TIMEOUT="$_ZOYSH_DEFAULT_TIMEOUT"
    ZOYSH_STREAMING="$_ZOYSH_DEFAULT_STREAMING"
    ZOYSH_CONTINUATION="$_ZOYSH_DEFAULT_CONTINUATION"
    ZOYSH_SERVER_WEB="$_ZOYSH_DEFAULT_SERVER_WEB"
    ZOYSH_CHAT_PREFIX="$_ZOYSH_DEFAULT_CHAT_PREFIX"
    ZOYSH_COLOR_PREFIX="$_ZOYSH_DEFAULT_COLOR_PREFIX"
    ZOYSH_COLOR_RESET="$_ZOYSH_DEFAULT_COLOR_RESET"
    ZOYSH_ENABLE_ITALIC="$_ZOYSH_DEFAULT_ENABLE_ITALIC"
    ZOYSH_DISABLE_ITALIC="$_ZOYSH_DEFAULT_DISABLE_ITALIC"
    ZOYSH_ENABLE_BOLD="$_ZOYSH_DEFAULT_ENABLE_BOLD"
    ZOYSH_DISABLE_BOLD="$_ZOYSH_DEFAULT_DISABLE_BOLD"
    ZOYSH_ENABLE_STRIKETHROUGH="$_ZOYSH_DEFAULT_ENABLE_STRIKETHROUGH"
    ZOYSH_DISABLE_STRIKETHROUGH="$_ZOYSH_DEFAULT_DISABLE_STRIKETHROUGH"
    ZOYSH_CODE_DELIMITER="$_ZOYSH_DEFAULT_CODE_DELIMITER"
    ZOYSH_SCROLLBACK_ENABLED=0
    ZOYSH_SCROLLBACK_BYTES=1048576
    ZOYSH_SCROLLBACK_LINES=1000
}

_zoysh_decode_config_value() {
    local value="$1"
    if (( ${#value} >= 2 )) &&
       [[ ( "${value[1]}" == '"' && "${value[-1]}" == '"' ) ||
          ( "${value[1]}" == "'" && "${value[-1]}" == "'" ) ]]; then
        value="${value[2,-2]}"
    fi
    printf -v REPLY '%b' "$value"
}

_zoysh_load_config() {
    [[ -f "$ZOYSH_CONF" ]] || return 0
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        line="${line%%[[:space:]]\#*}"
        line="${line%"${line##*[![:space:]]}"}"
        key="${line%%[[:space:]]*}"
        val="${line#${key}}"
        val="${val#"${val%%[![:space:]]*}"}"
        case "$key" in
            provider)      ZOYSH_PROVIDER="${(L)val}" ;;
            model)         ZOYSH_MODEL="$val"; _ZOYSH_MODEL_EXPLICIT=1 ;;
            base_url)      ZOYSH_BASE_URL="$val" ;;
            key)           ZOYSH_API_KEY="$val" ;;
            history_limit) ZOYSH_HISTORY_LIMIT="$val" ;;
            token_budget)  ZOYSH_TOKEN_BUDGET="$val" ;;
            max_output_tokens) ZOYSH_MAX_OUTPUT_TOKENS="$val" ;;
            timeout)       ZOYSH_TIMEOUT="$val" ;;
            streaming)     ZOYSH_STREAMING="$val" ;;
            continuation)  ZOYSH_CONTINUATION="$val" ;;
            server_web)    ZOYSH_SERVER_WEB="$val" ;;
            scrollback_enabled) ZOYSH_SCROLLBACK_ENABLED="$val" ;;
            scrollback_bytes)   ZOYSH_SCROLLBACK_BYTES="$val" ;;
            scrollback_lines)   ZOYSH_SCROLLBACK_LINES="$val" ;;
            chat_prefix)
                _zoysh_decode_config_value "$val"; ZOYSH_CHAT_PREFIX="$REPLY" ;;
            color_prefix)
                _zoysh_decode_config_value "$val"; ZOYSH_COLOR_PREFIX="$REPLY" ;;
            chat_reset|color_reset)
                _zoysh_decode_config_value "$val"; ZOYSH_COLOR_RESET="$REPLY" ;;
            enable_italic)
                _zoysh_decode_config_value "$val"; ZOYSH_ENABLE_ITALIC="$REPLY" ;;
            disable_italic)
                _zoysh_decode_config_value "$val"; ZOYSH_DISABLE_ITALIC="$REPLY" ;;
            enable_bold)
                _zoysh_decode_config_value "$val"; ZOYSH_ENABLE_BOLD="$REPLY" ;;
            disable_bold)
                _zoysh_decode_config_value "$val"; ZOYSH_DISABLE_BOLD="$REPLY" ;;
            enable_strikethrough)
                _zoysh_decode_config_value "$val"; ZOYSH_ENABLE_STRIKETHROUGH="$REPLY" ;;
            disable_strikethrough)
                _zoysh_decode_config_value "$val"; ZOYSH_DISABLE_STRIKETHROUGH="$REPLY" ;;
            code_delimiter)
                _zoysh_decode_config_value "$val"; ZOYSH_CODE_DELIMITER="$REPLY" ;;
            *) printf 'zoysh: %s: unknown directive: %s\n' "$ZOYSH_CONF" "$key" >&2 ;;
        esac
    done < "$ZOYSH_CONF"
}

_zoysh_validate_config() {
    case "$ZOYSH_PROVIDER" in
        local|anthropic|openai|openrouter|kimi|deepseek|qwen|zai) ;;
        *)
            printf 'zoysh: unsupported provider %s; using local\n' "$ZOYSH_PROVIDER" >&2
            ZOYSH_PROVIDER=local
            ;;
    esac
    if [[ "$ZOYSH_HISTORY_LIMIT" != <-> ]] || (( ZOYSH_HISTORY_LIMIT > 1000 )); then
        printf 'zoysh: invalid history_limit; using 10\n' >&2
        ZOYSH_HISTORY_LIMIT=10
    fi
    if [[ "$ZOYSH_TOKEN_BUDGET" != <-> ]] || (( ZOYSH_TOKEN_BUDGET < 100 || ZOYSH_TOKEN_BUDGET > 1000000 )); then
        printf 'zoysh: invalid token_budget; using 4096\n' >&2
        ZOYSH_TOKEN_BUDGET=4096
    fi
    if [[ "$ZOYSH_MAX_OUTPUT_TOKENS" != <-> ]] || (( ZOYSH_MAX_OUTPUT_TOKENS < 1 || ZOYSH_MAX_OUTPUT_TOKENS > 100000 )); then
        printf 'zoysh: invalid max_output_tokens; using 4096\n' >&2
        ZOYSH_MAX_OUTPUT_TOKENS=4096
    fi
    if [[ "$ZOYSH_TIMEOUT" != <-> ]] || (( ZOYSH_TIMEOUT < 1 || ZOYSH_TIMEOUT > 600 )); then
        printf 'zoysh: invalid timeout; using 30\n' >&2
        ZOYSH_TIMEOUT=30
    fi
    if [[ "$ZOYSH_STREAMING" != 0 && "$ZOYSH_STREAMING" != 1 ]]; then
        printf 'zoysh: invalid streaming; using 1\n' >&2
        ZOYSH_STREAMING=1
    fi
    if [[ "$ZOYSH_CONTINUATION" != 0 && "$ZOYSH_CONTINUATION" != 1 ]]; then
        printf 'zoysh: invalid continuation; using 0\n' >&2
        ZOYSH_CONTINUATION=0
    fi
    if [[ "$ZOYSH_SERVER_WEB" != 0 && "$ZOYSH_SERVER_WEB" != 1 ]]; then
        printf 'zoysh: invalid server_web; using 1\n' >&2
        ZOYSH_SERVER_WEB=1
    fi
    if [[ "$ZOYSH_SCROLLBACK_ENABLED" != 0 && "$ZOYSH_SCROLLBACK_ENABLED" != 1 ]]; then
        printf 'zoysh: invalid scrollback_enabled; using 0\n' >&2
        ZOYSH_SCROLLBACK_ENABLED=0
    fi
    if [[ "$ZOYSH_SCROLLBACK_BYTES" != <-> ]] || (( ZOYSH_SCROLLBACK_BYTES < 1 )); then
        printf 'zoysh: invalid scrollback_bytes; using 1048576\n' >&2
        ZOYSH_SCROLLBACK_BYTES=1048576
    fi
    if [[ "$ZOYSH_SCROLLBACK_LINES" != <-> ]] || (( ZOYSH_SCROLLBACK_LINES < 1 )); then
        printf 'zoysh: invalid scrollback_lines; using 1000\n' >&2
        ZOYSH_SCROLLBACK_LINES=1000
    fi
    if (( ZOYSH_SCROLLBACK_ENABLED && ! _ZOYSH_SCROLLBACK_WARNED )); then
        printf 'zoysh: scrollback capture wraps plan steps in zoysh-run and sends captured output to the configured API; see doc/pty-design.md\n' >&2
        _ZOYSH_SCROLLBACK_WARNED=1
    fi
}

_zoysh_resolve_model() {
    (( _ZOYSH_MODEL_EXPLICIT )) && return 0

    if _zoysh_local_base_url >/dev/null; then
        ZOYSH_MODEL=""
        return 0
    fi

    case "$ZOYSH_PROVIDER" in
        anthropic) ZOYSH_MODEL="claude-sonnet-4-5-20250929" ;;
        openai)    ZOYSH_MODEL="gpt-5.2" ;;
        openrouter) ZOYSH_MODEL="z-ai/glm-5.2" ;;
        kimi)      ZOYSH_MODEL="kimi-k2.5" ;;
        deepseek)  ZOYSH_MODEL="deepseek-v4-flash" ;;
        qwen)      ZOYSH_MODEL="qwen-plus" ;;
        zai)       ZOYSH_MODEL="glm-5.2" ;;
    esac
}

_zoysh_resolve_key() {
    [[ -n "$ZOYSH_API_KEY" ]] && return 0
    if _zoysh_local_base_url >/dev/null; then
        ZOYSH_API_KEY="local"
        return 0
    fi

    # Accept z.ai's conventional environment variable in addition to zoysh's
    # provider-neutral ZOYSH_API_KEY. This is resolved at invocation time so a
    # key exported after the plugin was sourced is picked up immediately.
    if [[ "$ZOYSH_PROVIDER" == "zai" && -n "${ZAI_API_KEY:-}" ]]; then
        ZOYSH_API_KEY="$ZAI_API_KEY"
        return 0
    fi
    if [[ "$ZOYSH_PROVIDER" == "openrouter" && -n "${OPENROUTER_API_KEY:-}" ]]; then
        ZOYSH_API_KEY="$OPENROUTER_API_KEY"
        return 0
    fi

    local keyfile
    case "$ZOYSH_PROVIDER" in
        anthropic) keyfile="$HOME/.anthropickey" ;;
        openai)    keyfile="$HOME/.openaikey" ;;
        openrouter) keyfile="$HOME/.openrouterkey" ;;
        kimi)      keyfile="$HOME/.kimikey" ;;
        deepseek)  keyfile="$HOME/.deepseekkey" ;;
        qwen)      keyfile="$HOME/.qwenkey" ;;
        zai)       keyfile="$HOME/.zaikey" ;;
        *)         return 0 ;;
    esac
    [[ -r "$keyfile" ]] && IFS= read -r ZOYSH_API_KEY < "$keyfile"
}

_zoysh_reload_config() {
    _zoysh_reset_config
    _zoysh_load_config
    _zoysh_validate_config
    _zoysh_resolve_model
    _zoysh_resolve_key
    (( ${+functions[_zoysh_history_prune]} )) && _zoysh_history_prune
}

# ─── Provider Helpers ────────────────────────────────────────────────────────

_zoysh_api_endpoint() {
    local base
    case "$ZOYSH_PROVIDER" in
        anthropic)
            base="${ZOYSH_BASE_URL:-https://api.anthropic.com/v1}"
            print -- "${base%/}/messages" ;;
        openai)
            base="${ZOYSH_BASE_URL:-https://api.openai.com/v1}"
            print -- "${base%/}/responses" ;;
        openrouter)
            base="${ZOYSH_BASE_URL:-https://openrouter.ai/api/v1}"
            print -- "${base%/}/chat/completions" ;;
        kimi)
            base="${ZOYSH_BASE_URL:-https://api.moonshot.ai/v1}"
            print -- "${base%/}/chat/completions" ;;
        deepseek)
            base="${ZOYSH_BASE_URL:-https://api.deepseek.com}"
            print -- "${base%/}/chat/completions" ;;
        qwen)
            base="${ZOYSH_BASE_URL:-https://dashscope.aliyuncs.com/compatible-mode/v1}"
            print -- "${base%/}/chat/completions" ;;
        zai)
            base="${ZOYSH_BASE_URL:-https://api.z.ai/api/paas/v4}"
            print -- "${base%/}/chat/completions" ;;
        local)
            base="${ZOYSH_BASE_URL:-http://127.0.0.1:8001/v1}"
            print -- "${base%/}/chat/completions" ;;
    esac
}

_zoysh_local_base_url() {
    local base="$ZOYSH_BASE_URL"
    if [[ -z "$base" ]]; then
        [[ "$ZOYSH_PROVIDER" == "local" ]] || return 1
        base="http://127.0.0.1:8001/v1"
    fi

    case "${base:l}" in
        http://localhost|http://localhost/*|http://localhost:*|\
        https://localhost|https://localhost/*|https://localhost:*|\
        http://127.0.0.1|http://127.0.0.1/*|http://127.0.0.1:*|\
        https://127.0.0.1|https://127.0.0.1/*|https://127.0.0.1:*|\
        'http://[::1]'|'http://[::1]/'*|'http://[::1]:'*|\
        'https://[::1]'|'https://[::1]/'*|'https://[::1]:'*)
            print -r -- "${base%/}"
            return 0 ;;
        *) return 1 ;;
    esac
}

_zoysh_prepare_backend() {
    _ZOYSH_BACKEND_ERROR=""

    local base models_endpoint response detected
    base="$(_zoysh_local_base_url)" || return 0
    models_endpoint="${base}/models"

    response=$(curl -fsS --connect-timeout 2 --max-time 5 \
        --user-agent "zoysh/${ZOYSH_VERSION}" \
        -H "Accept: application/json" "$models_endpoint" 2>/dev/null) || {
        _ZOYSH_BACKEND_ERROR="no local model server is responding at ${base}; start the server and load a model, then try yo again"
        return 1
    }

    detected=$(printf '%s' "$response" | ZMOD="$ZOYSH_MODEL" python3 -c '
import json, os, sys

try:
    payload = json.load(sys.stdin)
    models = payload.get("data", [])
    ids = [item.get("id") for item in models if isinstance(item, dict) and isinstance(item.get("id"), str) and item.get("id")]
except (AttributeError, TypeError, ValueError):
    raise SystemExit(2)

current = os.environ.get("ZMOD", "")
if ids:
    print(current if current in ids else ids[0])
')
    local parse_status=$?

    if (( parse_status != 0 )); then
        _ZOYSH_BACKEND_ERROR="the local server at ${base} returned an invalid /models response; verify that it provides an OpenAI-compatible API"
        return 1
    fi
    if [[ -z "$detected" ]]; then
        _ZOYSH_BACKEND_ERROR="no local model is loaded at ${base}; load a model, then try yo again"
        return 1
    fi

    ZOYSH_MODEL="$detected"
}

_zoysh_build_system_prompt() {
    local os shell git_branch
    os="$(head -1 /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    os="${os:-Linux}"
    git_branch="$(git -C "${PWD}" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    <<EOF
You are a shell assistant running inside zsh ${ZSH_VERSION} on ${os}.
Working directory: ${PWD}${git_branch:+ (git: ${git_branch})}.

Respond with ONLY a JSON object:
- Shell command: {"type":"command","command":"<zsh command>","explanation":"<brief>"}
- Informational: {"type":"chat","response":"<answer>"}

Rules: output valid JSON only and never wrap it in a markdown fence. Prefer zsh syntax. Keep command explanations to 1 sentence. In chat responses, use concise terminal-friendly Markdown (headings, lists, emphasis, and code fences); avoid LaTeX and write math as readable plain text.
EOF
}

_zoysh_build_continuation_prompt() {
    <<EOF

Multi-step tasks: when several commands are needed, you may instead reply
with a fenced block tagged zoysh:plan holding one shell command per line,
with a one-line summary above the fence. The user runs each command
themselves, one at a time. Prefer a single command whenever it is enough.
EOF
}

# ─── Session Memory ──────────────────────────────────────────────────────────

_zoysh_history_estimated_tokens() {
    local LC_ALL=C
    local total=0 i
    for (( i = 1; i <= ${#ZOYSH_HISTORY_QUERIES[@]}; i++ )); do
        (( total += ${#ZOYSH_HISTORY_QUERIES[$i]} + ${#ZOYSH_HISTORY_RESPONSES[$i]} ))
    done
    REPLY=$(( total / 4 ))
}

_zoysh_history_prune() {
    while (( ${#ZOYSH_HISTORY_QUERIES[@]} > ZOYSH_HISTORY_LIMIT )); do
        shift ZOYSH_HISTORY_QUERIES ZOYSH_HISTORY_TYPES ZOYSH_HISTORY_RESPONSES
    done

    _zoysh_history_estimated_tokens
    while (( ${#ZOYSH_HISTORY_QUERIES[@]} > 0 && REPLY > ZOYSH_TOKEN_BUDGET )); do
        shift ZOYSH_HISTORY_QUERIES ZOYSH_HISTORY_TYPES ZOYSH_HISTORY_RESPONSES
        _zoysh_history_estimated_tokens
    done
}

_zoysh_history_add() {
    local query="$1" type="$2" response="$3"
    ZOYSH_HISTORY_QUERIES+=("$query")
    ZOYSH_HISTORY_TYPES+=("$type")
    ZOYSH_HISTORY_RESPONSES+=("$response")
    _zoysh_history_prune
}

_zoysh_history_clear() {
    ZOYSH_HISTORY_QUERIES=()
    ZOYSH_HISTORY_TYPES=()
    ZOYSH_HISTORY_RESPONSES=()
    print "zoysh: session memory cleared"
}

# ─── LLM Call ────────────────────────────────────────────────────────────────

_zoysh_build_request() {
    local sys_prompt="$1" query="$2" stream="${3:-0}" i
    {
        printf '%s\0%s\0' "$sys_prompt" "$query"
        for (( i = 1; i <= ${#ZOYSH_HISTORY_QUERIES[@]}; i++ )); do
            printf '%s\0%s\0%s\0' \
                "${ZOYSH_HISTORY_QUERIES[$i]}" \
                "${ZOYSH_HISTORY_TYPES[$i]}" \
                "${ZOYSH_HISTORY_RESPONSES[$i]}"
        done
    } | ZPROV="$ZOYSH_PROVIDER" ZMOD="$ZOYSH_MODEL" \
        ZMAX="$ZOYSH_MAX_OUTPUT_TOKENS" ZWEB="$ZOYSH_SERVER_WEB" \
        ZSTREAM="${stream:-0}" python3 -c '
import json, os, sys

parts = sys.stdin.buffer.read().split(b"\0")
if parts and not parts[-1]:
    parts.pop()
if len(parts) < 2 or (len(parts) - 2) % 3:
    raise SystemExit("zoysh: invalid request input")

text = lambda value: value.decode("utf-8", "replace")
system_prompt, query = map(text, parts[:2])
provider = os.environ["ZPROV"]
model = os.environ["ZMOD"]
max_output_tokens = int(os.environ["ZMAX"])
server_web = os.environ["ZWEB"] == "1"
history = []

for offset in range(2, len(parts), 3):
    old_query, reply_type, reply = map(text, parts[offset:offset + 3])
    assistant = {"type": reply_type}
    assistant["command" if reply_type == "command" else "response"] = reply
    history.extend((
        {"role": "user", "content": old_query},
        {"role": "assistant", "content": json.dumps(assistant, ensure_ascii=False, separators=(",", ":"))},
    ))

messages = history + [{"role": "user", "content": query}]
if provider == "anthropic":
    body = {
        "model": model,
        "max_tokens": max_output_tokens,
        "system": system_prompt,
        "messages": messages,
    }
    if server_web:
        body["tools"] = [
            {"type": "web_search_20250305", "name": "web_search", "max_uses": 5},
            {"type": "web_fetch_20250910", "name": "web_fetch", "max_uses": 3},
        ]
elif provider == "openai":
    body = {
        "model": model,
        "instructions": system_prompt,
        "input": messages,
        "max_output_tokens": max_output_tokens,
        "store": False,
    }
    if server_web:
        body["tools"] = [{"type": "web_search"}]
else:
    body = {
        "model": model,
        "messages": [{"role": "system", "content": system_prompt}] + messages,
        "max_tokens": max_output_tokens,
        "temperature": 0.3,
    }

if os.environ.get("ZSTREAM") == "1":
    body["stream"] = True

print(json.dumps(body, ensure_ascii=False, separators=(",", ":")))
'
}

_zoysh_http_error() {
    python3 -c '
import json, sys

raw = sys.stdin.read()
try:
    error = json.loads(raw).get("error", {})
    if isinstance(error, dict):
        message = error.get("message") or error.get("type") or str(error)
    else:
        message = str(error)
except (ValueError, AttributeError):
    message = raw.strip()
message = "".join(char for char in message if char in "\n\t" or ord(char) >= 32)
print(message[:500] or "empty response")
'
}

_zoysh_call_llm() {
    local query="$1"
    local sys_prompt endpoint
    sys_prompt="$(_zoysh_build_system_prompt)"
    (( ZOYSH_CONTINUATION )) && sys_prompt+="$(_zoysh_build_continuation_prompt)"
    endpoint="$(_zoysh_api_endpoint)"

    if ! _zoysh_local_base_url >/dev/null &&
       [[ -z "$ZOYSH_API_KEY" || "$ZOYSH_API_KEY" == "local" ]]; then
        print -r -- "missing API key for provider ${ZOYSH_PROVIDER}"
        return 1
    fi

    local request_body raw response http_status error_message
    local curl_status
    local -a curl_args

    request_body=$(_zoysh_build_request "$sys_prompt" "$query") || {
        print -r -- "failed to build API request"
        return 1
    }

    [[ $ZOYSH_DEBUG -eq 1 ]] && printf 'DEBUG body: %.200s\n' "$request_body" >&2

    curl_args=(-sS --connect-timeout 10 --max-time "$ZOYSH_TIMEOUT"
        --user-agent "zoysh/${ZOYSH_VERSION}" "$endpoint"
        -H "Content-Type: application/json" --data-binary @-
        -w $'\n%{http_code}')

    if [[ "$ZOYSH_PROVIDER" == "anthropic" && "$ZOYSH_SERVER_WEB" == 1 ]]; then
        curl_args+=(-H "anthropic-beta: web-fetch-2025-09-10")
    fi

    if [[ "$ZOYSH_PROVIDER" == "anthropic" ]]; then
        raw=$(printf '%s' "$request_body" | curl "${curl_args[@]}" \
            -H @<(printf 'x-api-key: %s\nanthropic-version: 2023-06-01\n' "$ZOYSH_API_KEY"))
    else
        raw=$(printf '%s' "$request_body" | curl "${curl_args[@]}" \
            -H @<(printf 'Authorization: Bearer %s\n' "$ZOYSH_API_KEY"))
    fi
    curl_status=$?

    if (( curl_status != 0 )); then
        print -r -- "request failed (curl exit ${curl_status})"
        return 1
    fi

    http_status="${raw##*$'\n'}"
    response="${raw%$'\n'*}"
    if [[ "$http_status" != 2[0-9][0-9] ]]; then
        error_message=$(printf '%s' "$response" | _zoysh_http_error)
        print -r -- "API request failed (HTTP ${http_status}): ${error_message}"
        return 1
    fi
    if [[ -z "$response" ]]; then
        print -r -- "API returned an empty response"
        return 1
    fi

    print -r -- "$response"
}

# ─── Cancellation ────────────────────────────────────────────────────────────
#
# While yo waits on the network, Ctrl-C must kill the helper process group,
# keep whatever output already reached the terminal, restore the prompt, and
# leave no trap residue behind. The trap returns 0 so the interrupted builtin
# unwinds and the calling function runs its own cleanup; a non-zero return
# from TRAPINT would abort the whole function before it could restore state.
# Install/restore are depth counted so yo() and the streaming call can both
# guard the same critical section.

_zoysh_trap_install() {
    if (( _ZOYSH_TRAP_DEPTH++ == 0 )); then
        # The plugin runs under "emulate -L zsh", whose sticky localtraps
        # would scope the TRAPINT definition to this very function and disarm
        # it the moment we return. Unset it so the trap arms globally.
        unsetopt localtraps
        _ZOYSH_CANCELLED=0
        _ZOYSH_HELPER_PGID=""
        _ZOYSH_OLD_TRAPINT=""
        (( ${+functions[TRAPINT]} )) && _ZOYSH_OLD_TRAPINT="${functions[TRAPINT]}"
        functions[TRAPINT]='
            if (( ! _ZOYSH_CANCELLED )); then
                _ZOYSH_CANCELLED=1
                if [[ -n "$_ZOYSH_HELPER_PGID" ]]; then
                    kill -TERM -- "-$_ZOYSH_HELPER_PGID" 2>/dev/null
                fi
            fi
            return 0
        '
    fi
}

_zoysh_trap_restore() {
    (( _ZOYSH_TRAP_DEPTH )) || return 0
    if (( --_ZOYSH_TRAP_DEPTH == 0 )); then
        unsetopt localtraps
        if [[ -n "$_ZOYSH_OLD_TRAPINT" ]]; then
            functions[TRAPINT]="$_ZOYSH_OLD_TRAPINT"
        elif (( ${+functions[TRAPINT]} )); then
            unfunction TRAPINT
        fi
        _ZOYSH_HELPER_PGID=""
    fi
}

_zoysh_print_cancelled() {
    printf '\033[90myo: cancelled\033[0m\n'
}

# ─── Streaming LLM Call ──────────────────────────────────────────────────────
#
# The streaming helper runs curl, decodes provider SSE incrementally, and
# writes NUL-terminated records to stdout for the zsh read loop:
#   P<pid>         helper process id (for cancellation)
#   D<text>        visible content delta (think blocks already suppressed)
#   H              heartbeat, resets the idle timeout without display
#   L<lines><US><col> terminal geometry occupied by the streamed deltas
#   R<json>        synthesized full provider response, byte-compatible with
#                  the non-streaming response so the shared parser applies
#   S<code>        HTTP status (non-SSE fallback path)
#   B<text>        raw body (non-SSE fallback path)
#   E<text>        transport or provider error
#   Z              end of stream

typeset -gr _ZOYSH_STREAM_HELPER='
import json, os, re, signal, subprocess, sys, tempfile, unicodedata

# Detach into our own session so the whole helper subtree (python plus curl)
# can be terminated as one process group from zsh without touching the
# interactive shell, and without receiving terminal-generated SIGINT.
try:
    os.setsid()
except OSError:
    pass

def emit(kind, payload=""):
    data = (kind + payload).encode("utf-8", "replace").replace(b"\x00", b"") + b"\x00"
    os.write(1, data)

emit("P", str(os.getpid()))

provider = os.environ["ZPROV"]
key = os.environ.get("ZKEY", "")
cols = int(os.environ.get("ZCOLS") or 80)
if cols < 10:
    cols = 80
endpoint = sys.argv[1]

body = sys.stdin.buffer.read()

if provider == "anthropic":
    header_text = "x-api-key: " + key + "\nanthropic-version: 2023-06-01\n"
    if os.environ.get("ZWEB") == "1":
        header_text += "anthropic-beta: web-fetch-2025-09-10\n"
else:
    header_text = "Authorization: Bearer " + key + "\n"
header_text = "Content-Type: application/json\n" + header_text

hdr_fd, header_path = tempfile.mkstemp(prefix="zoysh-hdr-")
os.close(hdr_fd)
auth_r, auth_w = os.pipe()
os.write(auth_w, header_text.encode("utf-8", "replace"))
os.close(auth_w)

argv = ["curl", "-sS", "--no-buffer", "--connect-timeout", "10",
        "--user-agent", "zoysh/" + os.environ.get("ZVER", "0"),
        "-D", header_path, endpoint,
        "-H", "@/dev/fd/%d" % auth_r, "--data-binary", "@-"]

p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, pass_fds=(auth_r,))

def on_signal(signum, frame):
    try:
        p.kill()
    except OSError:
        pass
    os._exit(129)

signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGINT, on_signal)

try:
    p.stdin.write(body)
    p.stdin.close()
except OSError:
    pass

OPEN_TAG = "<think>"
CLOSE_TAG = "</think>"
unsafe = re.compile("[\x00-\x08\x0b-\x1f\x7f]")
bidi = dict.fromkeys(map(ord, "\u061c\u200e\u200f\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069"), None)

def clean(text):
    return unsafe.sub("", text).translate(bidi)

think_state = "normal"
carry = ""

def suffix_overlap(text, tag):
    limit = min(len(text), len(tag) - 1)
    for size in range(limit, 0, -1):
        if text.endswith(tag[:size]):
            return size
    return 0

def feed(text):
    global think_state, carry
    buf = carry + text
    carry = ""
    out = []
    i = 0
    while i < len(buf):
        if think_state == "normal":
            j = buf.find(OPEN_TAG, i)
            if j < 0:
                keep = suffix_overlap(buf[i:], OPEN_TAG)
                cut = len(buf) - keep
                out.append(buf[i:cut])
                carry = buf[cut:]
                i = len(buf)
            else:
                out.append(buf[i:j])
                i = j + len(OPEN_TAG)
                think_state = "think"
        else:
            j = buf.find(CLOSE_TAG, i)
            if j < 0:
                keep = suffix_overlap(buf[i:], CLOSE_TAG)
                cut = len(buf) - keep
                carry = buf[cut:]
                i = len(buf)
            else:
                i = j + len(CLOSE_TAG)
                think_state = "normal"
                k = i
                while k < len(buf) and buf[k] in " \t\r\n":
                    k += 1
                i = k
    return "".join(out)

col = 0
lines = 0

def advance(text):
    global col, lines
    for ch in text:
        if ch == "\n":
            lines += 1
            col = 0
            continue
        if ch == "\t":
            col = (col // 8 + 1) * 8
        else:
            col += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if col >= cols:
            lines += 1
            col = 0

raw = ""
finish = None
stop_reason = None
resp_status = None
error_message = ""
mode = None
body_lines = []
sse_lines = []

while True:
    raw_line = p.stdout.readline()
    if not raw_line:
        break
    line = raw_line.decode("utf-8", "replace").rstrip("\r\n")
    if mode == "body":
        body_lines.append(line)
        continue
    if line == "" or line.startswith((": ", "event:", "retry:")):
        if mode == "sse":
            emit("H")
        continue
    if not line.startswith("data:"):
        mode = "body"
        body_lines.append(line)
        continue
    mode = "sse"
    sse_lines.append(line)
    payload = line[5:]
    if payload.startswith(" "):
        payload = payload[1:]
    if payload == "[DONE]":
        continue
    try:
        obj = json.loads(payload)
    except ValueError:
        emit("H")
        continue
    if not isinstance(obj, dict):
        emit("H")
        continue
    text = None
    if provider == "anthropic":
        otype = obj.get("type")
        if otype == "content_block_delta":
            delta = obj.get("delta") or {}
            if delta.get("type") == "text_delta":
                text = delta.get("text")
        elif otype == "message_delta":
            stop_reason = (obj.get("delta") or {}).get("stop_reason") or stop_reason
        elif otype == "error":
            err = obj.get("error") or {}
            error_message = "API error: " + str(err.get("message") or err)
    elif provider == "openai":
        otype = obj.get("type")
        if otype == "response.output_text.delta":
            text = obj.get("delta")
        elif otype == "response.completed":
            resp_status = "completed"
        elif otype == "response.incomplete":
            resp_status = "incomplete"
        elif otype == "error" or "error" in obj:
            err = obj.get("error") or {}
            error_message = "API error: " + str(err.get("message") or err)
    else:
        try:
            choice = obj["choices"][0]
            delta = choice.get("delta") or {}
            if isinstance(delta.get("content"), str):
                text = delta["content"]
            if choice.get("finish_reason"):
                finish = choice["finish_reason"]
            if obj.get("error"):
                err = obj["error"]
                if isinstance(err, dict):
                    error_message = "API error: " + str(err.get("message") or err)
                else:
                    error_message = "API error: " + str(err)
        except (KeyError, IndexError, TypeError):
            pass
    if error_message:
        break
    if isinstance(text, str) and text:
        raw += text
        visible = feed(clean(text))
        if visible:
            advance(visible)
            emit("D", visible)
    else:
        emit("H")

curl_rc = p.wait()
try:
    stderr_text = p.stderr.read().decode("utf-8", "replace")
except OSError:
    stderr_text = ""

status = 0
try:
    with open(header_path, "r", encoding="utf-8", errors="replace") as handle:
        for hline in handle:
            if hline.startswith("HTTP/"):
                parts = hline.split(None, 2)
                if len(parts) >= 2:
                    try:
                        status = int(parts[1])
                    except ValueError:
                        pass
except OSError:
    pass

os.close(auth_r)
try:
    os.unlink(header_path)
except OSError:
    pass

if error_message:
    emit("E", error_message)
elif curl_rc != 0:
    emit("E", "request failed (curl exit %d)" % curl_rc)
elif mode is None or mode == "body":
    emit("S", str(status))
    emit("B", "\n".join(body_lines))
elif status and not 200 <= status < 300:
    emit("S", str(status))
    emit("B", "\n".join(sse_lines))
else:
    if provider == "anthropic":
        synth = {"content": [{"type": "text", "text": raw}],
                 "stop_reason": stop_reason or "end_turn"}
    elif provider == "openai":
        synth = {"output": [{"type": "message",
                             "content": [{"type": "output_text", "text": raw}]}],
                 "status": resp_status or "completed"}
    else:
        synth = {"choices": [{"message": {"content": raw},
                              "finish_reason": finish or "stop"}]}
    emit("L", "%d\x1f%d" % (lines, col))
    emit("R", json.dumps(synth, ensure_ascii=False, separators=(",", ":")))
emit("Z")
'

_zoysh_stream_call() {
    local display="$1" query="$2"
    local endpoint sys_prompt request_body body_file rec type payload
    local raw="" http_status="" fallback_body="" error_message=""
    local disp_lines=0 disp_col=0 visible=0 saw_end=0
    local engine="script" zstyle_engine helper_pid=""
    local -i term_cols=${COLUMNS:-80}
    (( term_cols < 10 )) && term_cols=80

    zstyle -s ':zoysh:engine' engine zstyle_engine
    if [[ "$zstyle_engine" == "module" ]] && (( ${+builtins[zoysh-call]} )); then
        engine="module"
    fi

    _ZOYSH_STREAM_ERROR=""
    endpoint="$(_zoysh_api_endpoint)"

    if ! _zoysh_local_base_url >/dev/null &&
       [[ -z "$ZOYSH_API_KEY" || "$ZOYSH_API_KEY" == "local" ]]; then
        _ZOYSH_STREAM_ERROR="missing API key for provider ${ZOYSH_PROVIDER}"
        return 1
    fi

    sys_prompt="$(_zoysh_build_system_prompt)"
    (( ZOYSH_CONTINUATION )) && sys_prompt+="$(_zoysh_build_continuation_prompt)"
    request_body=$(_zoysh_build_request "$sys_prompt" "$query" 1) || {
        _ZOYSH_STREAM_ERROR="failed to build API request"
        return 1
    }

    if (( _ZOYSH_CANCELLED )); then
        _zoysh_trap_restore
        return 130
    fi

    [[ $ZOYSH_DEBUG -eq 1 ]] && printf 'DEBUG body: %.200s\n' "$request_body" >&2

    body_file="$(mktemp "${TMPDIR:-/tmp}/zoysh-body.XXXXXX")"
    printf '%s' "$request_body" > "$body_file"

    _zoysh_trap_install
    local -i sfd
    if [[ "$engine" == "module" ]]; then
        exec {sfd}< <(ZPROV="$ZOYSH_PROVIDER" ZKEY="$ZOYSH_API_KEY" \
            ZWEB="$ZOYSH_SERVER_WEB" ZCOLS="$term_cols" \
            zoysh-call "$endpoint" < "$body_file")
    else
        exec {sfd}< <(ZPROV="$ZOYSH_PROVIDER" ZKEY="$ZOYSH_API_KEY" \
            ZWEB="$ZOYSH_SERVER_WEB" ZCOLS="$term_cols" ZVER="$ZOYSH_VERSION" \
            python3 -c "$_ZOYSH_STREAM_HELPER" "$endpoint" < "$body_file")
    fi

    while IFS= read -r -t "$ZOYSH_TIMEOUT" -d '' rec <&$sfd; do
        type="${rec[1]}"
        payload="${rec[2,-1]}"
        case "$type" in
            P)
                helper_pid="$payload"
                # The script helper setsids, so its pid doubles as the
                # process group id for signal delivery. The module engine
                # runs in the shell's own group and is signalled by pid.
                if [[ "$engine" == "script" ]]; then
                    _ZOYSH_HELPER_PGID="$payload"
                fi
                ;;
            C)
                _ZOYSH_CANCELLED=1
                saw_end=1
                break
                ;;
            D)
                if [[ "$display" == "chat" ]]; then
                    printf '%s' "$payload"
                    visible=1
                fi
                ;;
            L)
                disp_lines="${payload%%$'\x1f'*}"
                disp_col="${payload#*$'\x1f'}"
                ;;
            R) raw="$payload" ;;
            S) http_status="$payload" ;;
            B) fallback_body+="$payload" ;;
            E) error_message="$payload" ;;
            Z) saw_end=1; break ;;
        esac
    done
    exec {sfd}<&-
    rm -f -- "$body_file"

    local kill_group="$_ZOYSH_HELPER_PGID"
    if (( _ZOYSH_CANCELLED )); then
        if [[ "$display" == "chat" && "$visible" == 1 ]]; then
            printf '\n'
        fi
        _zoysh_trap_restore
        return 130
    fi
    _zoysh_trap_restore

    if (( ! saw_end )); then
        if [[ -n "$kill_group" ]]; then
            kill -TERM -- "-$kill_group" 2>/dev/null
        elif [[ -n "$helper_pid" ]]; then
            kill -TERM "$helper_pid" 2>/dev/null
        fi
        _ZOYSH_STREAM_ERROR="timed out after ${ZOYSH_TIMEOUT}s without a chunk from ${ZOYSH_PROVIDER}"
        return 1
    fi

    if [[ -n "$error_message" ]]; then
        _ZOYSH_STREAM_ERROR="$error_message"
        return 1
    fi

    if [[ -n "$http_status" ]]; then
        if [[ "$http_status" != 2[0-9][0-9] ]]; then
            error_message=$(printf '%s' "$fallback_body" | _zoysh_http_error)
            _ZOYSH_STREAM_ERROR="API request failed (HTTP ${http_status}): ${error_message}"
            return 1
        fi
        if [[ -z "$fallback_body" ]]; then
            _ZOYSH_STREAM_ERROR="API returned an empty response"
            return 1
        fi
        _ZOYSH_RAW_RESPONSE="$fallback_body"
        return 0
    fi

    if [[ "$display" == "chat" && "$visible" == 1 ]]; then
        local -i occupied=$(( disp_lines + (disp_col > 0 ? 1 : 0) ))
        local -i term_lines=${LINES:-24}
        (( term_lines < 10 )) && term_lines=24
        local -i erase_limit=$(( term_lines - 2 ))
        if (( occupied <= erase_limit )); then
            if (( disp_col > 0 )); then
                printf '\r\033[K'
            fi
            local -i i
            for (( i = 0; i < disp_lines; i++ )); do
                printf '\033[A\033[2K'
            done
            printf '\r'
        else
            printf '\n'
        fi
    fi

    _ZOYSH_RAW_RESPONSE="$raw"
    return 0
}

# ─── Response Parsing ────────────────────────────────────────────────────────

_zoysh_parse_response() {
    local response="$1"
    ZRESP="$response" ZPROV="$ZOYSH_PROVIDER" python3 -c '
import json, sys, os, re

raw = os.environ["ZRESP"]
provider = os.environ["ZPROV"]

separator = "\x1e"
unsafe_controls = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
bidi_controls = dict.fromkeys(map(ord, "\u061c\u200e\u200f\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069"), None)

def emit(kind, value, explanation=""):
    fields = (kind, value, explanation)
    clean = lambda field: unsafe_controls.sub("", str(field)).translate(bidi_controls)
    sys.stdout.write(separator.join(clean(field) for field in fields))

try:
    r = json.loads(raw)
except (TypeError, ValueError):
    emit("error", "invalid API response")
    sys.exit(0)

if not isinstance(r, dict):
    emit("error", "unrecognized API response")
    sys.exit(0)

if r.get("error"):
    error = r["error"]
    message = error.get("message") or error.get("type") if isinstance(error, dict) else str(error)
    emit("error", "API error: " + str(message))
    sys.exit(0)

content = ""
truncated = False
if provider == "anthropic":
    truncated = r.get("stop_reason") == "max_tokens"
    for b in r.get("content", []):
        if isinstance(b, dict) and b.get("type") == "text":
            content += b.get("text", "")
elif provider == "openai":
    truncated = r.get("status") == "incomplete"
    for item in r.get("output", []):
        if not isinstance(item, dict):
            continue
        if item.get("type") == "message":
            for c in item.get("content", []):
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "output_text":
                    content += c.get("text", "")
                elif c.get("type") == "refusal":
                    emit("error", c.get("refusal", "request refused"))
                    sys.exit(0)
else:
    try:
        choice = r["choices"][0]
        truncated = choice.get("finish_reason") == "length"
        content = choice["message"]["content"]
        if isinstance(content, list):
            content = "".join(part.get("text", "") for part in content if isinstance(part, dict))
    except (KeyError, IndexError, TypeError):
        emit("error", "unrecognized API response")
        sys.exit(0)

# Strip <think> blocks (local reasoning models)
content = re.sub(r"<think>.*?</think>\s*", "", str(content), flags=re.DOTALL).strip()

# Multi-step plan block (only when continuation is enabled)
if os.environ.get("ZPLAN") == "1":
    plan = re.search(r"```zoysh:plan\s*\n(.*?)```", content, re.DOTALL)
    if plan:
        commands = [line.strip() for line in plan.group(1).splitlines() if line.strip()]
        summary = (content[:plan.start()] + content[plan.end():]).strip()
        if commands:
            emit("plan", "\n".join(commands), summary[:400])
            sys.exit(0)

content = re.sub(r"^```(?:json)?\s*|\s*```$", "", content, flags=re.IGNORECASE).strip()

# Parse JSON
try:
    d = json.loads(content)
    if d.get("type") == "command":
        command = d.get("command", "")
        emit("command" if command else "error", command or "model returned an empty command", d.get("explanation", ""))
    else:
        emit("chat", d.get("response", str(d)))
except (TypeError, ValueError, AttributeError):
    if truncated:
        emit("error", "model response was truncated; increase max_output_tokens")
        sys.exit(0)
    decoder = json.JSONDecoder()
    for start, char in enumerate(content):
        if char != "{":
            continue
        try:
            d, _ = decoder.raw_decode(content[start:])
            if d.get("type") == "command":
                command = d.get("command", "")
                emit("command" if command else "error", command or "model returned an empty command", d.get("explanation", ""))
            else:
                emit("chat", d.get("response", ""))
            sys.exit(0)
        except (TypeError, ValueError, AttributeError):
            pass
    emit("chat", content[:4000] if content else "(empty)")
'
}

# ─── Display ─────────────────────────────────────────────────────────────────

_zoysh_render_markdown() {
    ZBASE="$ZOYSH_COLOR_PREFIX" ZRESET="$ZOYSH_COLOR_RESET" \
    ZITALIC="$ZOYSH_ENABLE_ITALIC" ZNOITALIC="$ZOYSH_DISABLE_ITALIC" \
    ZBOLD="$ZOYSH_ENABLE_BOLD" ZNOBOLD="$ZOYSH_DISABLE_BOLD" \
    ZSTRIKE="$ZOYSH_ENABLE_STRIKETHROUGH" ZNOSTRIKE="$ZOYSH_DISABLE_STRIKETHROUGH" \
    ZCODE="$ZOYSH_CODE_DELIMITER" python3 -c '
import os, re, sys

base = os.environ["ZBASE"]
reset = os.environ["ZRESET"]
italic = os.environ["ZITALIC"]
noitalic = os.environ["ZNOITALIC"]
bold = os.environ["ZBOLD"]
nobold = os.environ["ZNOBOLD"]
strike = os.environ["ZSTRIKE"]
nostrike = os.environ["ZNOSTRIKE"]
code = os.environ["ZCODE"]

def render_inline(value):
    protected = []

    def protect(style, content):
        token = f"\uf000{len(protected)}\uf001"
        protected.append(style + content + reset + base)
        return token

    value = re.sub(r"`([^`\n]+)`", lambda m: protect(code, m.group(1)), value)
    value = re.sub(r"(?<!\\)\$(?=\S)(.+?)(?<=\S)\$", lambda m: protect(code, m.group(1)), value)
    value = re.sub(r"\*\*(?=\S)(.+?)(?<=\S)\*\*", lambda m: bold + m.group(1) + nobold, value)
    value = re.sub(r"__(?=\S)(.+?)(?<=\S)__", lambda m: bold + m.group(1) + nobold, value)
    value = re.sub(r"~~(?=\S)(.+?)(?<=\S)~~", lambda m: strike + m.group(1) + nostrike, value)
    value = re.sub(r"(?<!\*)\*(?=\S)(.+?)(?<=\S)\*(?!\*)", lambda m: italic + m.group(1) + noitalic, value)
    value = re.sub(r"\\([\\`*_{}\[\]()#+.!$-])", r"\1", value)

    for index, rendered in enumerate(protected):
        value = value.replace(f"\uf000{index}\uf001", rendered)
    return value

output = []
in_fence = False
for line in sys.stdin.read().strip("\n").split("\n"):
    stripped = line.lstrip()
    if stripped.startswith("```"):
        if in_fence:
            output.append(code + "└─" + reset + base)
            in_fence = False
        else:
            language = stripped[3:].strip()
            output.append(code + "┌─" + (f" {language}" if language else "") + reset + base)
            in_fence = True
        continue

    if in_fence:
        output.append(code + "│ " + line + reset + base)
        continue

    heading = re.match(r"^\s{0,3}#{1,6}\s+(.+)$", line)
    if heading:
        output.append(bold + render_inline(heading.group(1)) + nobold)
        continue

    bullet = re.match(r"^(\s*)[-+*]\s+(.+)$", line)
    if bullet:
        output.append(bullet.group(1) + "• " + render_inline(bullet.group(2)))
        continue

    quote = re.match(r"^\s*>\s?(.*)$", line)
    if quote:
        output.append(code + "│ " + reset + base + render_inline(quote.group(1)))
        continue

    output.append(render_inline(line))

if in_fence:
    output.append(code + "└─" + reset + base)

sys.stdout.write("\n".join(output))
'
}

_zoysh_print_chat() {
    printf '\n%s%s' "$ZOYSH_CHAT_PREFIX" "$ZOYSH_COLOR_PREFIX"
    printf '%s' "$1" | _zoysh_render_markdown
    printf '%s\n\n' "$ZOYSH_COLOR_RESET"
}

_zoysh_print_error() {
    printf '\n\033[1;31merror\033[0m \033[31m%s\033[0m\n\n' "$1"
}

_zoysh_print_command() {
    [[ -n "$2" ]] && printf '\033[90m↳ %s\033[0m\n' "$2"
}

# ─── Scrollback Ring ─────────────────────────────────────────────────────────
#
# v1 capture, per doc/pty-design.md: plan steps prefilled while
# scrollback_enabled 1 are wrapped in zoysh-run, which tees the command and
# its output into a bounded ring; later yo calls carry the ring as context.
# Ambient whole-terminal capture stays a Yosh-only feature.

_zoysh_ring_file() {
    print -r -- "${ZOYSH_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/zoysh}/scrollback"
}

_zoysh_ring_trim() {
    local ring size
    ring=$(_zoysh_ring_file)
    [[ -f "$ring" ]] || return 0
    size=$(command stat -c %s -- "$ring" 2>/dev/null) || return 0
    if (( size > ZOYSH_SCROLLBACK_BYTES )); then
        local trimmed
        trimmed="$(mktemp "${TMPDIR:-/tmp}/zoysh-ring.XXXXXX")" || return 0
        command tail -c "$ZOYSH_SCROLLBACK_BYTES" -- "$ring" > "$trimmed" 2>/dev/null && \
            command mv -f -- "$trimmed" "$ring" || command rm -f -- "$trimmed"
    fi
}

# Run one command, teeing it and its output into the scrollback ring while
# keeping the command's exit status. Used for plan steps when scrollback
# capture is enabled; users can wrap any command manually.
zoysh-run() {
    local ring
    ring=$(_zoysh_ring_file)
    mkdir -p -- "${ring:h}"
    printf '$ %s\n' "$*" >> "$ring"
    {
        eval "$@"
    } 2>&1 | command tee -a -- "$ring"
    # Capture pipestatus before any other statement; even a local
    # declaration resets it.
    _ZOYSH_RUN_STATUS=$pipestatus[1]
    _zoysh_ring_trim
    return ${_ZOYSH_RUN_STATUS}
}

_zoysh_scrollback_context() {
    (( ZOYSH_SCROLLBACK_ENABLED )) || return 0
    local ring
    ring=$(_zoysh_ring_file)
    [[ -s "$ring" ]] || return 0
    print -r -- "

(Recent commands and output captured from zoysh plan steps:)
$(<"$ring")"
}

# ─── Multi-step Plans ────────────────────────────────────────────────────────
#
# When continuation is enabled the model may answer with a fenced
# ```zoysh:plan``` block holding one command per line. zoysh prefills each
# command for the user to run; a precmd hook watches history and advances the
# queue only when the prefilled command itself was executed. zoysh never
# executes plan commands itself, and any other command typed by the user
# drops the queue silently.

typeset -gi _ZOYSH_PLAN_ARMED=0
typeset -g _ZOYSH_PLAN_STEP=0
typeset -g _ZOYSH_PLAN_QUERY=""
typeset -g _ZOYSH_PLAN_LAST_EXEC=""
typeset -g -a _ZOYSH_PLAN_CMDS

_zoysh_plan_preexec() {
    # The exact command line the user is about to run. precmd then compares
    # it with the prefilled plan step; fc cannot be used because history is
    # not yet committed when precmd hooks fire.
    _ZOYSH_PLAN_LAST_EXEC="$1"
    return 0
}

_zoysh_plan_file() {
    print -r -- "${ZOYSH_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/zoysh}/plan"
}

_zoysh_plan_load() {
    local plan_file
    plan_file=$(_zoysh_plan_file)
    [[ -f "$plan_file" ]] || return 1
    local -a lines
    lines=("${(@f)$(<"$plan_file")}")
    if (( ${#lines[@]} < 3 )); then
        command rm -f -- "$plan_file"
        return 1
    fi
    _ZOYSH_PLAN_STEP="${lines[1]#step=}"
    _ZOYSH_PLAN_QUERY="${lines[2]}"
    _ZOYSH_PLAN_CMDS=("${(@)lines[3,-1]}")
    [[ "$_ZOYSH_PLAN_STEP" == <-> ]] || return 1
    (( _ZOYSH_PLAN_STEP >= 1 && _ZOYSH_PLAN_STEP <= ${#_ZOYSH_PLAN_CMDS[@]} )) || return 1
    return 0
}

_zoysh_plan_save() {
    local plan_file
    plan_file=$(_zoysh_plan_file)
    mkdir -p -- "${plan_file:h}"
    {
        print -r -- "step=$1"
        print -r -- "$_ZOYSH_PLAN_QUERY"
        printf '%s\n' "${_ZOYSH_PLAN_CMDS[@]}"
    } > "$plan_file"
}

_zoysh_plan_prefill() {
    local step="$1"
    local cmd="${_ZOYSH_PLAN_CMDS[step]}"
    if (( ZOYSH_SCROLLBACK_ENABLED )); then
        # Scrollback capture wraps the step so its output reaches the ring;
        # the wrap stays visible in the buffer for review before Enter.
        cmd="zoysh-run ${cmd}"
    fi
    if (( _ZOYSH_ZLE_MODE )); then
        _ZOYSH_LAST_COMMAND="$cmd"
    else
        _ZOYSH_PENDING_CMD="$cmd"
    fi
    printf '\033[90mplan step %s/%s\033[0m\n' "$step" "${#_ZOYSH_PLAN_CMDS[@]}"
}

_zoysh_plan_begin() {
    local query="$1" content="$2" summary="$3"
    _ZOYSH_PLAN_QUERY="$query"
    _ZOYSH_PLAN_CMDS=("${(@f)content}")
    (( ${#_ZOYSH_PLAN_CMDS[@]} )) || return 1
    [[ -n "$summary" ]] && printf '\033[90m↳ %s\033[0m\n' "$summary"
    _zoysh_plan_save 1
    _ZOYSH_PLAN_ARMED=1
    _zoysh_plan_prefill 1
    return 0
}

_zoysh_plan_advance() {
    local next=$(( _ZOYSH_PLAN_STEP + 1 ))
    if (( next > ${#_ZOYSH_PLAN_CMDS[@]} )); then
        command rm -f -- "$(_zoysh_plan_file)"
        printf '\033[90mzoysh: plan complete\033[0m\n'
        return 0
    fi
    # No arming here: an advance from precmd needs the very next preexec/
    # precmd pair to compare the newly prefilled command. Arming is only
    # for yo invocations (plan start, --skip, --abort), whose own precmd
    # must not compare the "yo ..." line itself.
    _zoysh_plan_save "$next"
    _zoysh_plan_prefill "$next"
    return 0
}

_zoysh_plan_context() {
    _zoysh_plan_load || return 0
    local -a done_cmds remaining
    local done_text="none" remaining_text=""
    (( _ZOYSH_PLAN_STEP > 1 )) && done_cmds=("${(@)_ZOYSH_PLAN_CMDS[1,$(( _ZOYSH_PLAN_STEP - 1 ))]}")
    remaining=("${(@)_ZOYSH_PLAN_CMDS[_ZOYSH_PLAN_STEP,-1]}")
    (( ${#done_cmds[@]} )) && done_text="${(j:; :)done_cmds}"
    remaining_text="${(j:; :)remaining}"
    print -r -- "

(Context: a zoysh plan for \"${_ZOYSH_PLAN_QUERY}\" is at step ${_ZOYSH_PLAN_STEP} of ${#_ZOYSH_PLAN_CMDS[@]}. Commands already run: ${done_text}. Remaining steps: ${remaining_text}. Account for this when answering.)"
}

_zoysh_plan_precmd() {
    (( ZOYSH_CONTINUATION )) || return 0
    if (( _ZOYSH_PLAN_ARMED )); then
        # The prompt right after yo itself: the queue was just written or
        # advanced, and history still holds the yo invocation.
        _ZOYSH_PLAN_ARMED=0
        return 0
    fi
    _zoysh_plan_load || return 0
    local last="${_ZOYSH_PLAN_LAST_EXEC}"
    last="${last#"${last%%[![:space:]]*}"}"
    last="${last%"${last##*[![:space:]]}"}"
    local expected="${_ZOYSH_PLAN_CMDS[_ZOYSH_PLAN_STEP]}"
    (( ZOYSH_SCROLLBACK_ENABLED )) && expected="zoysh-run ${expected}"
    if [[ "$last" == "$expected" ]]; then
        _zoysh_plan_advance
    else
        command rm -f -- "$(_zoysh_plan_file)"
    fi
    return 0
}

# ─── yo Command ──────────────────────────────────────────────────────────────

yo() {
    local chat_mode=0
    _zoysh_reload_config
    while [[ "$1" == -* ]]; do
        case "$1" in
            -c|--chat)  chat_mode=1; shift ;;
            -h|--help)
                printf 'zoysh v%s - LLM-powered shell assistant\n\n' "$ZOYSH_VERSION"
                printf 'A zsh port of Yosh by Fil Pizlo: https://github.com/pizlonator/yosh\n\n'
                printf 'Usage:\n'
                printf '  yo <natural language>    Generate a shell command\n'
                printf '  yo -c <question>         Ask a question inline\n'
                printf '  yo --skip                Prefill the next step of an active plan\n'
                printf '  yo --abort               Drop an active multi-step plan\n'
                printf '  yo --clear               Clear session memory\n'
                printf '  yo --version             Show version\n'
                printf '  yo --help                Show this help\n\n'
                if [[ -f "$ZOYSH_CONF" ]]; then
                    printf 'Config: %s\n' "$ZOYSH_CONF"
                else
                    printf 'Config: %s (not found; using environment/defaults)\n' "$ZOYSH_CONF"
                fi
                if _zoysh_prepare_backend; then
                    printf 'Backend: %s/%s @ %s\n' "$ZOYSH_PROVIDER" "$ZOYSH_MODEL" "$(_zoysh_api_endpoint)"
                else
                    printf 'Backend: unavailable @ %s\n' "$(_zoysh_api_endpoint)"
                    printf 'Status: %s\n' "$_ZOYSH_BACKEND_ERROR"
                fi
                printf 'History: %s exchanges / ~%s tokens\n' "$ZOYSH_HISTORY_LIMIT" "$ZOYSH_TOKEN_BUDGET"
                printf 'Generation: %s tokens / %ss timeout\n' "$ZOYSH_MAX_OUTPUT_TOKENS" "$ZOYSH_TIMEOUT"
                if (( ZOYSH_STREAMING )); then
                    printf 'Streaming: enabled (idle timeout %ss per chunk)\n' "$ZOYSH_TIMEOUT"
                else
                    printf 'Streaming: disabled\n'
                fi
                if (( ZOYSH_SERVER_WEB )); then
                    printf 'Hosted web search: enabled (Anthropic/OpenAI only)\n'
                else
                    printf 'Hosted web search: disabled\n'
                fi
                if (( ZOYSH_CONTINUATION )); then
                    printf 'Continuation: multi-step plans enabled (see yo --skip and yo --abort)\n'
                else
                    printf 'Continuation: disabled (single commands only)\n'
                fi
                return 0 ;;
            --clear) _zoysh_history_clear; return 0 ;;
            --skip)
                if _zoysh_plan_load; then
                    _zoysh_plan_advance
                    # Skip the precmd that follows this yo invocation itself;
                    # the yo --skip line is not a plan command.
                    _ZOYSH_PLAN_ARMED=1
                else
                    print "zoysh: no active plan"
                    return 1
                fi
                return 0 ;;
            --abort)
                if [[ -f "$(_zoysh_plan_file)" ]]; then
                    command rm -f -- "$(_zoysh_plan_file)"
                    print "zoysh: plan aborted"
                else
                    print "zoysh: no active plan"
                    return 1
                fi
                return 0 ;;
            --version) printf 'zoysh %s\n' "$ZOYSH_VERSION"; return 0 ;;
            --debug) ZOYSH_DEBUG=1; shift ;;
            --) shift; break ;;
            *) _zoysh_print_error "unknown option: $1"; return 2 ;;
        esac
    done

    local user_query="$*" query="$*"
    [[ -z "$query" ]] && { print "Usage: yo <natural language>"; return 1 }

    (( chat_mode )) && query="Answer this (do NOT generate a command): $query"

    if (( ZOYSH_CONTINUATION )); then
        local plan_context
        plan_context=$(_zoysh_plan_context)
        [[ -n "$plan_context" ]] && query+="$plan_context"
    fi
    local scrollback_context
    scrollback_context=$(_zoysh_scrollback_context)
    [[ -n "$scrollback_context" ]] && query+="$scrollback_context"

    _zoysh_trap_install
    if ! _zoysh_prepare_backend; then
        _zoysh_trap_restore
        if (( _ZOYSH_CANCELLED )); then
            _zoysh_print_cancelled
            return 130
        fi
        _zoysh_print_error "$_ZOYSH_BACKEND_ERROR"
        return 1
    fi

    local response call_status
    if (( ZOYSH_STREAMING )); then
        local stream_display=command
        (( chat_mode )) && stream_display=chat
        if ! _zoysh_stream_call "$stream_display" "$query"; then
            _zoysh_trap_restore
            if (( _ZOYSH_CANCELLED )); then
                _zoysh_print_cancelled
                return 130
            fi
            _zoysh_print_error "$_ZOYSH_STREAM_ERROR"
            return 1
        fi
        response="$_ZOYSH_RAW_RESPONSE"
    else
        response=$(_zoysh_call_llm "$query")
        call_status=$?
        if (( _ZOYSH_CANCELLED )); then
            _zoysh_trap_restore
            _zoysh_print_cancelled
            return 130
        fi
        _zoysh_trap_restore
        if (( call_status != 0 )) || [[ -z "$response" ]]; then
            _zoysh_print_error "${response:-API call failed}"
            return 1
        fi
    fi
    _zoysh_trap_restore

    local parsed rtype rcontent rexplanation
    parsed=$(ZPLAN="$ZOYSH_CONTINUATION" _zoysh_parse_response "$response")
    rtype="${parsed%%$'\x1e'*}"
    local _rest="${parsed#*$'\x1e'}"
    rcontent="${_rest%%$'\x1e'*}"
    rexplanation="${_rest#*$'\x1e'}"

    if [[ "$rtype" == "command" ]]; then
        _zoysh_print_command "$rcontent" "$rexplanation"
        _zoysh_history_add "$user_query" "command" "$rcontent"
        _ZOYSH_LAST_COMMAND="$rcontent"
        if (( _ZOYSH_ZLE_MODE )); then
            # Inside ZLE the widget copies the command into BUFFER itself.
            :
        else
            _ZOYSH_PENDING_CMD="$rcontent"
        fi
    elif [[ "$rtype" == "plan" ]]; then
        _zoysh_history_add "$user_query" "chat" "$rcontent"
        if ! _zoysh_plan_begin "$user_query" "$rcontent" "$rexplanation"; then
            _zoysh_print_error "model returned an empty plan"
            return 1
        fi
    elif [[ "$rtype" == "error" ]]; then
        _zoysh_print_error "$rcontent"
        return 1
    else
        _zoysh_print_chat "$rcontent"
        _zoysh_history_add "$user_query" "chat" "$rcontent"
    fi
}

# ─── ZLE Widget ──────────────────────────────────────────────────────────────
#
# M-y turns the current ZLE buffer (or a mini-prompt query when the buffer is
# empty) into a generated command without ever leaving the line editor: the
# result replaces BUFFER directly. zle -U would replay the command through
# the active keymap, which corrupts commands whenever the user has widgets
# bound to ordinary characters (zsh-autosuggestions and friends), so the
# widget assigns BUFFER and CURSOR instead.

# Minimal raw-mode line reader for the widget mini-prompt. vared cannot be
# used from inside a widget (ZLE refuses recursion) and the plain read
# builtin returns immediately against ZLE's raw terminal, so the widget
# reads and echoes one character at a time.

_zoysh_widget_read() {
    local char="" query=""
    printf '%s' "$1"
    while :; do
        read -k1 -r char || { printf '\n'; return 1; }
        case "$char" in
            $'\n'|$'\r')
                printf '\n'
                REPLY="$query"
                return 0
                ;;
            $'\x7f'|$'\b')
                if (( ${#query} )); then
                    query="${query[1,-2]}"
                    printf '\b \b'
                fi
                ;;
            $'\x03')
                printf '\n'
                return 130
                ;;
            $'\x15')
                while (( ${#query} )); do
                    query="${query[1,-2]}"
                    printf '\b \b'
                done
                ;;
            $'\x1b')
                read -k1 -r -t 0.01 char 2>/dev/null
                if [[ "$char" == "[" || "$char" == "O" ]]; then
                    read -k1 -r -t 0.01 char 2>/dev/null
                fi
                ;;
            *)
                query+="$char"
                printf '%s' "$char"
                ;;
        esac
    done
}

_zoysh_widget() {
    local query
    if [[ -n "$NUMERIC" || -n "$BUFFER" ]]; then
        query="$BUFFER"
    else
        zle -I
        _zoysh_widget_read "${ZOYSH_CHAT_PREFIX%%$'\n'}query: "
        case $? in
            0) query="$REPLY" ;;
            *) return 0 ;;
        esac
        [[ -z "$query" ]] && return 0
    fi

    _ZOYSH_ZLE_MODE=1
    zle -I
    yo "$query"
    local yo_status=$?
    _ZOYSH_ZLE_MODE=0

    if (( yo_status == 0 )) && [[ -n "$_ZOYSH_LAST_COMMAND" ]]; then
        BUFFER="$_ZOYSH_LAST_COMMAND"
        CURSOR=${#BUFFER}
    fi
    zle reset-prompt
    return 0
}

_zoysh_register_widget() {
    (( ${+widgets[zoysh-widget]} )) || zle -N zoysh-widget _zoysh_widget
    local bind_default
    zstyle -s ':zoysh:widget' bind bind_default
    [[ "$bind_default" == "no" ]] && return 0
    bindkey -M emacs '\ey' zoysh-widget
    bindkey -M viins '\ey' zoysh-widget
}

# Prefill the next prompt for review. print -z pushes onto the input stack,
# which zsh reads as the next command line and executes without any chance
# to review; the zle-line-init hook below instead places the text into the
# editor buffer so the user presses Enter (or edits) to run it.

_zoysh_line_init() {
    if [[ -n "$_ZOYSH_PENDING_CMD" ]]; then
        BUFFER="$_ZOYSH_PENDING_CMD"
        CURSOR=${#BUFFER}
        _ZOYSH_PENDING_CMD=""
    fi
    if [[ -n "$_ZOYSH_LINE_INIT_PREV_FUNC" ]]; then
        "${_ZOYSH_LINE_INIT_PREV_FUNC}" "$@"
    fi
    return 0
}

_zoysh_register_prefill() {
    if (( ${+widgets[zle-line-init]} )); then
        local previous="${widgets[zle-line-init]}"
        local -a words
        words=("${(z)previous}")
        [[ "${words[1]}" == builtin:* || "${words[1]}" == completion:* ]] ||
            _ZOYSH_LINE_INIT_PREV_FUNC="${words[1]}"
    fi
    zle -N zle-line-init _zoysh_line_init
}

# ─── Init ────────────────────────────────────────────────────────────────────

_zoysh_reload_config
_zoysh_register_widget
_zoysh_register_prefill
(( ${precmd_functions[(Ie)_zoysh_plan_precmd]} )) || precmd_functions+=(_zoysh_plan_precmd)
(( ${preexec_functions[(Ie)_zoysh_plan_preexec]} )) || preexec_functions+=(_zoysh_plan_preexec)

# Completion
_yo() {
    _arguments \
        '-c[ask a question]:question:' \
        '--chat[ask a question]:question:' \
        '--clear[clear session memory]' \
        '--skip[prefill the next plan step]' \
        '--abort[drop the active plan]' \
        '--version[show version]' \
        '--debug[show request diagnostics]' \
        '--help[show help]' \
        '*:natural language query:'
}
(( ${+functions[compdef]} )) && compdef _yo yo

return 0
