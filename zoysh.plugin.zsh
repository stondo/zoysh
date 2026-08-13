#!/bin/zsh
# zoysh.plugin.zsh — LLM-powered shell assistant for zsh
# Port of yosh (github.com/pizlonator/yosh) to zsh
#
# Install (plugin managers):
#   zinit:   zinit light stondo/zoysh
#   antidote: echo "stondo/zoysh" >> ~/.zsh_plugins.txt
#   manual:  source /path/to/zoysh.plugin.zsh
#
# Config in ~/.yoconf (same format as yosh):
#   provider qwen
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

# JSON backend: jq preferred (faster), python3 fallback
typeset -g _ZOYSH_JSON_BACKEND=""
if command -v jq >/dev/null 2>&1; then
    _ZOYSH_JSON_BACKEND="jq"
elif command -v python3 >/dev/null 2>&1; then
    _ZOYSH_JSON_BACKEND="python3"
else
    printf 'zoysh: requires jq or python3 for JSON parsing\n' >&2
    return 1
fi

# ─── Constants ────────────────────────────────────────────────────────────────

typeset -g ZOYSH_VERSION="0.2.0"
typeset -g ZOYSH_CONF="${HOME}/.yoconf"
typeset -g ZOYSH_HISTORY_LIMIT=10
typeset -g ZOYSH_TOKEN_BUDGET=4096
typeset -gi ZOYSH_DEBUG=0

# Session memory
typeset -ga ZOYSH_HISTORY_QUERIES
typeset -ga ZOYSH_HISTORY_TYPES
typeset -ga ZOYSH_HISTORY_RESPONSES
typeset -ga ZOYSH_HISTORY_EXECUTED

# ─── Config ───────────────────────────────────────────────────────────────────

typeset -g ZOYSH_PROVIDER="qwen"
typeset -g ZOYSH_MODEL="qwythos-9b-v2-mtp"
typeset -g ZOYSH_BASE_URL="http://127.0.0.1:8001/v1"
typeset -g ZOYSH_API_KEY="local"

_zoysh_load_config() {
    [[ -f "$ZOYSH_CONF" ]] || return 0
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        key="${line%% *}"
        val="${line#* }"
        val="${val#"${val%%[![:space:]]*}"}"
        case "$key" in
            provider)      ZOYSH_PROVIDER="$val" ;;
            model)         ZOYSH_MODEL="$val" ;;
            base_url)      ZOYSH_BASE_URL="$val" ;;
            key)           ZOYSH_API_KEY="$val" ;;
            history_limit) ZOYSH_HISTORY_LIMIT="$val" ;;
            token_budget)  ZOYSH_TOKEN_BUDGET="$val" ;;
        esac
    done < "$ZOYSH_CONF"
}

_zoysh_resolve_key() {
    [[ "$ZOYSH_API_KEY" != "local" && -n "$ZOYSH_API_KEY" ]] && return 0
    local keyfile
    case "$ZOYSH_PROVIDER" in
        anthropic) keyfile="$HOME/.anthropickey" ;;
        openai)    keyfile="$HOME/.openaikey" ;;
        kimi)      keyfile="$HOME/.kimikey" ;;
        deepseek)  keyfile="$HOME/.deepseekkey" ;;
        qwen)      keyfile="$HOME/.qwenkey" ;;
        zai)       keyfile="$HOME/.zaikey" ;;
        *)         keyfile="$HOME/.yoshkey" ;;
    esac
    [[ -f "$keyfile" ]] && ZOYSH_API_KEY="$(head -1 "$keyfile" 2>/dev/null)"
}

# ─── Provider Helpers ────────────────────────────────────────────────────────

_zoysh_api_endpoint() {
    case "$ZOYSH_PROVIDER" in
        anthropic) print -- "${ZOYSH_BASE_URL:-https://api.anthropic.com/v1}/messages" ;;
        openai)    print -- "${ZOYSH_BASE_URL:-https://api.openai.com/v1}/responses" ;;
        *)         local b="${ZOYSH_BASE_URL:-http://127.0.0.1:8001/v1}"; print -- "${b%/}/chat/completions" ;;
    esac
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

Rules: valid JSON only. No markdown. Prefer zsh syntax. Keep explanations to 1 sentence.
EOF
}

# ─── Session Memory ──────────────────────────────────────────────────────────

_zoysh_history_add() {
    local query="$1" type="$2" response="$3" executed="${4:-0}"
    ZOYSH_HISTORY_QUERIES+=("$query")
    ZOYSH_HISTORY_TYPES+=("$type")
    ZOYSH_HISTORY_RESPONSES+=("$response")
    ZOYSH_HISTORY_EXECUTED+=("$executed")
    while (( ${#ZOYSH_HISTORY_QUERIES[@]} > ZOYSH_HISTORY_LIMIT )); do
        shift ZOYSH_HISTORY_QUERIES ZOYSH_HISTORY_TYPES ZOYSH_HISTORY_RESPONSES ZOYSH_HISTORY_EXECUTED
    done
}

_zoysh_history_clear() {
    ZOYSH_HISTORY_QUERIES=()
    ZOYSH_HISTORY_TYPES=()
    ZOYSH_HISTORY_RESPONSES=()
    ZOYSH_HISTORY_EXECUTED=()
    print "zoysh: session memory cleared"
}

# ─── LLM Call ────────────────────────────────────────────────────────────────

_zoysh_call_llm() {
    local query="$1"
    local sys_prompt endpoint
    sys_prompt="$(_zoysh_build_system_prompt)"
    endpoint="$(_zoysh_api_endpoint)"

    # Build messages + request body in a single python3/jq pipeline
    local request_body response
    local -a curl_args

    # Construct auth headers WITHOUT leaking key into visible variables
    curl_args=(-s --max-time 30 "$endpoint" -H "Content-Type: application/json")
    if [[ "$ZOYSH_PROVIDER" == "anthropic" ]]; then
        curl_args+=(-H "x-api-key: ${ZOYSH_API_KEY}" -H "anthropic-version: 2023-06-01")
    else
        curl_args+=(-H "Authorization: Bearer ${ZOYSH_API_KEY}")
    fi

    # Build request body via python3 (always needed for multi-provider formatting)
    request_body=$(ZSYS="$sys_prompt" ZQ="$query" ZPROV="$ZOYSH_PROVIDER" ZMOD="$ZOYSH_MODEL" \
        ZHIST_Q="${(j:|:)ZOYSH_HISTORY_QUERIES}" \
        python3 -c '
import json, os, sys

sys_prompt = os.environ["ZSYS"]
query = os.environ["ZQ"]
provider = os.environ["ZPROV"]
model = os.environ["ZMOD"]

messages = [{"role": "system", "content": sys_prompt}]
messages.append({"role": "user", "content": query})

if provider == "anthropic":
    sys_msg = ""
    chat = []
    for m in messages:
        if m["role"] == "system": sys_msg = m["content"]
        else: chat.append(m)
    body = {"model": model, "max_tokens": 1024, "system": sys_msg, "messages": chat}
elif provider == "openai":
    sys_msg = ""
    chat = []
    for m in messages:
        if m["role"] == "system": sys_msg = m["content"]
        else: chat.append(m)
    body = {"model": model, "instructions": sys_msg, "input": chat, "max_output_tokens": 1024}
else:
    body = {"model": model, "messages": messages, "max_tokens": 1024, "temperature": 0.3}

print(json.dumps(body))
' 2>&1)

    [[ $ZOYSH_DEBUG -eq 1 ]] && printf 'DEBUG body: %.200s\n' "$request_body" >&2

    curl_args+=(-d "$request_body")
    response=$(curl "${curl_args[@]}" 2>/dev/null)

    if [[ $? -ne 0 || -z "$response" ]]; then
        printf '{"error":"request failed (%s)"}\n' "$endpoint"
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

try:
    r = json.loads(raw)
except:
    print("chat\nError: invalid API response")
    sys.exit(0)

content = ""
if provider == "anthropic":
    for b in r.get("content", []):
        if b.get("type") == "text": content = b["text"]; break
elif provider == "openai":
    for item in r.get("output", []):
        if item.get("type") == "message":
            for c in item.get("content", []):
                if c.get("type") == "output_text": content = c["text"]; break
            break
else:
    try: content = r["choices"][0]["message"]["content"]
    except:
        err = r.get("error", {})
        msg = err.get("message", str(r)[:200]) if isinstance(err, dict) else str(err)[:200]
        print("chat\nAPI error: " + msg)
        sys.exit(0)

# Strip <think> blocks (local reasoning models)
content = re.sub(r"<think>.*?</think>\s*", "", content, flags=re.DOTALL).strip()

# Parse JSON
try:
    d = json.loads(content)
    if d.get("type") == "command":
        print("command")
        print(d.get("command", ""))
        print(d.get("explanation", ""))
    else:
        print("chat")
        print(d.get("response", str(d)))
except:
    # Fallback: extract first JSON object
    m = re.search(r"\{[^{}]*\}", content)
    if m:
        try:
            d = json.loads(m.group())
            if d.get("type") == "command":
                print("command\n" + d.get("command","") + "\n" + d.get("explanation",""))
            else:
                print("chat\n" + d.get("response",""))
            sys.exit(0)
        except: pass
    print("chat")
    print(content[:500] if content else "(empty)")
'
}

# ─── Display ─────────────────────────────────────────────────────────────────

_zoysh_print_chat()   { printf '\n\033[3;36m%s\033[0m\n\n' "$1" }
_zoysh_print_error()  { printf '\n\033[31mzoysh: %s\033[0m\n\n' "$1" }
_zoysh_print_command() { [[ -n "$2" ]] && printf '\033[90m%s\033[0m\n' "$2" }

_zoysh_thinking_animation() {
    {
        local frames="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" i=0
        while true; do
            printf '\r\033[3;36myo\033[0m \033[90m%s thinking...\033[0m' "${frames:$((i % 10)):1}" >&2
            ((i++)); sleep 0.08
        done
    } &
    ZOYSH_SPINNER_PID=$!
}

_zoysh_stop_spinner() {
    [[ -n "${ZOYSH_SPINNER_PID:-}" ]] && {
        kill "$ZOYSH_SPINNER_PID" 2>/dev/null
        wait "$ZOYSH_SPINNER_PID" 2>/dev/null
        unset ZOYSH_SPINNER_PID
        printf '\r\033[K' >&2
    }
}

# ─── yo Command ──────────────────────────────────────────────────────────────

yo() {
    local chat_mode=0
    while [[ "$1" == -* ]]; do
        case "$1" in
            -c|--chat)  chat_mode=1; shift ;;
            -h|--help)
                printf 'zoysh v%s — LLM-powered shell assistant\n\n' "$ZOYSH_VERSION"
                printf 'Usage:\n'
                printf '  yo <natural language>    Generate a shell command\n'
                printf '  yo -c <question>         Ask a question inline\n'
                printf '  yo --clear               Clear session memory\n'
                printf '  yo --help                Show this help\n\n'
                printf 'Config: ~/.yoconf\n'
                printf 'Backend: %s/%s @ %s\n' "$ZOYSH_PROVIDER" "$ZOYSH_MODEL" "$ZOYSH_BASE_URL"
                printf 'JSON: %s\n' "$_ZOYSH_JSON_BACKEND"
                return 0 ;;
            --clear) _zoysh_history_clear; return 0 ;;
            --debug) ZOYSH_DEBUG=1; shift ;;
            *) break ;;
        esac
    done

    local query="$*"
    [[ -z "$query" ]] && { print "Usage: yo <natural language>"; return 1 }

    (( chat_mode )) && query="Answer this (do NOT generate a command): $query"

    _zoysh_thinking_animation
    local response
    response=$(_zoysh_call_llm "$query")
    _zoysh_stop_spinner

    if [[ -z "$response" ]] || [[ "$response" == *"\"error\""* ]]; then
        local err
        err=$(print -r -- "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null)
        _zoysh_print_error "${err:-API call failed}"
        return 1
    fi

    local parsed rtype rcontent rexplanation
    parsed=$(_zoysh_parse_response "$response")
    rtype="${parsed%%$'\n'*}"
    local _rest="${parsed#*$'\n'}"
    rcontent="${_rest%%$'\n'*}"

    if [[ "$rtype" == "command" ]]; then
        rexplanation="${_rest#*$'\n'}"
        _zoysh_print_command "$rcontent" "$rexplanation"
        _zoysh_history_add "$query" "command" "$rcontent" 0
        print -z "$rcontent"
    else
        _zoysh_print_chat "$rcontent"
        _zoysh_history_add "$query" "chat" "$rcontent" 0
    fi
}

_zoysh_preexec() {
    local last_idx=${#ZOYSH_HISTORY_TYPES[@]}
    if (( last_idx > 0 )) && [[ "${ZOYSH_HISTORY_TYPES[$last_idx]}" == "command" ]]; then
        ZOYSH_HISTORY_EXECUTED[$last_idx]=1
    fi
}

# ─── Init ────────────────────────────────────────────────────────────────────

_zoysh_load_config
_zoysh_resolve_key

autoload -Uz add-zsh-hook
add-zsh-hook preexec _zoysh_preexec

# Completion
_yo() {
    _arguments \
        '-c[ask a question]:question:' \
        '--chat[ask a question]:question:' \
        '--clear[clear session memory]' \
        '--help[show help]' \
        '*:natural language query:'
}
compdef _yo yo 2>/dev/null
