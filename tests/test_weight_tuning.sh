#!/usr/bin/env zsh
#
# Test: Weight tuning — verify each signal independently affects ranking
# This test isolates each signal to ensure weights are effective
#

zmodload zsh/datetime

set -uo pipefail

TEST_DB="/tmp/sage-weight-test-$$.db"
PASS=0
FAIL=0

export ZSH_SAGE_DB="$TEST_DB"
export ZSH_SAGE_MAX_CANDIDATES=10
export ZSH_SAGE_W_FREQUENCY="0.30"
export ZSH_SAGE_W_RECENCY="0.25"
export ZSH_SAGE_W_DIRECTORY="0.20"
export ZSH_SAGE_W_SEQUENCE="0.15"
export ZSH_SAGE_W_SUCCESS="0.10"

source "$(dirname $0)/../src/core/db.zsh"
source "$(dirname $0)/../src/core/scorer.zsh"

cleanup() { rm -f "$TEST_DB"; }
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

now=$EPOCHSECONDS

# ─────────────────────────────────────────────────────────────────
echo "=== Scenario 1: Frequency is the tiebreaker ==="
echo "    Two commands, same recency/dir/sequence/success, different frequency"

rm -f "$TEST_DB"
_sage_db_init

# Both used just now, same dir, same prev_cmd, same success rate
for i in {1..100}; do
    _sage_db_record "docker build ." "/app" "cd /app" 0 "$now" "main"
done
for i in {1..10}; do
    _sage_db_record "docker build --no-cache ." "/app" "cd /app" 0 "$now" "main"
done

_sage_rank_candidates "docker b" "/app" "cd /app"
result="$REPLY"
assert_eq "Higher frequency wins" "docker build ." "$result"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Scenario 2: Recency overcomes moderate frequency gap ==="
echo "    Old frequent cmd vs recent less-frequent cmd"

rm -f "$TEST_DB"
_sage_db_init

one_month_ago=$((now - 2592000))

# Old but heavily used
for i in {1..30}; do
    _sage_db_record "make build" "/project" "" 0 "$one_month_ago" "main"
done
# Recent but less used
for i in {1..15}; do
    _sage_db_record "make test" "/project" "" 0 "$((now - 60))" "main"
done

_sage_rank_candidates "make " "/project" ""
result="$REPLY"
echo "  Winner: $result"
# With frequency weight 0.30 and recency 0.25, a month-old command
# with 2x frequency should lose to a recent one

_sage_score_candidate "make build|30|${one_month_ago}|30|0" "/project" "" "$now"
score_build=${reply[1]}
_sage_score_candidate "make test|15|$((now - 60))|15|0" "/project" "" "$now"
score_test=${reply[1]}
echo "  make build score: $score_build"
echo "  make test  score: $score_test"
assert_eq "Recent command wins over stale frequent one" "make test" "$result"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Scenario 3: Directory affinity matters ==="
echo "    Same command, different frequencies per directory"

rm -f "$TEST_DB"
_sage_db_init

# npm start used a lot in /webapp
for i in {1..40}; do
    _sage_db_record "npm start" "/webapp" "" 0 "$((now - i * 30))" "main"
done
# npm start:dev used less globally, but more in /webapp-v2
for i in {1..10}; do
    _sage_db_record "npm start:dev" "/webapp-v2" "" 0 "$((now - i * 30))" "dev"
done
for i in {1..5}; do
    _sage_db_record "npm start" "/webapp-v2" "" 0 "$((now - i * 30))" "dev"
done

_sage_rank_candidates "npm start" "/webapp-v2" ""
result_v2="$REPLY"
echo "  In /webapp-v2: $result_v2"
# npm start:dev should get a directory boost in /webapp-v2
# but npm start has 4x global frequency... let's see what the weights do

_sage_rank_candidates "npm start" "/webapp" ""
result_webapp="$REPLY"
echo "  In /webapp: $result_webapp"
assert_eq "npm start wins in /webapp (high dir freq)" "npm start" "$result_webapp"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Scenario 4: Command sequence strongly influences ==="
echo "    After 'git add .', commit should beat checkout"

rm -f "$TEST_DB"
_sage_db_init

# Both equally frequent and recent
for i in {1..20}; do
    _sage_db_record "git commit -m 'wip'" "/repo" "git add ." 0 "$((now - i * 60))" "main"
done
for i in {1..20}; do
    _sage_db_record "git checkout dev" "/repo" "git pull" 0 "$((now - i * 60))" "main"
done

_sage_rank_candidates "git c" "/repo" "git add ."
result_after_add="$REPLY"
assert_eq "After 'git add .', commit wins" "git commit -m 'wip'" "$result_after_add"

_sage_rank_candidates "git c" "/repo" "git pull"
result_after_pull="$REPLY"
assert_eq "After 'git pull', checkout wins" "git checkout dev" "$result_after_pull"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Scenario 5: Failed commands get penalized ==="
echo "    Same freq, same recency, but different success rates"

rm -f "$TEST_DB"
_sage_db_init

# Command A: always succeeds
for i in {1..20}; do
    _sage_db_record "python run.py" "/code" "" 0 "$((now - i * 60))" ""
done
# Command B: fails half the time
for i in {1..10}; do
    _sage_db_record "python run_old.py" "/code" "" 0 "$((now - i * 60))" ""
done
for i in {1..10}; do
    _sage_db_record "python run_old.py" "/code" "" 1 "$((now - i * 60))" ""
done

_sage_rank_candidates "python run" "/code" ""
result="$REPLY"
assert_eq "Reliable command beats flaky one" "python run.py" "$result"

_sage_score_candidate "python run.py|20|${now}|20|0" "/code" "" "$now"
s1=${reply[1]}
_sage_score_candidate "python run_old.py|20|${now}|10|10" "/code" "" "$now"
s2=${reply[1]}
echo "  python run.py     score: $s1 (100% success)"
echo "  python run_old.py score: $s2 (50% success)"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Scenario 6: Weight override test ==="
echo "    Cranking recency to 1.0 makes it dominate"

rm -f "$TEST_DB"
_sage_db_init

# Old command with huge frequency
for i in {1..200}; do
    _sage_db_record "kubectl get pods" "/ops" "" 0 "$((now - 604800))" ""
done
# Very recent command with low frequency
for i in {1..3}; do
    _sage_db_record "kubectl get nodes" "/ops" "" 0 "$((now - 10))" ""
done

# Default weights: frequency should win
_sage_rank_candidates "kubectl get" "/ops" ""
result_default="$REPLY"
echo "  Default weights winner: $result_default"

# Override: crank recency
ZSH_SAGE_W_FREQUENCY="0.05"
ZSH_SAGE_W_RECENCY="0.80"
ZSH_SAGE_W_DIRECTORY="0.05"
ZSH_SAGE_W_SEQUENCE="0.05"
ZSH_SAGE_W_SUCCESS="0.05"

_sage_rank_candidates "kubectl get" "/ops" ""
result_recency="$REPLY"
echo "  Recency-heavy winner: $result_recency"
assert_eq "Recency-heavy weights favor recent cmd" "kubectl get nodes" "$result_recency"

# Restore defaults
ZSH_SAGE_W_FREQUENCY="0.30"
ZSH_SAGE_W_RECENCY="0.25"
ZSH_SAGE_W_DIRECTORY="0.20"
ZSH_SAGE_W_SEQUENCE="0.15"
ZSH_SAGE_W_SUCCESS="0.10"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==========================================="

(( FAIL > 0 )) && exit 1 || exit 0
