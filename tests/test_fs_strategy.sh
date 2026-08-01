#!/usr/bin/env zsh
#
# Filesystem strategy tests — glob-based fallback suggestions (issue #19)
#
# Unit-tests _sage_strategy_fs against a fixture directory, then drives
# _sage_update_suggestion with a stubbed empty scorer to verify the
# widget-level fallback wiring and the ZSH_SAGE_FS_SUGGEST toggle.
#

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
PASS=0
FAIL=0

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

# ── Fixture directory ────────────────────────────────────────────
FIXTURE_DIR="$(mktemp -d /tmp/sage-fs-test-XXXXXX)"
cleanup() { cd /; rm -rf "$FIXTURE_DIR"; }
trap cleanup EXIT

mkdir -p "$FIXTURE_DIR/src" "$FIXTURE_DIR/scripts"
touch "$FIXTURE_DIR/README.md" \
      "$FIXTURE_DIR/Rakefile" \
      "$FIXTURE_DIR/README FINAL.md" \
      "$FIXTURE_DIR/.zshrc" \
      "$FIXTURE_DIR/src/REPL.zsh" \
      "$FIXTURE_DIR/日本語ファイル.txt"
cd "$FIXTURE_DIR"

typeset -g _SAGE_SEP=$'\x1f'
source "$SCRIPT_DIR/../src/strategies/fs.zsh"

# Helper: run strategy, replace SEP with | for readable assertions
fs() {
    local out
    out=$(_sage_strategy_fs "$@")
    print -r -- "${out//$_SAGE_SEP/|}"
}

# ── Unit tests: matching ─────────────────────────────────────────
echo ""
echo "=== Test: Basic filesystem matching ==="

assert_eq "Argument-position file match" \
    "0.15|vim README\\ FINAL.md" "$(fs 'vim RE' | head -1)"

assert_eq "Path prefix match in subdirectory" \
    "0.15|cat src/REPL.zsh" "$(fs 'cat src/RE')"

assert_eq "Directory gets trailing slash" \
    "0.15|ls scripts/" "$(fs 'ls scr' | head -1)"

assert_eq "Exact directory name still suggests slash" \
    "0.15|ls scripts/" "$(fs 'ls scripts' | head -1)"

assert_eq "Unicode filename round-trips" \
    "0.15|cat 日本語ファイル.txt" "$(fs 'cat 日本')"

echo ""
echo "=== Test: Escaping ==="

esc_out="$(fs 'vim README' | head -1)"
assert_eq "Filename with space is backslash-escaped" \
    "0.15|vim README\\ FINAL.md" "$esc_out"
sug="${esc_out#*|}"
assert_eq "Escaped suggestion still extends the typed prefix" \
    "true" "$([[ "$sug" == "vim README"* ]] && echo true || echo false)"

echo ""
echo "=== Test: Dotfiles ==="

assert_eq "Dotfile not matched without leading dot" "" "$(fs 'cat z')"
assert_eq "Dotfile matched with leading dot" "0.15|cat .zshrc" "$(fs 'cat .z')"

echo ""
echo "=== Test: Multi-match mode (cycling) ==="

multi="$(fs 'vim R' 3)"
assert_eq "Limit of 3 returns 3 lines" "3" "$(print -r -- "$multi" | wc -l | tr -d ' ')"
assert_eq "Matches are lexicographically sorted" \
    "0.15|vim Rakefile" "$(print -r -- "$multi" | head -1)"

echo ""
echo "=== Test: Cases that must NOT fire ==="

assert_eq "Buffer ending in space" "" "$(fs 'vim RE ')"
assert_eq "Flag word" "" "$(fs 'ls -la')"
assert_eq "Bare command position" "" "$(fs 'REA')"
assert_eq "Explicit ./ path in command position fires" \
    "0.15|./README\\ FINAL.md" "$(fs './REA' | head -1)"
assert_eq "Word with \$VAR" "" "$(fs 'vim $HOME/RE')"
assert_eq "Word with tilde" "" "$(fs 'vim ~/RE')"
assert_eq "Word with glob star" "" "$(fs 'vim RE*')"
assert_eq "Word with quote" "" "$(fs "vim 'RE")"
assert_eq "No filesystem match" "" "$(fs 'vim zzz')"
assert_eq "Empty buffer" "" "$(fs '')"

echo ""
echo "=== Test: Large directory cap ==="

mkdir -p "$FIXTURE_DIR/big" && cd "$FIXTURE_DIR/big"
for i in {1..1000}; do : > "file$i.txt"; done
big_out="$(fs 'vim file' 8)"
assert_eq "1000-file dir capped at limit" "8" "$(print -r -- "$big_out" | wc -l | tr -d ' ')"

typeset -F SECONDS=0
_sage_strategy_fs 'vim file' 1 > /dev/null
elapsed=$SECONDS
assert_eq "1000-file lookup under 9ms budget" \
    "true" "$( (( elapsed < 0.009 )) && echo true || echo false )"
cd "$FIXTURE_DIR"

# ── Widget-level tests: fallback wiring + toggle ─────────────────
echo ""
echo "=== Test: Widget fallback wiring ==="

typeset -ga region_highlight=()
source "$SCRIPT_DIR/../src/core/widget.zsh"
_sage_highlight_reset() { :; }
_sage_highlight_apply() { :; }

# Stub the scorer: history DB knows nothing
_sage_rank_with_score() { return 0; }

reset_state() {
    BUFFER=""
    POSTDISPLAY=""
    _SAGE_PREV_COMMAND=""
    _SAGE_CURRENT_SUGGESTION=""
    _SAGE_CURRENT_FREQ_CONTRIB=0
    _SAGE_CURRENT_REC_CONTRIB=0
    _SAGE_CURRENT_DIR_CONTRIB=0
    _SAGE_CURRENT_SEQ_CONTRIB=0
    _SAGE_CURRENT_SUCC_CONTRIB=0
}

typeset -g ZSH_SAGE_FS_SUGGEST="true"
reset_state
BUFFER="cat src/RE"
_sage_update_suggestion
assert_eq "Fallback fills ghost text when DB is empty" "PL.zsh" "$POSTDISPLAY"
assert_eq "Fallback sets current suggestion" "cat src/REPL.zsh" "$_SAGE_CURRENT_SUGGESTION"
assert_eq "Fallback contribs are zero (no weight learning)" "0" \
    "$(( _SAGE_CURRENT_FREQ_CONTRIB + _SAGE_CURRENT_REC_CONTRIB + _SAGE_CURRENT_DIR_CONTRIB + _SAGE_CURRENT_SEQ_CONTRIB + _SAGE_CURRENT_SUCC_CONTRIB ))"

typeset -g ZSH_SAGE_FS_SUGGEST="false"
reset_state
BUFFER="cat src/RE"
_sage_update_suggestion
assert_eq "Toggle off: no ghost text" "" "$POSTDISPLAY"
assert_eq "Toggle off: no suggestion state" "" "$_SAGE_CURRENT_SUGGESTION"

# DB result must always win over the fallback
typeset -g ZSH_SAGE_FS_SUGGEST="true"
_sage_rank_with_score() { printf '0.8%scat src/REPL.zsh was from history%s0.3%s0.3%s0.1%s0%s0.1' \
    "$_SAGE_SEP" "$_SAGE_SEP" "$_SAGE_SEP" "$_SAGE_SEP" "$_SAGE_SEP" "$_SAGE_SEP"; }
reset_state
BUFFER="cat src/RE"
_sage_update_suggestion
assert_eq "History result wins over filesystem fallback" \
    "cat src/REPL.zsh was from history" "$_SAGE_CURRENT_SUGGESTION"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==========================================="

(( FAIL > 0 )) && exit 1
exit 0
