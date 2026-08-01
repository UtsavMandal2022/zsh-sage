#!/usr/bin/env zsh
#
# Test: Database layer — creation, recording, querying, persistence
#

set -uo pipefail

TEST_DB="/tmp/sage-test-$$.db"
PASS=0
FAIL=0

# Source only what we need
export ZSH_SAGE_DB="$TEST_DB"
export ZSH_SAGE_MAX_CANDIDATES=10
# Force fork-mode for every DB call so each operation opens, commits,
# and closes within a single sqlite3 process. The persistent coproc
# would run alongside the verifying `sqlite3 "$TEST_DB" "..."` forks,
# producing transient `database is locked` failures even under WAL.
export ZSH_SAGE_NO_COPROC=1
source "$(dirname $0)/../src/core/db.zsh"

cleanup() {
    rm -f "$TEST_DB"
}
trap cleanup EXIT

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected to contain: '$needle'"
        echo "    actual: '$haystack'"
        FAIL=$((FAIL + 1))
    fi
}

assert_empty() {
    local desc="$1" actual="$2"
    if [[ -z "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected empty, got: '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

# ─────────────────────────────────────────────────────────────────
echo "=== Test: DB Initialization ==="

_sage_db_init
assert_eq "DB file created" "true" "$([ -f $TEST_DB ] && echo true || echo false)"

# Verify tables exist
tables=$(sqlite3 "$TEST_DB" ".tables")
assert_contains "commands table exists" "commands" "$tables"
assert_contains "stats table exists" "stats" "$tables"

# Re-init should not fail (idempotent)
_sage_db_init
assert_eq "Re-init is safe" "true" "$([ -f $TEST_DB ] && echo true || echo false)"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Test: Recording Commands ==="

now=$(date +%s)

_sage_db_record "git status" "/home/user/project" "" 0 "$now" "main"
_sage_db_record "git commit -m 'fix bug'" "/home/user/project" "git status" 0 "$((now+1))" "main"
_sage_db_record "git push" "/home/user/project" "git commit -m 'fix bug'" 0 "$((now+2))" "main"
_sage_db_record "npm test" "/home/user/webapp" "" 0 "$((now+3))" "feature/auth"
_sage_db_record "npm test" "/home/user/webapp" "npm install" 1 "$((now+4))" "feature/auth"
_sage_db_record "git status" "/home/user/project" "git push" 0 "$((now+5))" "main"

cmd_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM commands;")
assert_eq "6 commands recorded" "6" "$cmd_count"

stat_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM stats;")
assert_eq "4 unique stats entries" "4" "$stat_count"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Test: Frequency Tracking ==="

git_status_freq=$(sqlite3 "$TEST_DB" "SELECT frequency FROM stats WHERE command='git status' AND directory='/home/user/project';")
assert_eq "git status frequency is 2" "2" "$git_status_freq"

npm_test_freq=$(sqlite3 "$TEST_DB" "SELECT frequency FROM stats WHERE command='npm test' AND directory='/home/user/webapp';")
assert_eq "npm test frequency is 2" "2" "$npm_test_freq"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Test: Success/Fail Tracking ==="

npm_success=$(sqlite3 "$TEST_DB" "SELECT success_count FROM stats WHERE command='npm test';")
assert_eq "npm test success count is 1" "1" "$npm_success"

npm_fail=$(sqlite3 "$TEST_DB" "SELECT fail_count FROM stats WHERE command='npm test';")
assert_eq "npm test fail count is 1" "1" "$npm_fail"

git_status_success=$(sqlite3 "$TEST_DB" "SELECT success_count FROM stats WHERE command='git status' AND directory='/home/user/project';")
assert_eq "git status all succeeded" "2" "$git_status_success"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Test: Candidate Query (prefix match) ==="

candidates=$(_sage_db_candidates "git" "/home/user/project")
assert_contains "git status in candidates" "git status" "$candidates"
assert_contains "git commit in candidates" "git commit" "$candidates"
assert_contains "git push in candidates" "git push" "$candidates"

# npm should not appear for "git" prefix
npm_in_git=$(echo "$candidates" | grep -c "npm" || true)
assert_eq "npm not in git prefix results" "0" "$npm_in_git"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Test: Directory-Specific Candidates ==="

dir_candidates=$(_sage_db_candidates_dir "npm" "/home/user/webapp")
assert_contains "npm test in webapp dir" "npm test" "$dir_candidates"

dir_candidates_wrong=$(_sage_db_candidates_dir "npm" "/home/user/project")
assert_empty "no npm in project dir" "$dir_candidates_wrong"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Test: Sequence Score ==="

seq_score=$(_sage_db_sequence_score "git commit" "git status")
assert_eq "git commit follows git status (score > 0)" "true" "$(echo "$seq_score > 0" | bc -l | grep -q 1 && echo true || echo false)"

seq_score_zero=$(_sage_db_sequence_score "npm test" "git status")
assert_eq "npm test doesn't follow git status" "true" "$(echo "$seq_score_zero == 0" | bc -l | grep -q 1 && echo true || echo false)"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Test: Persistence Across Sessions ==="

# Save the DB path and verify data survives re-source
db_path="$TEST_DB"
unset _sage_db_init  # Would be unset in a new shell

# Re-source and re-query (simulating a new shell session)
source "$(dirname $0)/../src/core/db.zsh"
ZSH_SAGE_DB="$db_path"

persisted_count=$(sqlite3 "$ZSH_SAGE_DB" "SELECT COUNT(*) FROM commands;")
assert_eq "Commands persist after re-source" "6" "$persisted_count"

persisted_freq=$(sqlite3 "$ZSH_SAGE_DB" "SELECT frequency FROM stats WHERE command='git status' AND directory='/home/user/project';")
assert_eq "Frequencies persist after re-source" "2" "$persisted_freq"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Test: SQL Injection Safety ==="

# Command with single quotes should not break SQL
_sage_db_record "echo 'hello world'" "/tmp" "" 0 "$now" ""
escaped_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM commands WHERE command LIKE '%hello world%';")
assert_eq "Single-quoted command recorded safely" "1" "$escaped_count"

# Command with special chars
_sage_db_record 'ls -la | grep "test"' "/tmp" "" 0 "$now" ""
special_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM commands WHERE command LIKE '%grep%';")
assert_eq "Pipe+quotes command recorded safely" "1" "$special_count"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Test: Coproc-spawn notification suppression (issue #5, PR #13) ==="

# Regression guard for issue #5: zsh's job control prints "[N] PID" when a
# coproc is spawned in an interactive shell (MONITOR on). The fix uses
# `setopt local_options no_monitor` BEFORE invoking `coproc` so the
# notification is suppressed at spawn time — `disown` alone runs too late.
#
# We can't easily exercise terminal-output behavior from a non-PTY test, so
# whitebox-check that the function body keeps the setopt line *before* the
# coproc invocation. Catches accidental removal or re-ordering during refactors.
# Anchor on `coproc sqlite3` (the actual invocation) rather than the bare word
# `coproc` — the latter also appears in the function name `_sage_coproc_start`.
coproc_start_body="$(typeset -f _sage_coproc_start)"
before_invocation="${coproc_start_body%%coproc sqlite3*}"
after_invocation="${coproc_start_body#*coproc sqlite3}"

case "$before_invocation" in
    *no_monitor*) echo "  PASS: setopt no_monitor present before coproc invocation"; PASS=$((PASS+1)) ;;
    *)            echo "  FAIL: no_monitor not found before coproc — spawn notification will leak"; FAIL=$((FAIL+1)) ;;
esac

case "$after_invocation" in
    *no_monitor*) echo "  FAIL: no_monitor appears AFTER coproc — would be too late to suppress spawn"; FAIL=$((FAIL+1)) ;;
    *)            echo "  PASS: no_monitor not placed after coproc (correct position)"; PASS=$((PASS+1)) ;;
esac

# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Test: History import (fc-based parsing) ==="

IMPORT_HIST="/tmp/sage-test-hist-$$"
IMPORT_DB="/tmp/sage-test-import-$$.db"

# Generate an authentic zsh histfile: metafied unicode, multiline
# continuations, and extended-history timestamps — the formats a
# naive line-by-line parser gets wrong.
zsh -fi -c '
HISTFILE='"$IMPORT_HIST"' HISTSIZE=1000 SAVEHIST=1000
setopt EXTENDED_HISTORY
print -s "git status"
print -s "echo '\''single quoted'\''"
print -s "echo \"héllo — 日本語のテスト\""
print -s $'\''for i in 1 2\ndo echo $i\ndone'\''
print -s "ps -ef | grep foo"
fc -W
' </dev/null 2>/dev/null

ZSH_SAGE_DB="$IMPORT_DB" _sage_db_init
import_out=$(ZSH_SAGE_DB="$IMPORT_DB" _sage_db_import_history "$IMPORT_HIST" 2>/dev/null)

row_count=$(sqlite3 "$IMPORT_DB" "SELECT COUNT(*) FROM commands;")
assert_eq "Import: 5 history entries -> 5 rows (multiline not split)" "5" "$row_count"
assert_contains "Import: reported count matches DB" "Imported 5 history" "$import_out"

unicode_row=$(sqlite3 "$IMPORT_DB" "SELECT COUNT(*) FROM commands WHERE command = 'echo \"héllo — 日本語のテスト\"';")
assert_eq "Import: unicode command unmetafied and intact" "1" "$unicode_row"

multiline_row=$(sqlite3 "$IMPORT_DB" "SELECT COUNT(*) FROM commands WHERE command LIKE 'for i in 1 2%done' AND command LIKE '%' || char(10) || '%';")
assert_eq "Import: multiline command stored as one row with real newlines" "1" "$multiline_row"

quote_row=$(sqlite3 "$IMPORT_DB" "SELECT COUNT(*) FROM commands WHERE command = 'echo ''single quoted''';")
assert_eq "Import: single quotes escaped, no backslash artifacts" "1" "$quote_row"

fake_ts=$(sqlite3 "$IMPORT_DB" "SELECT COUNT(*) FROM commands WHERE timestamp = 0 OR timestamp IS NULL;")
assert_eq "Import: every row has a real timestamp" "0" "$fake_ts"

rm -f "$IMPORT_DB" "$IMPORT_HIST"

# Regression (#9): huge commands + allexport must not hit ARG_MAX.
# The old batch-in-a-variable design leaked the batch into child env
# under `setopt allexport` and silently dropped whole batches.
echo ""
echo "=== Test: Import at scale under allexport (#9) ==="

IMPORT_BIG="/tmp/sage-test-bighist-$$"
IMPORT_BIGDB="/tmp/sage-test-bigimport-$$.db"
{
    local i pad
    pad="$(printf 'y%.0s' {1..3000})"
    for i in {1..600}; do
        print -r -- ": $((1785000000 + i)):0;echo ${pad} # cmd${i}"
    done
} > "$IMPORT_BIG"

big_count=$(zsh -f -c "
setopt allexport
source '$(dirname $0)/../src/core/db.zsh'
export ZSH_SAGE_DB='$IMPORT_BIGDB'
_sage_db_init
_sage_db_import_history '$IMPORT_BIG' >/dev/null 2>&1
sqlite3 '$IMPORT_BIGDB' 'SELECT COUNT(*) FROM commands;'
")
assert_eq "Import: 600 huge commands land under allexport (no ARG_MAX loss)" "600" "$big_count"

rm -f "$IMPORT_BIG" "$IMPORT_BIGDB"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==========================================="

(( FAIL > 0 )) && exit 1
exit 0
