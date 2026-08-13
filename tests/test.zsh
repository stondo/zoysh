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
assert_eq "http://127.0.0.1:8001/v1/chat/completions" "$(_zoysh_api_endpoint)" "local endpoint default"

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

ZOYSH_PROVIDER=openai
ZOYSH_BASE_URL=""
assert_eq "https://api.openai.com/v1/responses" "$(_zoysh_api_endpoint)" "OpenAI endpoint default"
ZOYSH_PROVIDER=anthropic
assert_eq "https://api.anthropic.com/v1/messages" "$(_zoysh_api_endpoint)" "Anthropic endpoint default"

ZOYSH_PROVIDER=qwen
ZOYSH_MODEL=test-model
ZOYSH_TOKEN_BUDGET=321
ZOYSH_HISTORY_QUERIES=("first | query")
ZOYSH_HISTORY_TYPES=(chat)
ZOYSH_HISTORY_RESPONSES=($'line one\nline two')
request="$(_zoysh_build_request "system prompt" "current query")"
assert_eq "321" "$(printf '%s' "$request" | json_value 'data["max_tokens"]')" "token budget reaches request"
assert_eq "4" "$(printf '%s' "$request" | json_value 'len(data["messages"])')" "history reaches request"
assert_eq $'line one\nline two' "$(printf '%s' "$request" | json_value 'json.loads(data["messages"][2]["content"])["response"]')" "history preserves multiline reply"

ZOYSH_PROVIDER=openai
request="$(_zoysh_build_request "system prompt" "current query")"
assert_eq "False" "$(printf '%s' "$request" | json_value 'data["store"]')" "OpenAI requests disable storage"
assert_eq "321" "$(printf '%s' "$request" | json_value 'data["max_output_tokens"]')" "OpenAI token budget"

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
assert_eq "model response was truncated; increase token_budget" "$REPLY_CONTENT" "truncated response guidance"

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

ZOYSH_PROVIDER=openai
ZOYSH_API_KEY=local
api_response="$(_zoysh_call_llm "fixture request")"
api_status=$?
assert_eq "1" "$api_status" "hosted providers reject placeholder keys"
unfunction curl

tmp_config="$(mktemp "${TMPDIR:-/tmp}/zoysh-test.XXXXXX")" || exit 1
tmp_home="$(mktemp -d "${TMPDIR:-/tmp}/zoysh-home.XXXXXX")" || exit 1
tmp_stderr="$tmp_home/stderr"
trap 'rm -f -- "$tmp_config" "$tmp_home/.qwenkey" "$tmp_stderr"; rmdir -- "$tmp_home" 2>/dev/null' EXIT
printf '%s\n' \
    $'provider\tOPENAI' \
    'model release-model # comment' \
    'history_limit invalid' \
    'token_budget 777' \
    'timeout 15' > "$tmp_config"
ZOYSH_CONF="$tmp_config"
ZOYSH_HISTORY_LIMIT=10
_zoysh_load_config
_zoysh_validate_config 2>/dev/null
assert_eq "openai" "$ZOYSH_PROVIDER" "config accepts tabs and normalizes provider"
assert_eq "release-model" "$ZOYSH_MODEL" "config strips inline comments"
assert_eq "10" "$ZOYSH_HISTORY_LIMIT" "invalid history limit falls back"
assert_eq "777" "$ZOYSH_TOKEN_BUDGET" "config token budget"
assert_eq "15" "$ZOYSH_TIMEOUT" "config timeout"

printf '%s\n' 'file-key' > "$tmp_home/.qwenkey"
ZOYSH_PROVIDER=qwen
ZOYSH_API_KEY=local
HOME="$tmp_home"
_zoysh_resolve_key
assert_eq "local" "$ZOYSH_API_KEY" "explicit local key bypasses key files"
ZOYSH_API_KEY=""
_zoysh_resolve_key
assert_eq "file-key" "$ZOYSH_API_KEY" "missing key loads provider key file"

_zoysh_call_llm() {
    print -r -- '{"choices":[{"message":{"content":"{\"type\":\"chat\",\"response\":\"quiet response\"}"}}]}'
}
_zoysh_prepare_backend() { return 0 }
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
