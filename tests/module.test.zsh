#!/bin/zsh
#
# Native module tests. Gated behind ZMODULE=1 because they require a built
# zoysh.so ("make module") plus a configured zsh source tree; plain
# "make check" never runs them.

emulate -L zsh
setopt pipe_fail

typeset -gr TEST_ROOT="${0:A:h:h}"

if [[ "${ZMODULE:-0}" != "1" ]]; then
    print -r -- "1..0 # skip set ZMODULE=1 after make module"
    exit 0
fi

if [[ ! -f "${TEST_ROOT}/zoysh.so" ]]; then
    print -u2 -r -- "module tests need ${TEST_ROOT}/zoysh.so (run make module)"
    exit 1
fi

typeset -gi TESTS_RUN=0
typeset -gi TESTS_FAILED=0

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    (( TESTS_RUN++ ))
    if [[ "$actual" == "$expected" ]]; then
        print -r -- "ok ${TESTS_RUN} - ${label}"
    else
        print -u2 -r -- "not ok - ${label} (expected ${(qqq)expected}, got ${(qqq)actual})"
        (( TESTS_FAILED++ ))
    fi
}

module_dir="$(mktemp -d "${TMPDIR:-/tmp}/zoysh-modpath.XXXXXX")" || exit 1
mkdir -p "${module_dir}/zsh"
cp "${TEST_ROOT}/zoysh.so" "${module_dir}/zsh/zoysh.so"

zmodload zsh/zpty 2>/dev/null
zmodload zsh/datetime

module_path=("${module_dir}" $module_path)
zmodload zsh/zoysh
assert_eq "1" "$(( ${+builtins[zoysh-status]} ))" "the module registers zoysh-status"
assert_eq "1" "$(( ${+builtins[zoysh-call]} ))" "the module registers zoysh-call"

conf="$(mktemp "${TMPDIR:-/tmp}/zoysh-modconf.XXXXXX")" || exit 1
printf 'provider local\nbase_url http://127.0.0.1:9199/v1\nkey local\ntimeout 15\nstreaming 0\ncontinuation 1\n' > "$conf"
export ZOYSH_CONF="$conf"
zoysh_status_output="$(zoysh-status)"
[[ "$zoysh_status_output" == *"provider local"* ]] && status_provider=1 || status_provider=0
assert_eq "1" "$status_provider" "zoysh-status reports the configured provider"
[[ "$zoysh_status_output" == *"endpoint http://127.0.0.1:9199/v1/chat/completions"* ]] && status_endpoint=1 || status_endpoint=0
assert_eq "1" "$status_endpoint" "zoysh-status resolves the chat completions endpoint"
[[ "$zoysh_status_output" == *"streaming 0 continuation 1"* ]] && status_flags=1 || status_flags=0
assert_eq "1" "$status_flags" "zoysh-status reflects streaming and continuation"

# ── end-to-end through the bridge against the stub ──────────────────────────

stub_log="$(mktemp "${TMPDIR:-/tmp}/zoysh-modstub.XXXXXX")" || exit 1
stub_port=$(( 23000 + RANDOM % 9000 ))
python3 "${TEST_ROOT}/tests/stub_server.py" "$stub_port" chat-md "$stub_log" >/dev/null 2>&1 &
stub_pid=$!

waited=0
until curl -fsS --max-time 1 "http://127.0.0.1:${stub_port}/v1/models" >/dev/null 2>&1; do
    if ! kill -0 "$stub_pid" 2>/dev/null; then
        print -u2 -r -- "stub server died"
        exit 1
    fi
    (( waited++ > 40 )) && { print -u2 -r -- "stub server failed to start"; exit 1 }
    sleep 0.1
done

zstyle ':zoysh:engine' engine module
printf 'provider local\nbase_url http://127.0.0.1:%s/v1\nkey local\n' "$stub_port" > "$conf"
source "${TEST_ROOT}/zoysh.plugin.zsh"

module_answer="$(yo -c "explain" 2>/dev/null)"

zstyle ':zoysh:engine' engine script
script_answer="$(yo -c "explain" 2>/dev/null)"

module_tail="${module_answer##*$'\033'\[2K}"
module_tail="${module_tail#$'\r'}"
script_tail="${script_answer##*$'\033'\[2K}"
script_tail="${script_tail#$'\r'}"
assert_eq "$script_tail" "$module_tail" "module engine renders byte-identical output to the script engine"

module_stream_requested="$(python3 -c '
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
' "$stub_log")"
assert_eq "2" "$module_stream_requested" "both engines ask the stub for SSE"

kill "$stub_pid" 2>/dev/null
wait "$stub_pid" 2>/dev/null

zmodload -u zsh/zoysh
assert_eq "0" "$(( ${+builtins[zoysh-status]} ))" "the module unloads cleanly"

rm -f -- "$conf" "$stub_log"
rm -rf -- "$module_dir"

print -r -- "1..${TESTS_RUN}"
if (( TESTS_FAILED )); then
    print -u2 -r -- "${TESTS_FAILED} module test(s) failed"
    exit 1
fi
print -r -- "All ${TESTS_RUN} module tests passed"
