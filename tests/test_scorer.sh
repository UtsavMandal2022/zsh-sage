#!/usr/bin/env zsh
#
# Test: Scorer — multi-signal ranking produces correct ordering
#

zmodload zsh/datetime

set -uo pipefail

TEST_DB="/tmp/sage-scorer-test-$$.db"
PASS=0
FAIL=0

# Source modules
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

# ── Seed the database with realistic data ────────────────────────
_sage_db_init

now=$EPOCHSECONDS
one_hour_ago=$((now - 3600))
one_day_ago=$((now - 86400))
one_week_ago=$((now - 604800))

# Scenario: user in ~/project types "git co"
# git commit: high freq (50x), used 5 min ago, always in this dir, follows "git add"
for i in {1..50}; do
    _sage_db_record "git commit -m 'update'" "/Users/user/project" "git add ." 0 "$((now - i * 60))" "main"
done

# git config: low freq (3x), used a week ago, global not dir-specific
for i in {1..3}; do
    _sage_db_record "git config user.name" "/Users/user" "" 0 "$((one_week_ago - i * 60))" ""
done

# git checkout main: medium freq (20x), used 1 day ago, in this dir
for i in {1..20}; do
    _sage_db_record "git checkout main" "/Users/user/project" "" 0 "$((one_day_ago - i * 60))" "feature/xyz"
done

# git commit --amend: low freq (5x), used recently, in this dir, but often fails
for i in {1..3}; do
    _sage_db_record "git commit --amend" "/Users/user/project" "git add ." 0 "$((now - i * 120))" "main"
done
for i in {1..2}; do
    _sage_db_record "git commit --amend" "/Users/user/project" "git add ." 1 "$((now - i * 300))" "main"
done

echo "=== Test: Ranking — frequency + recency dominate ==="

_sage_rank_candidates "git co" "/Users/user/project" "git add ."
result="$REPLY"
assert_eq "git commit wins over git config/checkout" "git commit -m 'update'" "$result"

echo ""
echo "=== Test: Ranking — directory affinity matters ==="

# From /Users/user (not project), git config should rank higher
_sage_rank_candidates "git co" "/Users/user" ""
result2="$REPLY"
echo "  (top suggestion from /Users/user: $result2)"
# git config is the only one specifically recorded in /Users/user
# so it should get a directory boost there

echo ""
echo "=== Test: Ranking — sequence context matters ==="

# After "git add .", "git commit" should strongly beat "git checkout"
_sage_rank_candidates "git co" "/Users/user/project" "git add ."
result3="$REPLY"
assert_eq "After 'git add .', commit wins" "git commit -m 'update'" "$result3"

# After no particular command, the order might differ
_sage_rank_candidates "git co" "/Users/user/project" "ls -la"
result4="$REPLY"
echo "  (top suggestion after 'ls -la': $result4)"

echo ""
echo "=== Test: Ranking — success rate penalty ==="

# git commit --amend has 60% success (3/5) vs git commit at 100%
# Even though amend is more recent per-call, commit should still win
_sage_rank_candidates "git commit" "/Users/user/project" "git add ."
result5="$REPLY"
assert_eq "Reliable command beats flaky one" "git commit -m 'update'" "$result5"

echo ""
echo "=== Test: Scoring individual signals ==="

# Manually check that a high-frequency recent command scores well
candidate="git commit -m 'update'|50|${now}|50|0"
_sage_score_candidate "$candidate" "/Users/user/project" "git add ." "$now"
score=${reply[1]}
echo "  High-signal candidate score: $score"
assert_eq "High-signal score > 0.3" "true" "$(echo "$score > 0.3" | bc -l | grep -q 1 && echo true || echo false)"

# Low-frequency old command should score poorly
candidate_low="git config user.name|3|${one_week_ago}|3|0"
_sage_score_candidate "$candidate_low" "/Users/user/project" "" "$now"
score_low=${reply[1]}
echo "  Low-signal candidate score: $score_low"
assert_eq "Low-signal score < high-signal score" "true" "$(echo "$score_low < $score" | bc -l | grep -q 1 && echo true || echo false)"

echo ""
echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==========================================="

(( FAIL > 0 )) && exit 1 || exit 0
