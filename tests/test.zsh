#!/bin/zsh

emulate -L zsh
setopt pipe_fail

typeset -gr TEST_ROOT="${0:A:h:h}"
typeset -gi TESTS_RUN=0
typeset -gi TESTS_FAILED=0

export ZOYSH_CONF=/dev/null
source "${TEST_ROOT}/zoysh.plugin.zsh" || exit 1

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

assert_eq "0.3.0" "$ZOYSH_VERSION" "version is release version"

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
trap 'rm -f -- "$tmp_config" "$tmp_home/.qwenkey" "$tmp_home/.openrouterkey" "$tmp_stderr"; rmdir -- "$tmp_home" 2>/dev/null' EXIT
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

_zoysh_call_llm() {
    print -r -- '{"choices":[{"message":{"content":"{\"type\":\"chat\",\"response\":\"quiet response\"}"}}]}'
}
_zoysh_prepare_backend() { return 0 }
ZOYSH_CONF=/dev/null
yo -c "fixture request" >/dev/null 2>"$tmp_stderr"
stderr_output=""
IFS= read -r stderr_output < "$tmp_stderr" || true
assert_eq "" "$stderr_output" "requests do not create spinner job output"

print -r -- "1..${TESTS_RUN}"
if (( TESTS_FAILED )); then
    print -u2 -r -- "${TESTS_FAILED} test(s) failed"
    exit 1
fi
print -r -- "All ${TESTS_RUN} tests passed"
