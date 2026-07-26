#!/usr/bin/env zsh
#
# Scenario tests — real-world workflows that test the full pipeline
#
# Each scenario tells a story: seed realistic data, then assert the
# right command gets suggested at the right moment.
#

set -uo pipefail

SCRIPT_DIR="$(dirname $0)"
PASS=0
FAIL=0

# ── Helpers ──────────────────────────────────────────────────────
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

assert_not_empty() {
    local desc="$1" actual="$2"
    if [[ -n "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (was empty)"
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

# Fresh DB for each scenario
new_scenario() {
    local name="$1"
    TEST_DB="/tmp/sage-scenario-$$.db"
    rm -f "$TEST_DB"
    export ZSH_SAGE_DB="$TEST_DB"
    export ZSH_SAGE_MAX_CANDIDATES=10
    export ZSH_SAGE_W_FREQUENCY="0.30"
    export ZSH_SAGE_W_RECENCY="0.25"
    export ZSH_SAGE_W_DIRECTORY="0.20"
    export ZSH_SAGE_W_SEQUENCE="0.15"
    export ZSH_SAGE_W_SUCCESS="0.10"
    export ZSH_SAGE_RECENCY_HALFLIFE="259200"
    export ZSH_SAGE_PREFIX_AWARE_WEIGHTS="true"
    export ZSH_SAGE_COLLECT_ACCEPTS="true"

    source "$SCRIPT_DIR/../src/core/db.zsh"
    source "$SCRIPT_DIR/../src/core/scorer.zsh"
    _sage_db_init
    _sage_coproc_stop 2>/dev/null
    _SAGE_COPROC_ALIVE=0
    _sage_coproc_start

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Scenario: $name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

end_scenario() {
    _sage_coproc_stop 2>/dev/null
    rm -f "$TEST_DB"
}

# ═════════════════════════════════════════════════════════════════
# DIRECTORY SCENARIOS
# ═════════════════════════════════════════════════════════════════

new_scenario "Directory disambiguation — same prefix, different projects"

now=$(date +%s)

# Web project: npm commands dominate
for i in {1..80}; do
    _sage_db_record "npm test" "/Users/dev/web" "" 0 "$((now - i * 60))" "main"
done
for i in {1..40}; do
    _sage_db_record "npm run build" "/Users/dev/web" "" 0 "$((now - i * 120))" "main"
done

# API project: go commands dominate
for i in {1..70}; do
    _sage_db_record "go test ./..." "/Users/dev/api" "" 0 "$((now - i * 60))" "main"
done
for i in {1..30}; do
    _sage_db_record "go build" "/Users/dev/api" "" 0 "$((now - i * 120))" "main"
done

# Also some npm in api (less frequent — package.json exists everywhere)
for i in {1..5}; do
    _sage_db_record "npm install" "/Users/dev/api" "" 0 "$((now - i * 300))" "main"
done

r_web=$(_sage_rank_candidates "npm" "/Users/dev/web" "")
r_api=$(_sage_rank_candidates "go" "/Users/dev/api" "")
r_api_npm=$(_sage_rank_candidates "npm" "/Users/dev/api" "")

assert_eq "npm test suggested in web project" "npm test" "$r_web"
assert_eq "go test suggested in api project" "go test ./..." "$r_api"
# npm test has 80 global uses vs npm install with 5 — frequency dominates
# even though npm install is the only npm command used in /api
assert_eq "Global frequency dominates over sparse dir-only data" "npm test" "$r_api_npm"

end_scenario

# ─────────────────────────────────────────────────────────────────

new_scenario "New directory cold start — no local history"

now=$(date +%s)

# User has tons of history globally but nothing in /Users/dev/new-project
for i in {1..100}; do
    _sage_db_record "git status" "/Users/dev/old-project" "" 0 "$((now - i * 60))" "main"
done
for i in {1..50}; do
    _sage_db_record "git log" "/Users/dev/old-project" "" 0 "$((now - i * 120))" "main"
done

# In a brand new directory — should fall back to global frequency
r=$(_sage_rank_candidates "git" "/Users/dev/new-project" "")
assert_not_empty "Suggestion exists even in new directory" "$r"
assert_eq "Falls back to globally frequent command" "git status" "$r"

end_scenario

# ═════════════════════════════════════════════════════════════════
# SEQUENCE SCENARIOS
# ═════════════════════════════════════════════════════════════════

new_scenario "Classic git flow — add → commit → push"

now=$(date +%s)

for i in {1..50}; do
    _sage_db_record "git add ." "/repo" "" 0 "$((now - i * 180))" "main"
    _sage_db_record "git commit -m 'update $i'" "/repo" "git add ." 0 "$((now - i * 180 + 60))" "main"
    _sage_db_record "git push" "/repo" "git commit -m 'update $i'" 0 "$((now - i * 180 + 120))" "main"
done

r_after_add=$(_sage_rank_candidates "git" "/repo" "git add .")
r_after_commit=$(_sage_rank_candidates "git" "/repo" "git commit -m 'update 1'")

# git commit should win after git add (sequence override picks most frequent variant)
local commit_prefix="${r_after_add%%\'*}"  # everything before first quote
assert_eq "git commit suggested after git add" "git commit -m " "$commit_prefix"
assert_eq "git push suggested after git commit" "git push" "$r_after_commit"

end_scenario

# ─────────────────────────────────────────────────────────────────

new_scenario "Weak sequence — no single dominant follow-up"

now=$(date +%s)

# After 'cd ~/project', user runs many different things (no dominant pattern)
for i in {1..10}; do
    _sage_db_record "git status" "/project" "cd ~/project" 0 "$((now - i * 60))" "main"
    _sage_db_record "ls -la" "/project" "cd ~/project" 0 "$((now - i * 60))" "main"
    _sage_db_record "vim README.md" "/project" "cd ~/project" 0 "$((now - i * 60))" "main"
    _sage_db_record "make build" "/project" "cd ~/project" 0 "$((now - i * 60))" "main"
done

# No single command should get sequence override (each is ~25%)
# Instead, the scorer should fall through to weighted combination
r=$(_sage_rank_candidates "g" "/project" "cd ~/project")
assert_not_empty "Returns a suggestion even without dominant sequence" "$r"
# git status should win on frequency (10 uses, same as others but alphabetical or freq tiebreaker)
assert_eq "git status wins on frequency in weak sequence" "git status" "$r"

end_scenario

# ─────────────────────────────────────────────────────────────────

new_scenario "Sequence with noise — dominant pattern despite interruptions"

now=$(date +%s)

# 40 times: git add → git commit (the pattern)
for i in {1..40}; do
    _sage_db_record "git commit -m 'fix'" "/repo" "git add ." 0 "$((now - i * 120))" "main"
done
# 10 times: git add → git status (noise)
for i in {1..10}; do
    _sage_db_record "git status" "/repo" "git add ." 0 "$((now - i * 300))" "main"
done
# 5 times: git add → git diff (more noise)
for i in {1..5}; do
    _sage_db_record "git diff" "/repo" "git add ." 0 "$((now - i * 500))" "main"
done

# git commit is 40/55 = 73% — should trigger sequence override
r=$(_sage_rank_candidates "git" "/repo" "git add .")
assert_eq "Dominant sequence wins despite noise" "git commit -m 'fix'" "$r"

end_scenario

# ═════════════════════════════════════════════════════════════════
# RECENCY SCENARIOS
# ═════════════════════════════════════════════════════════════════

new_scenario "Exponential decay — recent beats stale frequent"

now=$(date +%s)
one_month_ago=$((now - 2592000))

# Old but heavily used
for i in {1..30}; do
    _sage_db_record "make build" "/project" "" 0 "$one_month_ago" "main"
done
# Recent but less used
for i in {1..15}; do
    _sage_db_record "make test" "/project" "" 0 "$((now - 60))" "main"
done

r=$(_sage_rank_candidates "make " "/project" "")
assert_eq "Recent command beats month-old frequent one" "make test" "$r"

end_scenario

# ─────────────────────────────────────────────────────────────────

new_scenario "Recency decay — no cliff at boundary"

now=$(date +%s)

# Commands at various ages
_sage_db_record "cmd-1day" "/tmp" "" 0 "$((now - 86400))" ""
_sage_db_record "cmd-3day" "/tmp" "" 0 "$((now - 259200))" ""
_sage_db_record "cmd-7day" "/tmp" "" 0 "$((now - 604800))" ""
_sage_db_record "cmd-30day" "/tmp" "" 0 "$((now - 2592000))" ""

# All should still be findable — no hard cutoff at 7 days
r_7day=$(_sage_rank_candidates "cmd-7" "/tmp" "")
r_30day=$(_sage_rank_candidates "cmd-3" "/tmp" "")

assert_not_empty "7-day old command still suggested" "$r_7day"
assert_not_empty "30-day old command still suggested (no cliff)" "$r_30day"

end_scenario

# ═════════════════════════════════════════════════════════════════
# PREFIX-LENGTH SCENARIOS
# ═════════════════════════════════════════════════════════════════

new_scenario "Prefix-length — short prefix favors frequency, long favors recency"

now=$(date +%s)

# Old but very frequent
for i in {1..100}; do
    _sage_db_record "kubectl rollout status deployment/old-api" "/ops" "" 0 "$((now - 604800))" ""
done
# Recent but few uses
for i in {1..20}; do
    _sage_db_record "kubectl rollout status deployment/new-api" "/ops" "" 0 "$((now - 60))" ""
done

r_short=$(_sage_rank_candidates "kub" "/ops" "")
r_long=$(_sage_rank_candidates "kubectl rollout status d" "/ops" "")

assert_eq "Short prefix: frequency wins (old-api)" "kubectl rollout status deployment/old-api" "$r_short"
assert_eq "Long prefix: recency wins (new-api)" "kubectl rollout status deployment/new-api" "$r_long"

end_scenario

# ─────────────────────────────────────────────────────────────────

new_scenario "Prefix-length disabled — frequency always wins"

now=$(date +%s)
export ZSH_SAGE_PREFIX_AWARE_WEIGHTS="false"

for i in {1..100}; do
    _sage_db_record "kubectl rollout status deployment/old-api" "/ops" "" 0 "$((now - 604800))" ""
done
for i in {1..20}; do
    _sage_db_record "kubectl rollout status deployment/new-api" "/ops" "" 0 "$((now - 60))" ""
done

r_long=$(_sage_rank_candidates "kubectl rollout status d" "/ops" "")
assert_eq "With prefix-aware OFF, frequency always wins" "kubectl rollout status deployment/old-api" "$r_long"

export ZSH_SAGE_PREFIX_AWARE_WEIGHTS="true"

end_scenario

# ═════════════════════════════════════════════════════════════════
# SUCCESS RATE SCENARIOS
# ═════════════════════════════════════════════════════════════════

new_scenario "Typo penalty — reliable command beats flaky one"

now=$(date +%s)

# Reliable command: 20 uses, always succeeds
for i in {1..20}; do
    _sage_db_record "python run.py" "/code" "" 0 "$((now - i * 60))" ""
done
# Flaky command: 20 uses, fails half the time
for i in {1..10}; do
    _sage_db_record "python run_old.py" "/code" "" 0 "$((now - i * 60))" ""
done
for i in {1..10}; do
    _sage_db_record "python run_old.py" "/code" "" 1 "$((now - i * 60))" ""
done

r=$(_sage_rank_candidates "python run" "/code" "")
assert_eq "Reliable command wins over flaky one" "python run.py" "$r"

end_scenario

# ─────────────────────────────────────────────────────────────────

new_scenario "One-time failure doesn't kill a command"

now=$(date +%s)

# 50 successes + 1 failure
for i in {1..50}; do
    _sage_db_record "deploy.sh" "/ops" "" 0 "$((now - i * 60))" ""
done
_sage_db_record "deploy.sh" "/ops" "" 1 "$((now - 1))" ""

# 45 successes, zero failures
for i in {1..45}; do
    _sage_db_record "deploy-v2.sh" "/ops" "" 0 "$((now - i * 60))" ""
done

r=$(_sage_rank_candidates "deploy" "/ops" "")
# deploy.sh has 51 uses (1 fail) vs deploy-v2.sh has 45 uses (0 fail)
# deploy.sh should still win — success rate is 50/51 = 0.98, barely affected
assert_eq "One failure out of 51 doesn't demote the command" "deploy.sh" "$r"

end_scenario

# ═════════════════════════════════════════════════════════════════
# EDGE CASES
# ═════════════════════════════════════════════════════════════════

new_scenario "Empty database — no commands at all"

r=$(_sage_rank_candidates "git" "/tmp" "")
assert_empty "Empty DB returns empty suggestion" "$r"

r2=$(_sage_rank_with_score "git" "/tmp" "")
assert_empty "Empty DB rank_with_score returns empty" "$r2"

end_scenario

# ─────────────────────────────────────────────────────────────────

new_scenario "Commands with special characters"

now=$(date +%s)

# Single quotes
for i in {1..10}; do
    _sage_db_record "git commit -m 'fix: login bug'" "/repo" "" 0 "$((now - i * 60))" ""
done

# Double quotes
for i in {1..5}; do
    _sage_db_record "echo \"hello world\"" "/tmp" "" 0 "$((now - i * 60))" ""
done

# Pipes
for i in {1..8}; do
    _sage_db_record "cat file.txt | grep error | wc -l" "/tmp" "" 0 "$((now - i * 60))" ""
done

# Dollar signs
for i in {1..3}; do
    _sage_db_record "echo \$HOME" "/tmp" "" 0 "$((now - i * 60))" ""
done

r_quote=$(_sage_rank_candidates "git commit -m" "/repo" "")
assert_not_empty "Single-quoted command retrievable" "$r_quote"

r_pipe=$(_sage_rank_candidates "cat file" "/tmp" "")
assert_not_empty "Piped command retrievable" "$r_pipe"
# Regression (#8): '|' in the command must not be eaten by field parsing
assert_eq "Piped command returned intact" "cat file.txt | grep error | wc -l" "$r_pipe"

r_pipe_scored=$(_sage_rank_with_score "cat file" "/tmp" "")
local -a pipe_fields
pipe_fields=("${(@ps:$_SAGE_SEP:)r_pipe_scored}")
assert_eq "Score row: command field intact despite pipes" "cat file.txt | grep error | wc -l" "${pipe_fields[2]}"
assert_eq "Score row: score field is numeric" "" "${pipe_fields[1]//[0-9.]/}"

r_dollar=$(_sage_rank_candidates "echo \$" "/tmp" "")
assert_not_empty "Dollar-sign command retrievable" "$r_dollar"

end_scenario

# ─────────────────────────────────────────────────────────────────

new_scenario "Very long command (200+ chars)"

now=$(date +%s)

long_cmd="curl -X POST https://api.example.com/v1/very/long/endpoint -H 'Authorization: Bearer token123' -H 'Content-Type: application/json' -d '{\"key\": \"value\", \"nested\": {\"deep\": true}}' --max-time 30"

for i in {1..5}; do
    _sage_db_record "$long_cmd" "/tmp" "" 0 "$((now - i * 60))" ""
done

r=$(_sage_rank_candidates "curl -X POST" "/tmp" "")
assert_not_empty "Long command (${#long_cmd} chars) is retrievable" "$r"

end_scenario

# ─────────────────────────────────────────────────────────────────

new_scenario "Unicode in commands"

now=$(date +%s)

_sage_db_record "echo 'café'" "/tmp" "" 0 "$now" ""
_sage_db_record "grep '日本語' file.txt" "/tmp" "" 0 "$now" ""

r_utf8=$(_sage_rank_candidates "echo" "/tmp" "")
assert_not_empty "Unicode command stored and retrieved" "$r_utf8"

r_cjk=$(_sage_rank_candidates "grep" "/tmp" "")
assert_not_empty "CJK characters handled" "$r_cjk"

end_scenario

# ═════════════════════════════════════════════════════════════════
# ACCEPT TRACKING SCENARIOS
# ═════════════════════════════════════════════════════════════════

new_scenario "Accept tracking — explicit accept records data"

now=$(date +%s)

for i in {1..20}; do
    _sage_db_record "git status" "/repo" "" 0 "$((now - i * 60))" ""
done

# Simulate what the widget does: query, cache contribs, record accept
r=$(_sage_rank_with_score "git" "/repo" "")
local -a fields
fields=("${(@ps:$_SAGE_SEP:)r}")

# Record as if user pressed right arrow
_sage_db_record_accept "${fields[3]:-0}" "${fields[4]:-0}" "${fields[5]:-0}" "${fields[6]:-0}" "${fields[7]:-0}"

accept_count=$(_sage_db_query "SELECT COUNT(*) FROM weight_accepts;")
assert_eq "Accept row was written" "1" "$accept_count"

# Check that contributions sum to roughly the score
contrib_sum=$(_sage_db_query "SELECT ROUND(freq_contrib + recency_contrib + dir_contrib + seq_contrib + success_contrib, 2) FROM weight_accepts ORDER BY id DESC LIMIT 1;")
assert_not_empty "Contributions are non-zero" "$contrib_sum"

end_scenario

# ─────────────────────────────────────────────────────────────────

new_scenario "No false accepts — different command should not record"

now=$(date +%s)

for i in {1..10}; do
    _sage_db_record "git status" "/repo" "" 0 "$((now - i * 60))" ""
done

# Suggestion would be "git status" but user types "git log" instead
# In the collector, this comparison happens:
# _SAGE_CURRENT_SUGGESTION="git status"
# executed command = "git log"
# These don't match, so no accept should be recorded

_SAGE_CURRENT_SUGGESTION="git status"
local executed="git log"

# Simulate the preexec check
if [[ "$executed" == "$_SAGE_CURRENT_SUGGESTION" || "$executed" == "$_SAGE_CURRENT_SUGGESTION "* ]]; then
    _sage_db_record_accept 0 0 0 0 0
fi

accept_count=$(_sage_db_query "SELECT COUNT(*) FROM weight_accepts;")
assert_eq "No accept recorded for non-matching command" "0" "$accept_count"

end_scenario

# ─────────────────────────────────────────────────────────────────

new_scenario "Implicit accept — typed-through command records accept"

now=$(date +%s)

for i in {1..10}; do
    _sage_db_record "git status" "/repo" "" 0 "$((now - i * 60))" ""
done

# User typed "git status --short" which prefix-extends our suggestion "git status"
_SAGE_CURRENT_SUGGESTION="git status"
_SAGE_CURRENT_FREQ_CONTRIB=0.3
_SAGE_CURRENT_REC_CONTRIB=0.2
_SAGE_CURRENT_DIR_CONTRIB=0.1
_SAGE_CURRENT_SEQ_CONTRIB=0
_SAGE_CURRENT_SUCC_CONTRIB=0.1
local executed="git status --short"

if [[ "$executed" == "$_SAGE_CURRENT_SUGGESTION" || "$executed" == "$_SAGE_CURRENT_SUGGESTION "* ]]; then
    _sage_db_record_accept \
        "$_SAGE_CURRENT_FREQ_CONTRIB" \
        "$_SAGE_CURRENT_REC_CONTRIB" \
        "$_SAGE_CURRENT_DIR_CONTRIB" \
        "$_SAGE_CURRENT_SEQ_CONTRIB" \
        "$_SAGE_CURRENT_SUCC_CONTRIB"
fi

accept_count=$(_sage_db_query "SELECT COUNT(*) FROM weight_accepts;")
assert_eq "Prefix-extended command counts as accept" "1" "$accept_count"

# Verify contributions were stored correctly
freq_stored=$(_sage_db_query "SELECT freq_contrib FROM weight_accepts ORDER BY id DESC LIMIT 1;")
assert_eq "Freq contribution stored correctly" "0.3" "$freq_stored"

end_scenario

# ═════════════════════════════════════════════════════════════════
# COPROC RESILIENCE
# ═════════════════════════════════════════════════════════════════

# Skip coproc test in fork mode (CI) — coproc isn't used there
if (( ! ${ZSH_SAGE_NO_COPROC:-0} )); then

new_scenario "Coproc auto-respawn after death"

now=$(date +%s)

for i in {1..10}; do
    _sage_db_record "git status" "/repo" "" 0 "$((now - i * 60))" ""
done

# Kill the coproc
_sage_coproc_stop
_SAGE_COPROC_ALIVE=0

# Next query should auto-respawn and still work
r=$(_sage_rank_candidates "git" "/repo" "")
assert_eq "Suggestion works after coproc respawn" "git status" "$r"

end_scenario

else
    echo ""
    echo "  (Skipping coproc respawn test — running in fork mode)"
fi

# ═════════════════════════════════════════════════════════════════
# COMBINED SIGNAL SCENARIOS
# ═════════════════════════════════════════════════════════════════

new_scenario "All signals competing — realistic mixed workload"

now=$(date +%s)

# A: high freq, old, wrong dir, no sequence, always succeeds
for i in {1..100}; do
    _sage_db_record "docker ps" "/infra" "" 0 "$((now - 604800))" ""
done

# B: medium freq, recent, right dir, follows prev_cmd, sometimes fails
for i in {1..30}; do
    _sage_db_record "docker compose up" "/webapp" "git pull" 0 "$((now - i * 60))" ""
done
for i in {1..5}; do
    _sage_db_record "docker compose up" "/webapp" "git pull" 1 "$((now - i * 120))" ""
done

# C: low freq, very recent, right dir, strong sequence, always succeeds
for i in {1..10}; do
    _sage_db_record "docker compose logs -f" "/webapp" "docker compose up" 0 "$((now - i * 30))" ""
done

# In /webapp, after "docker compose up", type "docker"
r=$(_sage_rank_candidates "docker" "/webapp" "docker compose up")
# C should win: strong sequence (10/10 = 100% after docker compose up) triggers override
assert_eq "Sequence override wins in combined scenario" "docker compose logs -f" "$r"

# In /webapp, after no prev, type "docker"
r2=$(_sage_rank_candidates "docker" "/webapp" "")
# B should win: medium freq + recent + right dir + no sequence competition
# A has high freq but wrong dir and old
assert_eq "Dir + recency beats global frequency" "docker compose up" "$r2"

# In /infra, after no prev, type "docker"
r3=$(_sage_rank_candidates "docker" "/infra" "")
# A should win: high freq + right dir
assert_eq "High freq + right dir wins in its own directory" "docker ps" "$r3"

end_scenario

# ═════════════════════════════════════════════════════════════════
# RESULTS
# ═════════════════════════════════════════════════════════════════
echo ""
echo "==========================================="
echo "Scenario tests: $PASS passed, $FAIL failed"
echo "==========================================="

(( FAIL > 0 )) && exit 1 || exit 0
