#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Stefano Tondo
# zoysh.plugin.zsh — LLM-powered shell assistant for zsh
# Port of yosh (github.com/pizlonator/yosh) to zsh
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

typeset -g ZOYSH_VERSION="0.3.0"
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
        local|anthropic|openai|kimi|deepseek|qwen|zai) ;;
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
        printf 'zoysh: scrollback capture requires the planned native module and is unavailable in the script plugin\n' >&2
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

    local keyfile
    case "$ZOYSH_PROVIDER" in
        anthropic) keyfile="$HOME/.anthropickey" ;;
        openai)    keyfile="$HOME/.openaikey" ;;
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
    local sys_prompt="$1" query="$2" i
    {
        printf '%s\0%s\0' "$sys_prompt" "$query"
        for (( i = 1; i <= ${#ZOYSH_HISTORY_QUERIES[@]}; i++ )); do
            printf '%s\0%s\0%s\0' \
                "${ZOYSH_HISTORY_QUERIES[$i]}" \
                "${ZOYSH_HISTORY_TYPES[$i]}" \
                "${ZOYSH_HISTORY_RESPONSES[$i]}"
        done
    } | ZPROV="$ZOYSH_PROVIDER" ZMOD="$ZOYSH_MODEL" \
        ZMAX="$ZOYSH_MAX_OUTPUT_TOKENS" ZWEB="$ZOYSH_SERVER_WEB" python3 -c '
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

# ─── yo Command ──────────────────────────────────────────────────────────────

yo() {
    local chat_mode=0
    _zoysh_reload_config
    while [[ "$1" == -* ]]; do
        case "$1" in
            -c|--chat)  chat_mode=1; shift ;;
            -h|--help)
                printf 'zoysh v%s — LLM-powered shell assistant\n\n' "$ZOYSH_VERSION"
                printf 'Usage:\n'
                printf '  yo <natural language>    Generate a shell command\n'
                printf '  yo -c <question>         Ask a question inline\n'
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
                if (( ZOYSH_SERVER_WEB )); then
                    printf 'Hosted web search: enabled (Anthropic/OpenAI only)\n'
                else
                    printf 'Hosted web search: disabled\n'
                fi
                return 0 ;;
            --clear) _zoysh_history_clear; return 0 ;;
            --version) printf 'zoysh %s\n' "$ZOYSH_VERSION"; return 0 ;;
            --debug) ZOYSH_DEBUG=1; shift ;;
            --) shift; break ;;
            *) _zoysh_print_error "unknown option: $1"; return 2 ;;
        esac
    done

    local user_query="$*" query="$*"
    [[ -z "$query" ]] && { print "Usage: yo <natural language>"; return 1 }

    (( chat_mode )) && query="Answer this (do NOT generate a command): $query"

    if ! _zoysh_prepare_backend; then
        _zoysh_print_error "$_ZOYSH_BACKEND_ERROR"
        return 1
    fi

    local response call_status
    response=$(_zoysh_call_llm "$query")
    call_status=$?

    if (( call_status != 0 )) || [[ -z "$response" ]]; then
        _zoysh_print_error "${response:-API call failed}"
        return 1
    fi

    local parsed rtype rcontent rexplanation
    parsed=$(_zoysh_parse_response "$response")
    rtype="${parsed%%$'\x1e'*}"
    local _rest="${parsed#*$'\x1e'}"
    rcontent="${_rest%%$'\x1e'*}"
    rexplanation="${_rest#*$'\x1e'}"

    if [[ "$rtype" == "command" ]]; then
        _zoysh_print_command "$rcontent" "$rexplanation"
        _zoysh_history_add "$user_query" "command" "$rcontent"
        print -z "$rcontent"
    elif [[ "$rtype" == "error" ]]; then
        _zoysh_print_error "$rcontent"
        return 1
    else
        _zoysh_print_chat "$rcontent"
        _zoysh_history_add "$user_query" "chat" "$rcontent"
    fi
}

# ─── Init ────────────────────────────────────────────────────────────────────

_zoysh_reload_config

# Completion
_yo() {
    _arguments \
        '-c[ask a question]:question:' \
        '--chat[ask a question]:question:' \
        '--clear[clear session memory]' \
        '--version[show version]' \
        '--debug[show request diagnostics]' \
        '--help[show help]' \
        '*:natural language query:'
}
(( ${+functions[compdef]} )) && compdef _yo yo

return 0
