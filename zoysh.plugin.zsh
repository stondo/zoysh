#!/bin/zsh
# zoysh.plugin.zsh — LLM-powered shell assistant for zsh
# Port of yosh (pizlonator/yosh) readline+bash LLM integration to zsh ZLE
#
# Phase 1 MVP: Pure zsh script providing `yo` command
# Phase 2 (planned): C loadable zsh module for native integration
#
# Usage in ~/.zshrc:
#   source /path/to/zoysh.plugin.zsh
#
# Config in ~/.yoconf (same format as yosh):
#   provider qwen
#   model qwythos-9b-v2-mtp
#   base_url http://127.0.0.1:8001/v1/
#   key local

emulate -L zsh

# ─── Constants ────────────────────────────────────────────────────────────────

typeset -g ZOYSH_VERSION="0.1.0"
typeset -g ZOYSH_CONF="${HOME}/.yoconf"
typeset -g ZOYSH_HISTORY_LIMIT=10
typeset -g ZOYSH_TOKEN_BUDGET=4096
typeset -gi ZOYSH_DEBUG=0

# Session memory: parallel arrays for conversation context
typeset -ga ZOYSH_HISTORY_QUERIES
typeset -ga ZOYSH_HISTORY_TYPES      # "command" or "chat"
typeset -ga ZOYSH_HISTORY_RESPONSES
typeset -ga ZOYSH_HISTORY_EXECUTED   # "1" if executed, "0" if not

# ─── Config Loading ──────────────────────────────────────────────────────────

# Default config — local Qwythos-9B as safe default
typeset -g ZOYSH_PROVIDER="qwen"
typeset -g ZOYSH_MODEL="qwythos-9b-v2-mtp"
typeset -g ZOYSH_BASE_URL="http://127.0.0.1:8001/v1"
typeset -g ZOYSH_API_KEY="local"
typeset -g ZOYSH_SYSTEM_PROMPT=""

_zoysh_load_config() {
    [[ -f "$ZOYSH_CONF" ]] || return 0

    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"           # strip comments
        line="${line#"${line%%[![:space:]]*}"}"  # ltrim
        line="${line%"${line##*[![:space:]]}"}"  # rtrim
        [[ -z "$line" ]] && continue

        key="${line%% *}"
        val="${line#* }"
        val="${val#"${val%%[![:space:]]*}"}"  # ltrim val

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

# Try key files if no key in config
_zoysh_resolve_key() {
    if [[ "$ZOYSH_API_KEY" != "local" && -n "$ZOYSH_API_KEY" ]]; then
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
        *)         keyfile="$HOME/.yoshkey" ;;
    esac

    if [[ -f "$keyfile" ]]; then
        ZOYSH_API_KEY="$(head -1 "$keyfile" 2>/dev/null)"
    fi
}

# ─── Provider URL Building ───────────────────────────────────────────────────

_zoysh_api_endpoint() {
    case "$ZOYSH_PROVIDER" in
        anthropic)
            echo "${ZOYSH_BASE_URL:-https://api.anthropic.com/v1}/messages"
            ;;
        openai)
            echo "${ZOYSH_BASE_URL:-https://api.openai.com/v1}/responses"
            ;;
        qwen|kimi|deepseek|zai)
            local base="${ZOYSH_BASE_URL:-http://127.0.0.1:8001/v1}"
            echo "${base%/}/chat/completions"
            ;;
        *)
            echo "${ZOYSH_BASE_URL}/chat/completions"
            ;;
    esac
}

_zoysh_api_headers() {
    case "$ZOYSH_PROVIDER" in
        anthropic)
            echo "-H" "Content-Type: application/json"
            echo "-H" "x-api-key: ${ZOYSH_API_KEY}"
            echo "-H" "anthropic-version: 2023-06-01"
            ;;
        openai|qwen|kimi|deepseek|zai|*)
            echo "-H" "Content-Type: application/json"
            echo "-H" "Authorization: Bearer ${ZOYSH_API_KEY}"
            ;;
    esac
}

# ─── System Prompt ───────────────────────────────────────────────────────────

_zoysh_build_system_prompt() {
    local os shell pwd_contents git_branch

    os="$(head -1 /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    os="${os:-Linux}"
    shell="zsh ${ZSH_VERSION}"
    git_branch="$(git -C "${PWD}" rev-parse --abbrev-ref HEAD 2>/dev/null)"

    cat <<EOF
You are a shell assistant running inside zsh on ${os}.
The user's shell is ${shell}, working directory is ${PWD}${git_branch:+ (git branch: ${git_branch})}.

When the user asks a question, respond with a JSON object:
- For a shell command: {"type":"command","command":"<the command>","explanation":"<brief explanation>"}
- For an informational answer: {"type":"chat","response":"<your answer>"}

Rules:
- Output ONLY valid JSON, no markdown fences, no text before or after.
- Commands must be complete and ready to execute in zsh.
- Prefer zsh syntax over bash where they differ.
- If the user asks a question (not a command request), use "chat" type.
- Keep explanations concise (1-2 sentences).
EOF
}

# ─── Session Memory ──────────────────────────────────────────────────────────

_zoysh_history_add() {
    local query="$1" type="$2" response="$3" executed="${4:-0}"

    ZOYSH_HISTORY_QUERIES+=("$query")
    ZOYSH_HISTORY_TYPES+=("$type")
    ZOYSH_HISTORY_RESPONSES+=("$response")
    ZOYSH_HISTORY_EXECUTED+=("$executed")

    # Prune to history_limit
    while (( ${#ZOYSH_HISTORY_QUERIES[@]} > ZOYSH_HISTORY_LIMIT )); do
        shift ZOYSH_HISTORY_QUERIES
        shift ZOYSH_HISTORY_TYPES
        shift ZOYSH_HISTORY_RESPONSES
        shift ZOYSH_HISTORY_EXECUTED
    done
}

_zoysh_history_build_messages() {
    local current_query="$1"
    local sys_prompt
    sys_prompt="$(_zoysh_build_system_prompt)"

    # Build messages entirely in python3 — avoids shell quoting/escaping issues
    # Pass history via stdin (newline-delimited), query via argv
    local hist_data=""
    local count=${#ZOYSH_HISTORY_QUERIES[@]}
    if (( count > 0 )); then
        local i
        for ((i=1; i<=count; i++)); do
            hist_data+="${ZOYSH_HISTORY_QUERIES[$i]}"$'\n'
            hist_data+="${ZOYSH_HISTORY_TYPES[$i]}"$'\n'
            hist_data+="${ZOYSH_HISTORY_RESPONSES[$i]}"$'\n'
            hist_data+="${ZOYSH_HISTORY_EXECUTED[$i]}"$'\n'
        done
    fi

    python3 -c '
import json, sys, os

query = sys.argv[1]
sys_prompt = sys.argv[2]
provider = sys.argv[3]

messages = [{"role": "system", "content": sys_prompt}]

# Parse history from stdin
hist = sys.stdin.read().strip()
if hist:
    lines = hist.split("\n")
    i = 0
    while i + 3 < len(lines):
        q, t, r, e = lines[i], lines[i+1], lines[i+2], lines[i+3]
        i += 4
        messages.append({"role": "user", "content": q})
        if t == "command":
            content = f"Command suggested: {r}"
            if e == "1":
                content += " (executed)"
        else:
            content = r
        messages.append({"role": "assistant", "content": content})

messages.append({"role": "user", "content": query})
print(json.dumps(messages))
' "$current_query" "$sys_prompt" "$ZOYSH_PROVIDER" <<<"$hist_data"
}

_zoysh_history_clear() {
    ZOYSH_HISTORY_QUERIES=()
    ZOYSH_HISTORY_TYPES=()
    ZOYSH_HISTORY_RESPONSES=()
    ZOYSH_HISTORY_EXECUTED=()
    echo "zoysh: session memory cleared"
}

# ─── LLM API Call ────────────────────────────────────────────────────────────

_zoysh_call_llm() {
    local query="$1"
    local messages_json
    messages_json="$(_zoysh_history_build_messages "$query")"

    local endpoint
    endpoint="$(_zoysh_api_endpoint)"

    # Build request body in python3 — provider-specific formatting
    local request_body
    request_body=$(python3 -c '
import json, sys

provider = sys.argv[1]
model = sys.argv[2]
messages = json.loads(sys.argv[3])

if provider == "anthropic":
    sys_msg = ""
    chat_msgs = []
    for m in messages:
        if m["role"] == "system":
            sys_msg = m["content"]
        else:
            chat_msgs.append(m)
    body = {
        "model": model,
        "max_tokens": 1024,
        "system": sys_msg,
        "messages": chat_msgs,
    }
elif provider == "openai":
    sys_msg = ""
    chat_items = []
    for m in messages:
        if m["role"] == "system":
            sys_msg = m["content"]
        else:
            chat_items.append(m)
    body = {
        "model": model,
        "instructions": sys_msg,
        "input": chat_items,
        "max_output_tokens": 1024,
    }
else:
    # Chat Completions API (qwen, kimi, deepseek, zai, local)
    body = {
        "model": model,
        "messages": messages,
        "max_tokens": 1024,
        "temperature": 0.3,
    }

print(json.dumps(body))
' "$ZOYSH_PROVIDER" "$ZOYSH_MODEL" "$messages_json" 2>&1)

    if [[ $ZOYSH_DEBUG -eq 1 ]]; then
        echo "DEBUG endpoint: $endpoint" >&2
        echo "DEBUG body: ${request_body:0:200}" >&2
    fi

    local response
    local -a curl_args
    curl_args=(-s --max-time 30 "$endpoint" -H "Content-Type: application/json")

    if [[ "$ZOYSH_PROVIDER" == "anthropic" ]]; then
        curl_args+=(-H "x-api-key: ${ZOYSH_API_KEY}" -H "anthropic-version: 2023-06-01")
    else
        curl_args+=(-H "Authorization: Bearer ${ZOYSH_API_KEY}")
    fi
    curl_args+=(-d "$request_body")

    response=$(curl "${curl_args[@]}" 2>/dev/null)

    if [[ $? -ne 0 || -z "$response" ]]; then
        echo "{\"error\":\"curl request failed (endpoint: $endpoint)\"}"
        return 1
    fi

    print -r -- "$response"
}

# ─── Response Parsing ────────────────────────────────────────────────────────

_zoysh_parse_response() {
    local response="$1"
    local provider="$ZOYSH_PROVIDER"

    python3 -c '
import json, sys, re

provider = sys.argv[1]
raw = sys.stdin.read()

try:
    r = json.loads(raw)
except:
    print("chat")
    print("Error: could not parse API response")
    sys.exit(0)

content = ""
if provider == "anthropic":
    for block in r.get("content", []):
        if block.get("type") == "text":
            content = block["text"]
            break
elif provider == "openai":
    for item in r.get("output", []):
        if item.get("type") == "message":
            for c in item.get("content", []):
                if c.get("type") == "output_text":
                    content = c["text"]
                    break
            break
else:
    try:
        content = r["choices"][0]["message"]["content"]
    except:
        err = r.get("error", {})
        print("chat")
        msg = err.get("message", str(r)[:200]) if isinstance(err, dict) else str(err)[:200]
        print("API error: " + msg)
        sys.exit(0)

content = re.sub(r"<think>.*?</think>\s*", "", content, flags=re.DOTALL).strip()

try:
    d = json.loads(content)
    if d.get("type") == "command":
        print("command")
        print(d.get("command", ""))
        print(d.get("explanation", ""))
    else:
        print("chat")
        print(d.get("response", d.get("content", str(d))))
except json.JSONDecodeError:
    match = re.search(r"\{[^{}]*\}", content)
    if match:
        try:
            d = json.loads(match.group())
            if d.get("type") == "command":
                print("command")
                print(d.get("command", ""))
                print(d.get("explanation", ""))
            else:
                print("chat")
                print(d.get("response", ""))
            sys.exit(0)
        except:
            pass
    print("chat")
    print(content[:500] if content else "(empty response)")
' "$provider" <<<"$response"
}


# ─── Display ─────────────────────────────────────────────────────────────────

_zoysh_print_thinking() {
    printf "\033[3;36myo\033[0m \033[90mthinking...\033[0m" >&2
}

_zoysh_clear_thinking() {
    printf "\r\033[K" >&2
}

_zoysh_print_chat() {
    local text="$1"
    printf "\n\033[3;36m%s\033[0m\n\n" "$text"
}

_zoysh_print_error() {
    local msg="$1"
    printf "\n\033[31mzoysh: %s\033[0m\n\n" "$msg"
}

_zoysh_print_command() {
    local cmd="$1" explanation="$2"
    if [[ -n "$explanation" ]]; then
        printf "\033[90m%s\033[0m\n" "$explanation"
    fi
}

# ─── Main yo Command ─────────────────────────────────────────────────────────

_zoysh_thinking_animation() {
    local pid
    {
        local frames="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
        local i=0
        while true; do
            printf "\r\033[3;36myo\033[0m \033[90m${frames:$((i % ${#frames})):1} thinking...\033[0m" >&2
            ((i++))
            sleep 0.08
        done
    } &
    pid=$!
    # Store pid for cleanup
    ZOYSH_SPINNER_PID=$pid
}

_zoysh_stop_spinner() {
    if [[ -n "${ZOYSH_SPINNER_PID:-}" ]]; then
        kill "$ZOYSH_SPINNER_PID" 2>/dev/null
        wait "$ZOYSH_SPINNER_PID" 2>/dev/null
        unset ZOYSH_SPINNER_PID
        printf "\r\033[K" >&2
    fi
}

yo() {
    # Handle flags
    local chat_mode=0
    local clear_history=0

    while [[ "$1" == -* ]]; do
        case "$1" in
            -c|--chat)    chat_mode=1; shift ;;
            -h|--help)
                cat <<EOF
zoysh v${ZOYSH_VERSION} — LLM-powered shell assistant

Usage:
  yo <natural language>    Generate a shell command (prefilled at prompt)
  yo -c <question>         Ask a question, get inline answer
  yo --clear               Clear session memory
  yo --help                Show this help

Config: ~/.yoconf (same format as yosh)
Default: ${ZOYSH_PROVIDER}/${ZOYSH_MODEL} @ ${ZOYSH_BASE_URL}
EOF
                return 0
                ;;
            --clear)
                _zoysh_history_clear
                return 0
                ;;
            --debug)
                ZOYSH_DEBUG=1; shift
                ;;
            *)
                break
                ;;
        esac
    done

    local query="$*"
    if [[ -z "$query" ]]; then
        echo "Usage: yo <natural language>"
        echo "       yo -c <question>"
        echo "       yo --help"
        return 1
    fi

    # If chat mode, append instruction to answer rather than generate command
    if (( chat_mode )); then
        query="Answer this question (do NOT generate a shell command): $query"
    fi

    # Start thinking animation
    _zoysh_thinking_animation

    # Call LLM
    local response
    response=$(_zoysh_call_llm "$query")

    # Stop animation
    _zoysh_stop_spinner

    if [[ -z "$response" ]] || print -r -- "$response" | grep -q '"error"' 2>/dev/null; then
        local err_msg
        err_msg=$(print -r -- "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error','unknown error'))" 2>/dev/null || echo "API call failed")
        _zoysh_print_error "$err_msg"
        return 1
    fi

    # Parse response
    local parsed
    parsed=$(_zoysh_parse_response "$response")

    local rtype rcontent rexplanation
    rtype=$(print -r -- "$parsed" | head -1)
    rcontent=$(print -r -- "$parsed" | sed -n '2p')

    if [[ "$rtype" == "command" ]]; then
        rexplanation=$(print -r -- "$parsed" | sed -n '3p')

        # Display explanation
        _zoysh_print_command "$rcontent" "$rexplanation"

        # Record in history
        _zoysh_history_add "$query" "command" "$rcontent" 0

        # Prefill command at zsh prompt
        # print -z pushes text to the ZLE buffer for editing
        print -z "$rcontent"
    else
        # Chat response
        _zoysh_print_chat "$rcontent"
        _zoysh_history_add "$query" "chat" "$rcontent" 0
    fi
}

# Track whether the last yo-suggested command was executed
# Called via preexec hook
_zoysh_preexec() {
    local cmd="$1"
    # If the last history entry was a command suggestion, mark it as executed
    local last_idx=${#ZOYSH_HISTORY_TYPES[@]}
    if (( last_idx > 0 )) && [[ "${ZOYSH_HISTORY_TYPES[$last_idx]}" == "command" ]]; then
        ZOYSH_HISTORY_EXECUTED[$last_idx]=1
    fi
}

# ─── ZLE Integration (Phase 2 preparation) ────────────────────────────────────

# Custom ZLE widget for yo — can be bound to a key
_zoysh_yo_widget() {
    local query="${BUFFER}"
    if [[ -z "$query" ]]; then
        return
    fi

    # Clear buffer
    BUFFER=""

    # Run yo with the buffer content
    # Note: this runs in ZLE context, so we need zle-specific handling
    zle -I  # invalidate (redisplay)
    yo "$query"
}

# ─── Initialization ──────────────────────────────────────────────────────────

_zoysh_init() {
    _zoysh_load_config
    _zoysh_resolve_key

    # Register ZLE widget (for future keybinding)
    zle -N _zoysh_yo_widget 2>/dev/null

    # Register preexec hook to track command execution
    autoload -Uz add-zsh-hook
    add-zsh-hook preexec _zoysh_preexec

    # Optional: bind to a key (disabled by default, uncomment to enable)
    # bindkey '^O' _zoysh_yo_widget  # Ctrl-O to submit buffer to yo

    if [[ $ZOYSH_DEBUG -eq 1 ]]; then
        echo "zoysh v${ZOYSH_VERSION} loaded: ${ZOYSH_PROVIDER}/${ZOYSH_MODEL} @ ${ZOYSH_BASE_URL}" >&2
    fi
}

# Run initialization
_zoysh_init

# ─── Completion ──────────────────────────────────────────────────────────────

# Basic completion for yo
compdef _yo yo 2>/dev/null
_yo() {
    _arguments \
        '-c[ask a question]:question:' \
        '--chat[ask a question]:question:' \
        '--clear[clear session memory]' \
        '--help[show help]' \
        '*:natural language query:'
}
