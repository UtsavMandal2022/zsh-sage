#!/usr/bin/env zsh
#
# Tests for hm (helpme) — AI command assistance
#
# Tests cover: gating, context gathering, fix mode logic, display formatting,
# and markdown stripping. Claude API calls are mocked to avoid real API usage.
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

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected NOT to contain: '$needle'"
        echo "    actual: '$haystack'"
        FAIL=$((FAIL + 1))
    fi
}

assert_exit() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected exit code: $expected"
        echo "    actual exit code:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

setup_db() {
    TEST_DB="/tmp/sage-helpme-test-$$.db"
    rm -f "$TEST_DB"
    export ZSH_SAGE_DB="$TEST_DB"
    source "$SCRIPT_DIR/../src/core/db.zsh"
    _sage_db_init
}

cleanup() {
    _sage_coproc_stop 2>/dev/null
    rm -f "$TEST_DB"
}

# ═════════════════════════════════════════════════════════════════
# GATE TESTS — hm should be gated properly
# ═════════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Gate tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

setup_db
source "$SCRIPT_DIR/../src/ai/helpme.zsh"

# Test 1: hm fails when AI is disabled
export ZSH_SAGE_AI_ENABLED=false
output=$(hm "test" 2>&1)
assert_exit "hm returns 1 when AI disabled" "1" "$?"
assert_contains "hm shows setup message when disabled" "zsage ai" "$output"

# Test 2: hm fails when AI is empty string
export ZSH_SAGE_AI_ENABLED=""
output=$(hm "test" 2>&1)
assert_exit "hm returns 1 when AI empty" "1" "$?"

# Test 3: hm fails in auto mode when neither provider is found
export ZSH_SAGE_AI_ENABLED=true
# Mock both providers away by overriding PATH
output=$(PATH="/nonexistent" hm "test" 2>&1)
assert_exit "hm returns 1 when no provider found" "1" "$?"
assert_contains "hm shows setup message" "Claude Code or Ollama" "$output"

# Test 4: explicit claude mode fails with install hint when claude not found
export ZSH_SAGE_AI_ENABLED=claude
output=$(PATH="/nonexistent" hm "test" 2>&1)
assert_exit "hm returns 1 when claude not found" "1" "$?"
assert_contains "hm shows install message" "npm install" "$output"

# Test 5: explicit ollama mode fails with install hint when ollama not found
export ZSH_SAGE_AI_ENABLED=ollama
output=$(PATH="/nonexistent" hm "test" 2>&1)
assert_exit "hm returns 1 when ollama not found" "1" "$?"
assert_contains "hm shows ollama install hint" "ollama.com" "$output"

cleanup

# ═════════════════════════════════════════════════════════════════
# PROVIDER DETECTION TESTS — auto-detect + ollama model selection
# ═════════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Provider detection tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

source "$SCRIPT_DIR/../src/ai/helpme.zsh"
unset ZSH_SAGE_OLLAMA_MODEL

# Mock dirs: one with only claude, one with only ollama
DETECT_DIR="/tmp/sage-detect-$$"
mkdir -p "$DETECT_DIR/claude-only" "$DETECT_DIR/ollama-only"

cat > "$DETECT_DIR/claude-only/claude" << 'MOCK'
#!/bin/sh
echo "mock claude"
MOCK
chmod +x "$DETECT_DIR/claude-only/claude"

cat > "$DETECT_DIR/ollama-only/ollama" << 'MOCK'
#!/bin/sh
case "$1" in
    ps)   printf 'NAME    ID    SIZE    PROCESSOR    UNTIL\n' ;;
    list) printf 'NAME    ID    SIZE    MODIFIED\nllama3:8b    abc123    4.7 GB    2 days ago\n' ;;
esac
MOCK
chmod +x "$DETECT_DIR/ollama-only/ollama"

# Replace ask/fix so hm only reports what the gate resolved
_sage_helpme_ask() { echo "PROVIDER:${_SAGE_AI_PROVIDER} MODEL:${ZSH_SAGE_OLLAMA_MODEL:-${_SAGE_OLLAMA_MODEL:-}}"; }
_sage_helpme_fix() { _sage_helpme_ask; }

# Auto mode: only claude installed
export ZSH_SAGE_AI_ENABLED=true
output=$(PATH="$DETECT_DIR/claude-only" hm "test" 2>&1)
assert_contains "auto picks claude when only claude installed" "PROVIDER:claude" "$output"

# Auto mode: both installed — claude preferred
output=$(PATH="$DETECT_DIR/claude-only:$DETECT_DIR/ollama-only" hm "test" 2>&1)
assert_contains "auto prefers claude when both installed" "PROVIDER:claude" "$output"

# Auto mode: only ollama installed — picks ollama and detects model
output=$(PATH="$DETECT_DIR/ollama-only" hm "test" 2>&1)
assert_contains "auto picks ollama when only ollama installed" "PROVIDER:ollama" "$output"
assert_contains "auto-detected ollama gets a model" "MODEL:llama3:8b" "$output"
assert_contains "model detection reports its pick" "recently installed ollama model" "$output"

# Auto mode does not overwrite the user's setting
assert_eq "auto mode leaves ZSH_SAGE_AI_ENABLED untouched" "true" "$ZSH_SAGE_AI_ENABLED"

# Explicit ollama: ZSH_SAGE_OLLAMA_MODEL wins, no detection
export ZSH_SAGE_AI_ENABLED=ollama
output=$(ZSH_SAGE_OLLAMA_MODEL="custom:model" PATH="$DETECT_DIR/ollama-only" hm "test" 2>&1)
assert_contains "explicit model is used verbatim" "MODEL:custom:model" "$output"
assert_not_contains "explicit model skips detection" "ollama model:" "$output"

# Explicit ollama: loaded model (ollama ps) preferred over installed list
cat > "$DETECT_DIR/ollama-only/ollama" << 'MOCK'
#!/bin/sh
case "$1" in
    ps)   printf 'NAME    ID    SIZE    PROCESSOR    UNTIL\nqwen3:4b    def456    2.6 GB    100%% GPU    4 minutes from now\n' ;;
    list) printf 'NAME    ID    SIZE    MODIFIED\nllama3:8b    abc123    4.7 GB    2 days ago\n' ;;
esac
MOCK

output=$(PATH="$DETECT_DIR/ollama-only" hm "test" 2>&1)
assert_contains "loaded model preferred over installed" "MODEL:qwen3:4b" "$output"
assert_contains "loaded model detection reports its pick" "loaded ollama model" "$output"

# Explicit ollama: no models at all — clear error
cat > "$DETECT_DIR/ollama-only/ollama" << 'MOCK'
#!/bin/sh
case "$1" in
    ps)   printf 'NAME    ID    SIZE    PROCESSOR    UNTIL\n' ;;
    list) printf 'NAME    ID    SIZE    MODIFIED\n' ;;
esac
MOCK

output=$(PATH="$DETECT_DIR/ollama-only" hm "test" 2>&1)
assert_exit "hm returns 1 when no ollama models installed" "1" "$?"
assert_contains "hm suggests pulling a model" "ollama pull" "$output"

rm -rf "$DETECT_DIR"

# ═════════════════════════════════════════════════════════════════
# CONTEXT TESTS — _sage_helpme_context gathers shell context
# ═════════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Context tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

setup_db
source "$SCRIPT_DIR/../src/ai/helpme.zsh"

# Seed some commands
_sage_db_exec "INSERT INTO commands (command, directory, exit_code, timestamp)
VALUES ('git status', '$PWD', 0, $(date +%s));"
_sage_db_exec "INSERT INTO commands (command, directory, exit_code, timestamp)
VALUES ('npm test', '$PWD', 1, $(date +%s));"

context=$(_sage_helpme_context)

assert_contains "context includes PWD" "$PWD" "$context"
assert_contains "context includes OS" "$(uname -s)" "$context"
assert_contains "context includes shell version" "$ZSH_VERSION" "$context"
assert_contains "context includes recent commands" "git status" "$context"
assert_contains "context includes recent commands (2)" "npm test" "$context"

cleanup

# ═════════════════════════════════════════════════════════════════
# FIX MODE TESTS — _sage_helpme_fix logic
# ═════════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Fix mode logic tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

setup_db
source "$SCRIPT_DIR/../src/ai/helpme.zsh"
export ZSH_SAGE_AI_ENABLED=true

# Test: no history
output=$(_sage_helpme_fix 2>&1)
assert_exit "fix returns 1 with no history" "1" "$?"
assert_contains "fix says no history" "No command history" "$output"

# Test: last command succeeded
_sage_db_exec "INSERT INTO commands (command, directory, exit_code, timestamp)
VALUES ('ls', '$PWD', 0, $(date +%s));"

output=$(_sage_helpme_fix 2>&1)
assert_exit "fix returns 0 when last command succeeded" "0" "$?"
assert_contains "fix says nothing to fix" "nothing to fix" "$output"

# Test: last command failed — check it tries to call claude
_sage_db_exec "INSERT INTO commands (command, directory, exit_code, timestamp)
VALUES ('git push origin main', '$PWD', 1, $(date +%s));"

# Mock _sage_helpme_call to avoid real API
_sage_helpme_call() { echo "git pull --rebase origin main"; }
_sage_helpme_display() { echo "DISPLAY:$1"; }

output=$(_sage_helpme_fix 2>&1)
assert_contains "fix shows failed command" "git push origin main" "$output"
assert_contains "fix shows exit code" "Exit code: 1" "$output"
assert_contains "fix calls display with suggestion" "DISPLAY:git pull --rebase origin main" "$output"

cleanup

# ═════════════════════════════════════════════════════════════════
# ASK MODE TESTS — _sage_helpme_ask logic
# ═════════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Ask mode logic tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

setup_db
source "$SCRIPT_DIR/../src/ai/helpme.zsh"
export ZSH_SAGE_AI_ENABLED=true

# Mock _sage_helpme_call
_sage_helpme_call() { echo "find / -type f -size +1G"; }
_sage_helpme_display() { echo "DISPLAY:$1"; }

output=$(_sage_helpme_ask "find files larger than 1GB" 2>&1)
assert_contains "ask calls display with result" "DISPLAY:find / -type f -size +1G" "$output"

# Mock empty response
_sage_helpme_call() { echo ""; }
output=$(_sage_helpme_ask "something impossible" 2>&1)
assert_contains "ask shows error on empty result" "Could not get a suggestion" "$output"

# Mock NO_COMMAND response (non-command input)
_sage_helpme_call() { echo "NO_COMMAND"; }
output=$(_sage_helpme_ask "I love you" 2>&1)
assert_contains "ask handles non-command input" "doesn't look like a command" "$output"
assert_exit "ask returns 0 for non-command" "0" "$?"

cleanup

# ═════════════════════════════════════════════════════════════════
# STRIP FORMATTING TESTS — _sage_helpme_strip
# ═════════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Markdown stripping tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

source "$SCRIPT_DIR/../src/ai/helpme.zsh"

# Plain command — no change
result=$(_sage_helpme_strip "ls -la")
assert_eq "plain command unchanged" "ls -la" "$result"

# Triple backticks
result=$(_sage_helpme_strip '```
ls -la
```')
assert_eq "strips triple backticks" "ls -la" "$result"

# Triple backticks with language tag
result=$(_sage_helpme_strip '```bash
find / -size +1G
```')
assert_eq "strips triple backticks with bash tag" "find / -size +1G" "$result"

result=$(_sage_helpme_strip '```zsh
du -sh *
```')
assert_eq "strips triple backticks with zsh tag" "du -sh *" "$result"

# Single backticks
result=$(_sage_helpme_strip '`ls -la`')
assert_eq "strips single backticks" "ls -la" "$result"

# Double quotes
result=$(_sage_helpme_strip '"ls -la"')
assert_eq "strips double quotes" "ls -la" "$result"

# Single quotes
result=$(_sage_helpme_strip "'ls -la'")
assert_eq "strips single quotes" "ls -la" "$result"

# No stripping for normal text with backticks inside
result=$(_sage_helpme_strip 'echo `date`')
assert_eq "preserves internal backticks" 'echo `date`' "$result"

# ═════════════════════════════════════════════════════════════════
# DISPLAY BOX TESTS — _sage_helpme_display formatting
# ═════════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Display box tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

source "$SCRIPT_DIR/../src/ai/helpme.zsh"

# Test box rendering (press 'n' to skip execution)
export NO_COLOR=1  # disable colors for clean assertion
export COLUMNS=80  # pin width — box wrapping depends on terminal size
output=$(echo "n" | _sage_helpme_display "ls -la" 2>&1)
assert_contains "display shows top border" "┌" "$output"
assert_contains "display shows bottom border" "└" "$output"
assert_contains "display shows command" "ls -la" "$output"
assert_contains "display shows action prompt" "Run it?" "$output"

# Test 'n' doesn't execute
assert_contains "pressing n says not executed" "not executed" "$output"
assert_not_contains "pressing n doesn't run command" ">" "$output"

unset NO_COLOR

# ═════════════════════════════════════════════════════════════════
# INTEGRATION TEST — full pipeline with mock
# ═════════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Integration tests (mocked claude)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

setup_db
source "$SCRIPT_DIR/../src/ai/helpme.zsh"
export ZSH_SAGE_AI_ENABLED=true
export NO_COLOR=1
export COLUMNS=80  # pin width — box wrapping depends on terminal size

# Create a mock claude command
MOCK_DIR="/tmp/sage-mock-$$"
mkdir -p "$MOCK_DIR"
cat > "$MOCK_DIR/claude" << 'MOCK'
#!/bin/sh
echo "find / -type f -size +1G 2>/dev/null"
MOCK
chmod +x "$MOCK_DIR/claude"

# Put the mock on PATH so hm's provider gate resolves to claude
# even on machines without the real CLI installed.
SAVED_PATH="$PATH"
export PATH="$MOCK_DIR:$PATH"

# Override _sage_helpme_call to use mock (skip spinner)
_sage_helpme_call() {
    local raw
    raw=$("$MOCK_DIR/claude" 2>/dev/null)
    raw=$(_sage_helpme_strip "$raw")
    printf '%s' "$raw"
}

# Test ask mode end-to-end
output=$(echo "n" | hm "find large files" 2>&1)
assert_contains "e2e ask: shows suggestion in box" "find / -type f -size +1G" "$output"
assert_contains "e2e ask: shows action prompt" "Run it?" "$output"

# Test fix mode end-to-end
_sage_db_exec "INSERT INTO commands (command, directory, exit_code, timestamp)
VALUES ('bad_command', '$PWD', 127, $(date +%s));"

# Mock returns fix
cat > "$MOCK_DIR/claude" << 'MOCK'
#!/bin/sh
echo "good_command"
MOCK

_sage_helpme_call() {
    local raw
    raw=$("$MOCK_DIR/claude" 2>/dev/null)
    raw=$(_sage_helpme_strip "$raw")
    printf '%s' "$raw"
}

output=$(echo "n" | hm 2>&1)
assert_contains "e2e fix: shows failed command" "bad_command" "$output"
assert_contains "e2e fix: shows exit code" "127" "$output"
assert_contains "e2e fix: shows suggestion" "good_command" "$output"

# Cleanup
export PATH="$SAVED_PATH"
rm -rf "$MOCK_DIR"
unset NO_COLOR
cleanup

# ═════════════════════════════════════════════════════════════════
# RESULTS
# ═════════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: $PASS passed, $FAIL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

(( FAIL > 0 )) && exit 1
exit 0
