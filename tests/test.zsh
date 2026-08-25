#!/bin/zsh

emulate -L zsh
setopt pipe_fail

typeset -gr TEST_ROOT="${0:A:h:h}"
typeset -gi TESTS_RUN=0
typeset -gi TESTS_FAILED=0

export ZOYSH_CONF=/dev/null
source "${TEST_ROOT}/zoysh.plugin.zsh" || exit 1

# ── Stub server helpers ──────────────────────────────────────────────────────

typeset -g ZOYSH_STUB_PID=""
typeset -g ZOYSH_STUB_LOG=""
typeset -gi ZOYSH_STUB_PORT=0

zoysh_stub_start() {
    local script="$1"
    # A per-invocation port avoids interference from stray listeners left by
    # earlier runs or by interactive smoke tests on the default port.
    ZOYSH_STUB_PORT=$(( 21000 + RANDOM % 20000 ))
    ZOYSH_STUB_LOG="$(mktemp "${TMPDIR:-/tmp}/zoysh-stub-log.XXXXXX")"
    python3 "${TEST_ROOT}/tests/stub_server.py" "$ZOYSH_STUB_PORT" "$script" "$ZOYSH_STUB_LOG" \
        >/dev/null 2>&1 &
    ZOYSH_STUB_PID=$!
    local waited=0
    until curl -fsS --max-time 1 "http://127.0.0.1:${ZOYSH_STUB_PORT}/v1/models" >/dev/null 2>&1; do
        if ! kill -0 "$ZOYSH_STUB_PID" 2>/dev/null; then
            print -u2 "stub server died on port ${ZOYSH_STUB_PORT}"
            exit 1
        fi
        (( waited++ > 40 )) && { print -u2 "stub server failed to start"; exit 1 }
        sleep 0.1
    done
}

zoysh_stub_stop() {
    [[ -n "$ZOYSH_STUB_PID" ]] && kill "$ZOYSH_STUB_PID" 2>/dev/null
    wait "$ZOYSH_STUB_PID" 2>/dev/null
    ZOYSH_STUB_PID=""
}

zoysh_stub_write_config() {
    printf 'provider local\nbase_url http://127.0.0.1:%s/v1\nkey local\n' "$ZOYSH_STUB_PORT" > "$1"
}

fail() {
    print -u2 -r -- "not ok - $1"
    (( TESTS_FAILED++ ))
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    (( TESTS_RUN++ ))
    if [[ "$actual" == "$expected" ]]; then
        print -r -- "ok ${TESTS_RUN} - ${label}"
    else
        fail "${label} (expected ${(qqq)expected}, got ${(qqq)actual})"
    fi
}

json_value() {
    local expression="$1"
    python3 -c "import json,sys; data=json.load(sys.stdin); print(${expression})"
}

parse_reply() {
    local parsed="$(_zoysh_parse_response "$1")"
    REPLY_TYPE="${parsed%%$'\x1e'*}"
    local rest="${parsed#*$'\x1e'}"
    REPLY_CONTENT="${rest%%$'\x1e'*}"
    REPLY_EXPLANATION="${rest#*$'\x1e'}"
}

assert_eq "0.4.0" "$ZOYSH_VERSION" "version is release version"

assert_eq $'\033[1;36myo\033[0m\n' "$ZOYSH_CHAT_PREFIX" "default chat prefix contains real ANSI escapes"
assert_eq $'\033[1m' "$ZOYSH_ENABLE_BOLD" "default bold style contains real ANSI escape"
assert_eq "http://127.0.0.1:8001/v1/chat/completions" "$(_zoysh_api_endpoint)" "local endpoint default"
assert_eq "local" "$ZOYSH_PROVIDER" "default provider is local"
assert_eq "" "$ZOYSH_MODEL" "local model starts unset for auto-detection"

FAKE_MODELS_RESPONSE='{"data":[{"id":"detected-model"}]}'
FAKE_MODELS_STATUS=0
curl() {
    printf '%s' "$FAKE_MODELS_RESPONSE"
    return "$FAKE_MODELS_STATUS"
}
ZOYSH_PROVIDER=qwen
ZOYSH_BASE_URL="http://127.0.0.1:8001/v1/"
ZOYSH_MODEL=stale-model
_zoysh_prepare_backend
prepare_status=$?
assert_eq "0" "$prepare_status" "local model detection succeeds"
assert_eq "detected-model" "$ZOYSH_MODEL" "local model detection updates runtime model"

FAKE_MODELS_RESPONSE='{"data":[]}'
_zoysh_prepare_backend
prepare_status=$?
assert_eq "1" "$prepare_status" "empty local model list fails"
assert_eq "no local model is loaded at http://127.0.0.1:8001/v1; load a model, then try yo again" "$_ZOYSH_BACKEND_ERROR" "empty local model list gives actionable error"

FAKE_MODELS_STATUS=7
_zoysh_prepare_backend
prepare_status=$?
assert_eq "1" "$prepare_status" "unavailable local server fails"
assert_eq "no local model server is responding at http://127.0.0.1:8001/v1; start the server and load a model, then try yo again" "$_ZOYSH_BACKEND_ERROR" "unavailable local server gives actionable error"
unfunction curl

assert_provider_defaults() {
    local provider="$1" endpoint="$2" model="$3"
    ZOYSH_PROVIDER="$provider"
    ZOYSH_BASE_URL=""
    ZOYSH_MODEL=""
    _ZOYSH_MODEL_EXPLICIT=0
    _zoysh_resolve_model
    assert_eq "$endpoint" "$(_zoysh_api_endpoint)" "$provider endpoint default"
    assert_eq "$model" "$ZOYSH_MODEL" "$provider model default"
}

assert_provider_defaults anthropic "https://api.anthropic.com/v1/messages" "claude-sonnet-4-5-20250929"
assert_provider_defaults openai "https://api.openai.com/v1/responses" "gpt-5.2"
assert_provider_defaults openrouter "https://openrouter.ai/api/v1/chat/completions" "z-ai/glm-5.2"
assert_provider_defaults kimi "https://api.moonshot.ai/v1/chat/completions" "kimi-k2.5"
assert_provider_defaults deepseek "https://api.deepseek.com/chat/completions" "deepseek-v4-flash"
assert_provider_defaults qwen "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions" "qwen-plus"
assert_provider_defaults zai "https://api.z.ai/api/paas/v4/chat/completions" "glm-5.2"

ZOYSH_PROVIDER=openrouter
_zoysh_validate_config 2>/dev/null
assert_eq "openrouter" "$ZOYSH_PROVIDER" "config accepts OpenRouter provider"

ZOYSH_PROVIDER=qwen
ZOYSH_BASE_URL="http://127.0.0.1:8001/v1"
ZOYSH_MODEL=""
_ZOYSH_MODEL_EXPLICIT=0
_zoysh_resolve_model
assert_eq "" "$ZOYSH_MODEL" "custom local endpoint leaves model for auto-detection"

ZOYSH_PROVIDER=qwen
ZOYSH_MODEL=test-model
ZOYSH_TOKEN_BUDGET=321
ZOYSH_MAX_OUTPUT_TOKENS=321
ZOYSH_SERVER_WEB=1
ZOYSH_HISTORY_QUERIES=("first | query")
ZOYSH_HISTORY_TYPES=(chat)
ZOYSH_HISTORY_RESPONSES=($'line one\nline two')
request="$(_zoysh_build_request "system prompt" "current query")"
assert_eq "321" "$(printf '%s' "$request" | json_value 'data["max_tokens"]')" "max output tokens reach request"
assert_eq "4" "$(printf '%s' "$request" | json_value 'len(data["messages"])')" "history reaches request"
assert_eq $'line one\nline two' "$(printf '%s' "$request" | json_value 'json.loads(data["messages"][2]["content"])["response"]')" "history preserves multiline reply"

assert_eq "False" "$(printf '%s' "$request" | json_value 'str("tools" in data)')" "Chat Completions omit hosted web tools"

sample_text="${(l:120::x:)}"
ZOYSH_HISTORY_QUERIES=("$sample_text" "$sample_text" "$sample_text" "$sample_text")
ZOYSH_HISTORY_TYPES=(chat chat chat chat)
ZOYSH_HISTORY_RESPONSES=("$sample_text" "$sample_text" "$sample_text" "$sample_text")
ZOYSH_HISTORY_LIMIT=10
ZOYSH_TOKEN_BUDGET=180
_zoysh_history_prune
assert_eq "3" "${#ZOYSH_HISTORY_QUERIES[@]}" "history token budget prunes oldest exchanges"
_zoysh_history_estimated_tokens
assert_eq "180" "$REPLY" "history token estimate follows yosh semantics"
ZOYSH_HISTORY_QUERIES=()
ZOYSH_HISTORY_TYPES=()
ZOYSH_HISTORY_RESPONSES=()
ZOYSH_TOKEN_BUDGET=321

ZOYSH_PROVIDER=openai
request="$(_zoysh_build_request "system prompt" "current query")"
assert_eq "False" "$(printf '%s' "$request" | json_value 'data["store"]')" "OpenAI requests disable storage"
assert_eq "321" "$(printf '%s' "$request" | json_value 'data["max_output_tokens"]')" "OpenAI max output tokens"
assert_eq "web_search" "$(printf '%s' "$request" | json_value 'data["tools"][0]["type"]')" "OpenAI web search tool"

ZOYSH_PROVIDER=anthropic
request="$(_zoysh_build_request "system prompt" "current query")"
assert_eq "web_search_20250305" "$(printf '%s' "$request" | json_value 'data["tools"][0]["type"]')" "Anthropic web search tool"
assert_eq "web_fetch_20250910" "$(printf '%s' "$request" | json_value 'data["tools"][1]["type"]')" "Anthropic web fetch tool"
ZOYSH_SERVER_WEB=0
request="$(_zoysh_build_request "system prompt" "current query")"
assert_eq "False" "$(printf '%s' "$request" | json_value 'str("tools" in data)')" "server_web disables hosted web tools"
ZOYSH_SERVER_WEB=1

ZOYSH_PROVIDER=qwen
response="$(python3 -c 'import json; print(json.dumps({"choices":[{"message":{"content":json.dumps({"type":"chat","response":"first line\nsecond line"})}}]}))')"
parse_reply "$response"
assert_eq "chat" "$REPLY_TYPE" "chat response type"
assert_eq $'first line\nsecond line' "$REPLY_CONTENT" "chat response preserves newlines"

response="$(python3 -c 'import json; print(json.dumps({"choices":[{"message":{"content":"```json\n" + json.dumps({"type":"command","command":"printf one\nprintf two","explanation":"two lines"}) + "\n```"}}]}))')"
parse_reply "$response"
assert_eq "command" "$REPLY_TYPE" "fenced command response type"
assert_eq $'printf one\nprintf two' "$REPLY_CONTENT" "command response preserves newlines"
assert_eq "two lines" "$REPLY_EXPLANATION" "command explanation"

parse_reply '{"error":{"message":"rate limited"}}'
assert_eq "error" "$REPLY_TYPE" "API error response type"
assert_eq "API error: rate limited" "$REPLY_CONTENT" "API error message"

response='{"choices":[{"finish_reason":"length","message":{"content":"{\"type\":\"command\",\"command\":"}}]}'
parse_reply "$response"
assert_eq "error" "$REPLY_TYPE" "truncated response type"
assert_eq "model response was truncated; increase max_output_tokens" "$REPLY_CONTENT" "truncated response guidance"

response="$(python3 -c 'import json; print(json.dumps({"choices":[{"message":{"content":json.dumps({"type":"chat","response":"safe\u001b]52;clipboard\u0007 text\u202e"})}}]}))')"
parse_reply "$response"
assert_eq "safe]52;clipboard text" "$REPLY_CONTENT" "terminal and bidi controls are stripped"

FAKE_CURL_BODY="$response"
FAKE_CURL_STATUS=200
curl() {
    command cat >/dev/null
    printf '%s\n%s' "$FAKE_CURL_BODY" "$FAKE_CURL_STATUS"
}
ZOYSH_PROVIDER=qwen
ZOYSH_API_KEY=local
api_response="$(_zoysh_call_llm "fixture request")"
assert_eq "$FAKE_CURL_BODY" "$api_response" "HTTP success returns response body"

FAKE_CURL_BODY='{"error":{"message":"slow down"}}'
FAKE_CURL_STATUS=429
api_response="$(_zoysh_call_llm "fixture request")"
api_status=$?
assert_eq "1" "$api_status" "HTTP errors return failure"
assert_eq "API request failed (HTTP 429): slow down" "$api_response" "HTTP errors preserve provider message"

for hosted_provider in anthropic openai openrouter kimi deepseek qwen zai; do
    ZOYSH_PROVIDER="$hosted_provider"
    ZOYSH_BASE_URL=""
    ZOYSH_API_KEY=local
    api_response="$(_zoysh_call_llm "fixture request")"
    api_status=$?
    assert_eq "1" "$api_status" "$hosted_provider rejects placeholder key"
    assert_eq "missing API key for provider ${hosted_provider}" "$api_response" "$hosted_provider reports missing key"
done
unfunction curl

tmp_config="$(mktemp "${TMPDIR:-/tmp}/zoysh-test.XXXXXX")" || exit 1
tmp_home="$(mktemp -d "${TMPDIR:-/tmp}/zoysh-home.XXXXXX")" || exit 1
tmp_stderr="$tmp_home/stderr"
trap 'zoysh_stub_stop; rm -f -- "$tmp_config" "$tmp_home/.qwenkey" "$tmp_home/.openrouterkey" "$tmp_stderr" "$ZOYSH_STUB_LOG"; rmdir -- "$tmp_home" 2>/dev/null' EXIT
printf '%s\n' \
    $'provider\tOPENAI' \
    'model release-model # comment' \
    'history_limit invalid' \
    'token_budget 777' \
    'max_output_tokens 888' \
    'timeout 15' \
    'server_web 0' \
    'scrollback_enabled 0' \
    'scrollback_bytes 2048' \
    'scrollback_lines 50' \
    'chat_prefix "\033[1mYO\033[0m\n"' \
    'color_prefix "\033[32m"' \
    'chat_reset "\033[0m"' \
    'enable_italic "<i>"' \
    'disable_italic "</i>"' \
    'enable_bold "<b>"' \
    'disable_bold "</b>"' \
    'enable_strikethrough "<s>"' \
    'disable_strikethrough "</s>"' \
    'code_delimiter "<code>"' > "$tmp_config"
ZOYSH_CONF="$tmp_config"
ZOYSH_HISTORY_LIMIT=10
_zoysh_load_config
_zoysh_validate_config 2>/dev/null
assert_eq "openai" "$ZOYSH_PROVIDER" "config accepts tabs and normalizes provider"
assert_eq "release-model" "$ZOYSH_MODEL" "config strips inline comments"
assert_eq "10" "$ZOYSH_HISTORY_LIMIT" "invalid history limit falls back"
assert_eq "777" "$ZOYSH_TOKEN_BUDGET" "config history token budget"
assert_eq "888" "$ZOYSH_MAX_OUTPUT_TOKENS" "config max output tokens"
assert_eq "15" "$ZOYSH_TIMEOUT" "config timeout"
assert_eq "0" "$ZOYSH_SERVER_WEB" "config server web toggle"
assert_eq "2048" "$ZOYSH_SCROLLBACK_BYTES" "config scrollback byte limit"
assert_eq "50" "$ZOYSH_SCROLLBACK_LINES" "config scrollback line limit"
assert_eq $'\033[1mYO\033[0m\n' "$ZOYSH_CHAT_PREFIX" "config decodes quoted chat prefix"
assert_eq $'\033[32m' "$ZOYSH_COLOR_PREFIX" "config decodes color prefix"
assert_eq "<b>" "$ZOYSH_ENABLE_BOLD" "config bold style"
assert_eq "</s>" "$ZOYSH_DISABLE_STRIKETHROUGH" "config strikethrough style"
assert_eq "<code>" "$ZOYSH_CODE_DELIMITER" "config code style"

printf '%s\n' \
    'provider qwen' \
    'model reloaded-model' \
    'history_limit 10' \
    'token_budget 4096' > "$tmp_config"
_zoysh_reload_config
assert_eq "qwen" "$ZOYSH_PROVIDER" "config reload updates provider"
assert_eq "reloaded-model" "$ZOYSH_MODEL" "config reload updates model"

assert_eq "1" "$ZOYSH_SERVER_WEB" "config reload restores omitted defaults"
_zoysh_decode_config_value '""'
assert_eq "" "$REPLY" "config accepts an explicitly empty display value"

ZOYSH_COLOR_PREFIX=""
ZOYSH_COLOR_RESET="</code>"
ZOYSH_ENABLE_ITALIC="<i>"
ZOYSH_DISABLE_ITALIC="</i>"
ZOYSH_ENABLE_BOLD="<b>"
ZOYSH_DISABLE_BOLD="</b>"
ZOYSH_ENABLE_STRIKETHROUGH="<s>"
ZOYSH_DISABLE_STRIKETHROUGH="</s>"
ZOYSH_CODE_DELIMITER="<code>"
rendered="$(printf '%s' $'## Example\n\n**Matrix A:** $Ax = B$\n- first\n1 * -1\n\x60\x60\x60zsh\nprint hi\n\x60\x60\x60' | _zoysh_render_markdown)"
assert_eq $'<b>Example</b>\n\n<b>Matrix A:</b> <code>Ax = B</code>\n• first\n1 * -1\n<code>┌─ zsh</code>\n<code>│ print hi</code>\n<code>└─</code>' "$rendered" "markdown renderer formats terminal output"

printf '%s\n' 'file-key' > "$tmp_home/.qwenkey"
unset ZAI_API_KEY OPENROUTER_API_KEY
ZOYSH_PROVIDER=qwen
ZOYSH_API_KEY=local
HOME="$tmp_home"
_zoysh_resolve_key
assert_eq "local" "$ZOYSH_API_KEY" "explicit local key bypasses key files"
ZOYSH_API_KEY=""
_zoysh_resolve_key
assert_eq "file-key" "$ZOYSH_API_KEY" "missing key loads provider key file"

printf '%s\n' 'openrouter-file-key' > "$tmp_home/.openrouterkey"
ZOYSH_PROVIDER=openrouter
ZOYSH_API_KEY=""
_zoysh_resolve_key
assert_eq "openrouter-file-key" "$ZOYSH_API_KEY" "OpenRouter loads its provider key file"

ZAI_API_KEY="env-key"
ZOYSH_PROVIDER=zai
ZOYSH_API_KEY=""
_zoysh_resolve_key
assert_eq "env-key" "$ZOYSH_API_KEY" "z.ai loads its conventional environment key"
unset ZAI_API_KEY

OPENROUTER_API_KEY="env-key"
ZOYSH_PROVIDER=openrouter
ZOYSH_API_KEY=""
_zoysh_resolve_key
assert_eq "env-key" "$ZOYSH_API_KEY" "OpenRouter loads its conventional environment key"
unset OPENROUTER_API_KEY

_zoysh_real_call_llm="${functions[_zoysh_call_llm]}"
_zoysh_real_prepare_backend="${functions[_zoysh_prepare_backend]}"
_zoysh_call_llm() {
    print -r -- '{"choices":[{"message":{"content":"{\"type\":\"chat\",\"response\":\"quiet response\"}"}}]}'
}
_zoysh_prepare_backend() { return 0 }
ZOYSH_CONF=/dev/null
yo -c "fixture request" >/dev/null 2>"$tmp_stderr"
stderr_output=""
IFS= read -r stderr_output < "$tmp_stderr" || true
assert_eq "" "$stderr_output" "requests do not create spinner job output"

help_output="$(yo --help)"
[[ "$help_output" == *"A zsh port of Yosh by Fil Pizlo"* ]] && help_credits=1 || help_credits=0
assert_eq "1" "$help_credits" "help credits Yosh and Fil Pizlo"

# ── End-to-end stub tests ────────────────────────────────────────────────────

functions[_zoysh_call_llm]="$_zoysh_real_call_llm"
functions[_zoysh_prepare_backend]="$_zoysh_real_prepare_backend"

zoysh_stub_start plain
zoysh_stub_write_config "$tmp_config"
ZOYSH_CONF="$tmp_config"
stub_answer="$(yo -c "greet me" 2>/dev/null)"
[[ "$stub_answer" == *"Hello from the stub."* ]] && stub_ok=1 || stub_ok=0
assert_eq "1" "$stub_ok" "stub chat answer reaches the user end to end"
_zoysh_reload_config
_zoysh_prepare_backend
assert_eq "stub-model" "$ZOYSH_MODEL" "stub models endpoint feeds local model detection"
stub_requests="$(grep -c chat/completions "$ZOYSH_STUB_LOG")"
assert_eq "1" "$stub_requests" "stub records the completion request"
zoysh_stub_stop
ZOYSH_CONF=/dev/null

# ── Streaming tests ──────────────────────────────────────────────────────────

zmodload zsh/datetime

stream_config() {
    zoysh_stub_write_config "$tmp_config"
    printf 'streaming %s\n' "$1" >> "$tmp_config"
    ZOYSH_CONF="$tmp_config"
    _zoysh_reload_config
}

zoysh_stub_start chat-md
stream_config 0
nonstream_answer="$(yo -c "explain" 2>/dev/null)"
stream_config 1
stream_answer="$(yo -c "explain" 2>/dev/null)"
stream_tail="${stream_answer##*$'\033'\[2K}"
stream_tail="${stream_tail#$'\r'}"
assert_eq "$nonstream_answer" "$stream_tail" "streaming final render matches non-streaming output byte for byte"
stream_request="$(python3 -c '
import json, sys
found = 0
for line in open(sys.argv[1]):
    try:
        entry = json.loads(line)
        body = json.loads(entry.get("body") or "{}")
    except ValueError:
        continue
    if "chat/completions" in entry.get("path", "") and body.get("stream") is True:
        found += 1
print(found)
' "$ZOYSH_STUB_LOG")"
assert_eq "1" "$stream_request" "streaming requests ask the server for SSE"
zoysh_stub_stop

zoysh_stub_start think-stream
stream_config 1
think_answer="$(yo -c "ponder" 2>/dev/null)"
[[ "$think_answer" == *"muses quietly"* ]] && think_leak=1 || think_leak=0
assert_eq "0" "$think_leak" "streaming hides think blocks split across chunks"
[[ "$think_answer" == *"visible after thinking"* ]] && think_ok=1 || think_ok=0
assert_eq "1" "$think_ok" "streamed answer text survives think suppression"
zoysh_stub_stop

zoysh_stub_start error429
stream_config 1
error_answer="$(yo -c "query" 2>/dev/null)"
[[ "$error_answer" == *"API request failed (HTTP 429): stub rate limited"* ]] && fallback_ok=1 || fallback_ok=0
assert_eq "1" "$fallback_ok" "non-SSE error responses fall back to the blocking error path"
zoysh_stub_stop

zoysh_stub_start command
stream_config 1
command_stdout="$(mktemp "${TMPDIR:-/tmp}/zoysh-cmd-out.XXXXXX")"
_zoysh_stream_call command "greet" > "$command_stdout"
stream_call_status=$?
assert_eq "0" "$stream_call_status" "command-mode streaming call succeeds"
assert_eq "" "$(cat "$command_stdout")" "command mode suppresses delta output"
parsed=$(printf '%s' "$_ZOYSH_RAW_RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["content"])')
assert_eq '{"type":"command","command":"echo hello-zoysh","explanation":"prints a greeting"}' "$parsed" "command mode still delivers the full response for parsing"
rm -f "$command_stdout"
zoysh_stub_stop

zoysh_stub_start veryslow
printf 'provider local\nbase_url http://127.0.0.1:%s/v1\nkey local\ntimeout 1\nstreaming 1\n' "$ZOYSH_STUB_PORT" > "$tmp_config"
ZOYSH_CONF="$tmp_config"
_zoysh_reload_config
started=$EPOCHSECONDS
timeout_answer="$(yo -c "slow query" 2>/dev/null)"
timed_out=$(( EPOCHSECONDS - started ))
[[ "$timeout_answer" == *"timed out after 1s without a chunk from local"* ]] && timeout_ok=1 || timeout_ok=0
assert_eq "1" "$timeout_ok" "idle timeout reports while the server stalls"
(( timed_out < 10 )) && timeout_fast=1 || timeout_fast=0
assert_eq "1" "$timeout_fast" "idle timeout returns promptly (${timed_out}s)"
zoysh_stub_stop

zoysh_stub_start slow
stream_config 1
progress_file="$(mktemp "${TMPDIR:-/tmp}/zoysh-progress.XXXXXX")"
(_zoysh_stream_call chat "count slowly" > "$progress_file" 2>/dev/null) &
progress_pid=$!
progress_seen=0
for (( i = 0; i < 80; i++ )); do
    grep -q "counting " "$progress_file" 2>/dev/null && { progress_seen=1; break }
    sleep 0.1
done
assert_eq "1" "$progress_seen" "slow stream delivers its first chunk promptly"
grep -q "three." "$progress_file" 2>/dev/null && early_finish=1 || early_finish=0
assert_eq "0" "$early_finish" "later chunks have not arrived yet at first-poll time"
wait "$progress_pid"
grep -q "three." "$progress_file" 2>/dev/null && late_finish=1 || late_finish=0
assert_eq "1" "$late_finish" "slow stream completes after all chunks arrive"
rm -f "$progress_file"
zoysh_stub_stop

printf 'provider local\nbase_url http://127.0.0.1:%s/v1\nkey local\nstreaming maybe\n' "$ZOYSH_STUB_PORT" > "$tmp_config"
ZOYSH_CONF="$tmp_config"
_zoysh_reload_config 2>/dev/null
assert_eq "1" "$ZOYSH_STREAMING" "invalid streaming value falls back to enabled"
ZOYSH_CONF=/dev/null

# ── Cancellation tests ───────────────────────────────────────────────────────

zmodload zsh/zpty

zoysh_zpty_wait() {
    ZPTY_WAITED=0
    local name="$1" pattern="$2" timeout="$3" acc="" chunk
    local deadline=$(( EPOCHSECONDS + timeout ))
    while (( EPOCHSECONDS < deadline )); do
        zpty -r "$name" chunk 2>/dev/null
        acc="${acc}${chunk}"
        [[ "$acc" == *"$pattern"* ]] && { ZPTY_WAITED=1; break; }
        sleep 0.2
    done
    REPLY="$acc"
}

cancel_config() {
    printf 'provider local\nbase_url http://127.0.0.1:%s/v1\nkey local\ntimeout 30\nstreaming %s\n' \
        "$ZOYSH_STUB_PORT" "$1" > "$tmp_config"
}

zoysh_stub_start slow
cancel_config 1
zpty -b zcancel1 "env ZOYSH_CONF=$tmp_config HOME=$HOME PS1='ZC1> ' zsh -f -i"
zpty -w zcancel1 "stty rows 30 cols 100; source ${TEST_ROOT}/zoysh.plugin.zsh"$'\r'
sleep 0.8
zpty -r zcancel1 junk >/dev/null
zpty -w zcancel1 "yo -c 'count for me'"$'\r'
zoysh_zpty_wait zcancel1 "counting " 25
assert_eq "1" "$ZPTY_WAITED" "streaming cancel test saw partial output before Ctrl-C"
zpty -w -n zcancel1 $'\x03'
zoysh_zpty_wait zcancel1 "yo: cancelled" 25
assert_eq "1" "$ZPTY_WAITED" "Ctrl-C during streaming prints the cancellation notice"
sleep 1
cancel_leftovers="$(pgrep -fc "127.0.0.1:${ZOYSH_STUB_PORT}" 2>/dev/null)"
[[ "$cancel_leftovers" == "" ]] && cancel_leftovers=0
assert_eq "0" "$cancel_leftovers" "Ctrl-C reaps the helper process group"
zpty -w zcancel1 "print TRAPLEFT=\$(( \${+functions[TRAPINT]} )) ; print SHELL-OK-\$?"$'\r'
zoysh_zpty_wait zcancel1 "TRAPLEFT=" 10
zoysh_zpty_wait zcancel1 "SHELL-OK-" 25
assert_eq "1" "$ZPTY_WAITED" "the shell still executes commands after cancellation"
zpty -w zcancel1 "print TRAPLEFT-\$(( \${+functions[TRAPINT]} ))"$'\r'
zoysh_zpty_wait zcancel1 "TRAPLEFT-0" 25
assert_eq "1" "$ZPTY_WAITED" "the interrupt trap does not leak after cancellation"
zpty -d zcancel1
zoysh_stub_stop

zoysh_stub_start veryslow
cancel_config 0
zpty -b zcancel2 "env ZOYSH_CONF=$tmp_config HOME=$HOME PS1='ZC2> ' zsh -f -i"
zpty -w zcancel2 "stty rows 30 cols 100; source ${TEST_ROOT}/zoysh.plugin.zsh"$'\r'
sleep 0.8
zpty -r zcancel2 junk >/dev/null
zpty -w zcancel2 "yo -c 'slow one'"$'\r'
blocking_started=0
# Slow CI runners (macos) can need several seconds of cold start before the
# request even reaches the stub; poll generously since early exit is cheap.
for (( i = 0; i < 150; i++ )); do
    grep -q "chat/completions" "$ZOYSH_STUB_LOG" 2>/dev/null && { blocking_started=1; break }
    sleep 0.2
done
assert_eq "1" "$blocking_started" "blocking request is in flight before Ctrl-C"
zpty -w -n zcancel2 $'\x03'
zoysh_zpty_wait zcancel2 "yo: cancelled" 30
assert_eq "1" "$ZPTY_WAITED" "Ctrl-C cancels the blocking request path"
zpty -d zcancel2
zoysh_stub_stop
ZOYSH_CONF=/dev/null

# ── ZLE widget tests ─────────────────────────────────────────────────────────

zoysh_stub_start widget
printf 'provider local\nbase_url http://127.0.0.1:%s/v1\nkey local\n' "$ZOYSH_STUB_PORT" > "$tmp_config"
zpty -b zwidget "env ZOYSH_CONF=$tmp_config HOME=$HOME PS1='ZW> ' zsh -f -i"
zpty -w zwidget "stty rows 30 cols 100; source ${TEST_ROOT}/zoysh.plugin.zsh; print WREG=\$(( \${+widgets[zoysh-widget]} )) BOUND=\$(bindkey '\\ey') SYNC\$(( 6*7 ))"$'\r'
zoysh_zpty_wait zwidget "SYNC42" 10
assert_eq "1" "$ZPTY_WAITED" "the widget registration probe completed"
[[ "${REPLY}" == *"WREG=1"* ]] && wreg=1 || wreg=0
assert_eq "1" "$wreg" "the zoysh widget is registered"
[[ "${REPLY}" == *"zoysh-widget"* ]] && wbound=1 || wbound=0
assert_eq "1" "$wbound" "M-y is bound to the zoysh widget by default"

zpty -w -n zwidget "print a marker"
sleep 0.4
zpty -w -n zwidget $'\033y'
zoysh_zpty_wait zwidget "echo ZOYSH_WIDGET_OK" 15
assert_eq "1" "$ZPTY_WAITED" "M-y over a typed buffer replaces it with the generated command"
zpty -w -n zwidget $'\r'
zoysh_zpty_wait zwidget "ZOYSH_WIDGET_OK" 10
assert_eq "1" "$ZPTY_WAITED" "the generated widget command runs after Enter"

zpty -w -n zwidget $'\033y'
zoysh_zpty_wait zwidget "query:" 10
assert_eq "1" "$ZPTY_WAITED" "M-y on an empty buffer opens the mini-prompt"
zpty -w -n zwidget "run the marker"
sleep 0.3
zpty -w -n zwidget $'\r'
zoysh_zpty_wait zwidget "echo ZOYSH_WIDGET_OK" 15
assert_eq "1" "$ZPTY_WAITED" "a mini-prompt query generates the command into the buffer"
zpty -d zwidget
zoysh_stub_stop

zpty -b zoptout "env ZOYSH_CONF=/dev/null HOME=$HOME PS1='ZO> ' zsh -f -i"
optout_probe="$(mktemp "${TMPDIR:-/tmp}/zoysh-optout.XXXXXX")"
zpty -w zoptout "stty rows 30 cols 100; zstyle ':zoysh:widget' bind no; source ${TEST_ROOT}/zoysh.plugin.zsh; bindkey '\\ey' > $optout_probe 2>&1; print PROBED\$(( 6*7 ))"$'\r'
zoysh_zpty_wait zoptout "PROBED42" 25
assert_eq "1" "$ZPTY_WAITED" "the opt-out probe completed"
# Stock zsh binds M-y to yank-pop in the emacs keymap (and leaves it
# unbound in vi mode), so the assertion is "not bound to our widget".
# Never assert "undefined-key": that message only appears when the
# default keymap is vi (EDITOR containing "vi"), which depends on the
# caller's environment.
[[ "$(<"$optout_probe")" == *"zoysh-widget"* ]] && optout_bound=1 || optout_bound=0
assert_eq "0" "$optout_bound" "zstyle :zoysh:widget bind no leaves M-y untouched"
rm -f -- "$optout_probe"
zpty -d zoptout
ZOYSH_CONF=/dev/null

# ── Multi-step plan tests ────────────────────────────────────────────────────

plan_response='{"choices":[{"message":{"content":"Build all the things\n```zoysh:plan\necho step-one\necho step-two\necho step-three\n```"}}]}'
ZPLAN=1 parse_reply "$plan_response"
assert_eq "plan" "$REPLY_TYPE" "plan response type"
assert_eq $'echo step-one\necho step-two\necho step-three' "$REPLY_CONTENT" "plan commands are parsed one per line"
assert_eq "Build all the things" "$REPLY_EXPLANATION" "plan summary comes from outside the fence"
ZPLAN=0 parse_reply "$plan_response"
assert_eq "chat" "$REPLY_TYPE" "plan blocks stay plain chat when continuation is off"

printf '%s\n' 'continuation maybe' >> "$tmp_config"
ZOYSH_CONF="$tmp_config"
_zoysh_reload_config 2>/dev/null
assert_eq "0" "$ZOYSH_CONTINUATION" "invalid continuation falls back to disabled"
printf '%s\n' 'continuation 1' >> "$tmp_config"
_zoysh_reload_config 2>/dev/null
assert_eq "1" "$ZOYSH_CONTINUATION" "continuation directive enables plans"
ZOYSH_CONF=/dev/null

zoysh_stub_start plan3
plan_state="$(mktemp -d "${TMPDIR:-/tmp}/zoysh-plan.XXXXXX")"
printf 'provider local\nbase_url http://127.0.0.1:%s/v1\nkey local\ncontinuation 1\n' "$ZOYSH_STUB_PORT" > "$tmp_config"
zpty -b zplan "env ZOYSH_CONF=$tmp_config ZOYSH_STATE_DIR=$plan_state HOME=$HOME PS1='ZP> ' zsh -f -i"
zpty -w -n zplan "stty rows 30 cols 100; source ${TEST_ROOT}/zoysh.plugin.zsh"$'\r'
sleep 0.8
zpty -r zplan junk >/dev/null
zpty -w -n zplan "yo build all the things"$'\r'
zoysh_zpty_wait zplan "echo step-one" 15
assert_eq "1" "$ZPTY_WAITED" "plan step one is prefilled for review"
[[ "${REPLY}" == *"plan step 1/3"* ]] && plan_ind1=1 || plan_ind1=0
assert_eq "1" "$plan_ind1" "plan progress indicator prints"
zpty -w -n zplan $'\r'
zoysh_zpty_wait zplan "echo step-two" 15
assert_eq "1" "$ZPTY_WAITED" "running step one prefills step two"
[[ "${REPLY}" == *"plan step 2/3"* ]] && plan_ind2=1 || plan_ind2=0
assert_eq "1" "$plan_ind2" "step two indicator prints after step one runs"
zpty -w -n zplan $'\r'
zoysh_zpty_wait zplan "echo step-three" 15
assert_eq "1" "$ZPTY_WAITED" "running step two prefills step three"
zpty -w -n zplan $'\r'
zoysh_zpty_wait zplan "plan complete" 15
assert_eq "1" "$ZPTY_WAITED" "finishing the last step completes the plan"
[[ -f "$plan_state/plan" ]] && plan_file_left=1 || plan_file_left=0
assert_eq "0" "$plan_file_left" "the queue file is removed when the plan completes"
zpty -d zplan

zoysh_stub_stop
zoysh_stub_start plan3
printf 'provider local\nbase_url http://127.0.0.1:%s/v1\nkey local\ncontinuation 1\n' "$ZOYSH_STUB_PORT" > "$tmp_config"
zpty -b zabort "env ZOYSH_CONF=$tmp_config ZOYSH_STATE_DIR=$plan_state HOME=$HOME PS1='ZB> ' zsh -f -i"
zpty -w -n zabort "stty rows 30 cols 100; source ${TEST_ROOT}/zoysh.plugin.zsh"$'\r'
sleep 0.8
zpty -r zabort junk >/dev/null
zpty -w -n zabort "yo build all the things"$'\r'
zoysh_zpty_wait zabort "echo step-one" 15
assert_eq "1" "$ZPTY_WAITED" "abort session reaches step one"
zpty -w -n zabort $'\x15'
sleep 0.3
zpty -w -n zabort "yo --abort"$'\r'
zoysh_zpty_wait zabort "plan aborted" 15
assert_eq "1" "$ZPTY_WAITED" "yo --abort drops the queue with a notice"
[[ -f "$plan_state/plan" ]] && abort_file_left=1 || abort_file_left=0
assert_eq "0" "$abort_file_left" "yo --abort removes the queue file"
zpty -d zabort
zoysh_stub_stop

zoysh_stub_start command
printf 'provider local\nbase_url http://127.0.0.1:%s/v1\nkey local\ncontinuation 1\n' "$ZOYSH_STUB_PORT" > "$tmp_config"
zpty -b zsingle "env ZOYSH_CONF=$tmp_config ZOYSH_STATE_DIR=$plan_state HOME=$HOME PS1='ZS> ' zsh -f -i"
zpty -w -n zsingle "stty rows 30 cols 100; source ${TEST_ROOT}/zoysh.plugin.zsh"$'\r'
sleep 0.8
zpty -r zsingle junk >/dev/null
zpty -w -n zsingle "yo say hi"$'\r'
zoysh_zpty_wait zsingle "echo hello-zoysh" 15
assert_eq "1" "$ZPTY_WAITED" "single commands still prefill with continuation on"
sleep 1.5
zpty -r zsingle quiet
[[ "$quiet" == *"hello-zoysh"* ]] && single_autoran=1 || single_autoran=0
assert_eq "0" "$single_autoran" "a prefilled command never runs without Enter"
[[ -f "$plan_state/plan" ]] && single_queue=1 || single_queue=0
assert_eq "0" "$single_queue" "single commands do not create a queue"
zpty -w -n zsingle $'\r'
zoysh_zpty_wait zsingle "hello-zoysh" 10
assert_eq "1" "$ZPTY_WAITED" "the prefilled command runs after an explicit Enter"
zpty -d zsingle
zoysh_stub_stop
rm -rf -- "$plan_state"
ZOYSH_CONF=/dev/null

# ── Scrollback capture tests ─────────────────────────────────────────────────

sb_state="$(mktemp -d "${TMPDIR:-/tmp}/zoysh-sb.XXXXXX")"
zoysh_stub_start planthenchat
printf 'provider local\nbase_url http://127.0.0.1:%s/v1\nkey local\ncontinuation 1\nscrollback_enabled 1\nscrollback_bytes 4096\n' \
    "$ZOYSH_STUB_PORT" > "$tmp_config"
zpty -b zsb "env ZOYSH_CONF=$tmp_config ZOYSH_STATE_DIR=$sb_state HOME=$HOME PS1='ZSB> ' zsh -f -i"
zpty -w -n zsb "stty rows 30 cols 100; source ${TEST_ROOT}/zoysh.plugin.zsh"$'\r'
sleep 0.8
zpty -r zsb junk >/dev/null
zpty -w -n zsb "yo build the thing"$'\r'
zoysh_zpty_wait zsb "zoysh-run echo known-output-marker" 15
assert_eq "1" "$ZPTY_WAITED" "plan steps prefill wrapped in zoysh-run when capture is on"
zpty -w -n zsb $'\r'
zoysh_zpty_wait zsb "plan step 2/2" 15
assert_eq "1" "$ZPTY_WAITED" "the wrapped step still advances the plan"
[[ -f "$sb_state/scrollback" ]] && ring_present=1 || ring_present=0
assert_eq "1" "$ring_present" "running the wrapped step creates the ring"
[[ "$(<"$sb_state/scrollback")" == *"known-output-marker"* ]] && ring_out=1 || ring_out=0
assert_eq "1" "$ring_out" "the ring holds the step output"
zpty -w -n zsb $'\x15'
sleep 0.3
zpty -w -n zsb "yo -c 'what did the last command print'"$'\r'
zoysh_zpty_wait zsb "known-output-marker" 15
assert_eq "1" "$ZPTY_WAITED" "follow-up questions receive the canned answer"
sb_in_request="$(python3 -c '
import json, sys
found = 0
for line in open(sys.argv[1]):
    try:
        entry = json.loads(line)
        body = json.loads(entry.get("body") or "{}")
    except ValueError:
        continue
    text = json.dumps(body)
    if "known-output-marker" in text and "chat/completions" in entry.get("path", ""):
        found += 1
print(found)
' "$ZOYSH_STUB_LOG")"
assert_eq "1" "$sb_in_request" "the captured output reaches the follow-up request context"
zpty -d zsb
zoysh_stub_stop

ZOYSH_CONF=/dev/null
ZOYSH_STATE_DIR="$sb_state"
ZOYSH_SCROLLBACK_ENABLED=1
rm -f -- "$sb_state/scrollback"
ZOYSH_SCROLLBACK_BYTES=50
zoysh-run "seq 1 40" >/dev/null
ring_size=$(command stat -c %s -- "$sb_state/scrollback" 2>/dev/null)
(( ring_size <= 50 )) && ring_capped=1 || ring_capped=0
assert_eq "1" "$ring_capped" "the ring respects the byte cap (${ring_size} bytes)"
[[ "$(<"$sb_state/scrollback")" == *"40"* ]] && ring_tail=1 || ring_tail=0
assert_eq "1" "$ring_tail" "trimming keeps the most recent output"
zoysh-run "false" >/dev/null
false_status=$?
assert_eq "1" "$false_status" "zoysh-run preserves the command exit status"

ZOYSH_SCROLLBACK_ENABLED=0
_ZOYSH_PLAN_CMDS=("echo raw-step")
_ZOYSH_PLAN_QUERY="unit"
_zoysh_plan_prefill 1 >/dev/null
assert_eq "echo raw-step" "$_ZOYSH_PENDING_CMD" "capture off leaves plan steps unwrapped"
ZOYSH_STATE_DIR=""
rm -rf -- "$sb_state"

print -r -- "1..${TESTS_RUN}"
if (( TESTS_FAILED )); then
    print -u2 -r -- "${TESTS_FAILED} test(s) failed"
    exit 1
fi
print -r -- "All ${TESTS_RUN} tests passed"
