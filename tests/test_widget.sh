#!/usr/bin/env zsh
#
# Widget tests — pre-redraw invariant logic
#
# The pre-redraw hook (added in PR #12 for issue #6) clears stale ghost text
# when any widget mutates BUFFER without going through our wrappers (history
# navigation, vi edits, undo, kill-ring yanks, …). The hook enforces:
#   _SAGE_CURRENT_SUGGESTION == BUFFER + POSTDISPLAY  AND
#   _SAGE_CURRENT_SUGGESTION starts with BUFFER
# When either breaks, the ghost is stale — clear it so right-arrow can't
# accept something inconsistent with what's on screen.
#
# These tests drive _sage_pre_redraw_widget directly with mocked ZLE state.
#

set -uo pipefail

SCRIPT_DIR="$(dirname $0)"
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

# region_highlight is a ZLE-only array; declare it so _sage_highlight_reset's
# parameter expansion doesn't error when widget.zsh is sourced outside ZLE.
typeset -ga region_highlight=()

source "$SCRIPT_DIR/../src/core/widget.zsh"

# Override the highlight stub AFTER sourcing — the real one calls
# region_highlight=("${(@)region_highlight:#$_SAGE_LAST_HIGHLIGHT}") which
# works fine on an empty array but pulls in ZLE assumptions we don't need here.
_sage_highlight_reset() { :; }

# Reset all globals the pre-redraw hook touches, to a known baseline.
reset_state() {
    BUFFER=""
    POSTDISPLAY=""
    _SAGE_CURRENT_SUGGESTION=""
    _SAGE_CURRENT_FREQ_CONTRIB=0
    _SAGE_CURRENT_REC_CONTRIB=0
    _SAGE_CURRENT_DIR_CONTRIB=0
    _SAGE_CURRENT_SEQ_CONTRIB=0
    _SAGE_CURRENT_SUCC_CONTRIB=0
    _SAGE_CYCLE_RESULTS=()
    _SAGE_CYCLE_INDEX=0
    _SAGE_CYCLE_PREFIX=""
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Pre-redraw invariant tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Case 1: POSTDISPLAY empty — early return, nothing to do ──
reset_state
BUFFER="git"
POSTDISPLAY=""
_SAGE_CURRENT_SUGGESTION="git status"
_sage_pre_redraw_widget
assert_eq "empty POSTDISPLAY: cache preserved (early-return path)" \
    "git status" "$_SAGE_CURRENT_SUGGESTION"

# ── Case 2: invariant holds — typical typing state, nothing changes ──
reset_state
BUFFER="git"
POSTDISPLAY=" status"
_SAGE_CURRENT_SUGGESTION="git status"
_sage_pre_redraw_widget
assert_eq "invariant holds: POSTDISPLAY preserved" " status"    "$POSTDISPLAY"
assert_eq "invariant holds: cache preserved"      "git status" "$_SAGE_CURRENT_SUGGESTION"

# ── Case 3: history navigation (issue #6) ──
# User typed 'git', ghost was ' status', then pressed up — history widget
# replaced BUFFER with a prior command. POSTDISPLAY/cache are now stale.
reset_state
BUFFER="ls -la"
POSTDISPLAY=" status"
_SAGE_CURRENT_SUGGESTION="git status"
_sage_pre_redraw_widget
assert_eq "history-nav: POSTDISPLAY cleared" "" "$POSTDISPLAY"
assert_eq "history-nav: cache cleared"       "" "$_SAGE_CURRENT_SUGGESTION"

# ── Case 4: prefix-search history (up-line-or-beginning-search) ──
# Buffer mutated to a different command that happens to share first char.
reset_state
BUFFER="grep foo"
POSTDISPLAY="it status"
_SAGE_CURRENT_SUGGESTION="git status"
_sage_pre_redraw_widget
assert_eq "prefix-search nav: POSTDISPLAY cleared" "" "$POSTDISPLAY"
assert_eq "prefix-search nav: cache cleared"       "" "$_SAGE_CURRENT_SUGGESTION"

# ── Case 5: buffer extended without going through self-insert wrapper ──
# e.g. yank, vi-mode insert, undo. BUFFER+POSTDISPLAY no longer equals suggestion.
reset_state
BUFFER="git x"
POSTDISPLAY=" status"
_SAGE_CURRENT_SUGGESTION="git status"
_sage_pre_redraw_widget
assert_eq "buffer extended out-of-band: POSTDISPLAY cleared" "" "$POSTDISPLAY"
assert_eq "buffer extended out-of-band: cache cleared"       "" "$_SAGE_CURRENT_SUGGESTION"

# ── Case 6: tab-completion completed BUFFER mid-word ──
# Old _sage_complete_widget cleared POSTDISPLAY before completion;
# new mechanism relies on pre-redraw firing during the completion's own redraw.
reset_state
BUFFER="cd Desktop/zsh-sage"
POSTDISPLAY="ge"   # was ' ' from cached 'cd Desktop' — now invalid
_SAGE_CURRENT_SUGGESTION="cd Desktop "
_sage_pre_redraw_widget
assert_eq "tab completion: POSTDISPLAY cleared" "" "$POSTDISPLAY"
assert_eq "tab completion: cache cleared"       "" "$_SAGE_CURRENT_SUGGESTION"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Side-effect: signal contributions also reset"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Case 7: cache clearing wipes per-signal contribs (accept-tracking state) ──
# Otherwise a later accept would record contributions for a suggestion the
# user never actually saw.
reset_state
BUFFER="ls"
POSTDISPLAY=" status"
_SAGE_CURRENT_SUGGESTION="git status"
_SAGE_CURRENT_FREQ_CONTRIB="0.3"
_SAGE_CURRENT_REC_CONTRIB="0.2"
_SAGE_CURRENT_DIR_CONTRIB="0.15"
_SAGE_CURRENT_SEQ_CONTRIB="0.1"
_SAGE_CURRENT_SUCC_CONTRIB="0.05"
_sage_pre_redraw_widget
assert_eq "freq contrib zeroed on clear"    "0" "$_SAGE_CURRENT_FREQ_CONTRIB"
assert_eq "recency contrib zeroed on clear" "0" "$_SAGE_CURRENT_REC_CONTRIB"
assert_eq "dir contrib zeroed on clear"     "0" "$_SAGE_CURRENT_DIR_CONTRIB"
assert_eq "seq contrib zeroed on clear"     "0" "$_SAGE_CURRENT_SEQ_CONTRIB"
assert_eq "success contrib zeroed on clear" "0" "$_SAGE_CURRENT_SUCC_CONTRIB"

# ── Case 8: cycle state cleared too ──
reset_state
BUFFER="ls"
POSTDISPLAY=" status"
_SAGE_CURRENT_SUGGESTION="git status"
_SAGE_CYCLE_RESULTS=("0.9|git status" "0.7|git push")
_SAGE_CYCLE_INDEX=2
_SAGE_CYCLE_PREFIX="git"
_sage_pre_redraw_widget
assert_eq "cycle results emptied"    "0"  "${#_SAGE_CYCLE_RESULTS}"
assert_eq "cycle index reset"        "0"  "$_SAGE_CYCLE_INDEX"
assert_eq "cycle prefix cleared"     ""   "$_SAGE_CYCLE_PREFIX"

echo ""
echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==========================================="

[[ $FAIL -eq 0 ]]
