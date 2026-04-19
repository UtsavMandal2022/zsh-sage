#
# hm — AI-powered command assistance via Claude Code
#
# Usage:
#   hm <question>   Ask AI for a command (e.g. "hm find files larger than 1GB")
#   hm              Analyze the previous failed command and suggest a fix
#
# Requires: Claude Code CLI installed (claude)
#
# Uses --no-session-persistence so hm calls don't clutter
# your Claude session history.
#

hm() {
    if [[ "$ZSH_SAGE_AI_ENABLED" != "true" ]]; then
        echo ""
        echo "  hm is not enabled. Run zsage ai to set it up."
        echo ""
        return 1
    fi

    if ! command -v claude &>/dev/null; then
        echo ""
        echo "  hm needs Claude Code. Install it:"
        echo ""
        echo "    npm install -g @anthropic-ai/claude-code"
        echo ""
        return 1
    fi

    if [[ $# -gt 0 ]]; then
        _sage_helpme_ask "$*"
    else
        _sage_helpme_fix
    fi
}

# Alias for discoverability
alias helpme=hm

# ── Question mode ────────────────────────────────────────────────

_sage_helpme_ask() {
    local question="$1"
    local context
    context=$(_sage_helpme_context)

    local prompt="You are a shell command expert. Given the context below, suggest the best shell command to accomplish the user's goal. Return ONLY the command — no explanation, no markdown, no quotes around it.

${context}

User's question: ${question}

Command:"

    local result
    result=$(_sage_helpme_call "$prompt")

    if [[ -z "$result" ]]; then
        echo "  Could not get a suggestion."
        return 1
    fi

    _sage_helpme_display "$result"
}

# ── Fix mode ─────────────────────────────────────────────────────

_sage_helpme_fix() {
    # Get last command and exit code from DB
    local last_row
    last_row=$(_sage_db_query "SELECT command, exit_code FROM commands ORDER BY id DESC LIMIT 1;")

    if [[ -z "$last_row" ]]; then
        echo "  No command history yet — nothing to fix."
        echo "  Try: hm <question>"
        return 1
    fi

    local last_cmd="${last_row%%|*}"
    local last_exit="${last_row##*|}"

    if [[ "$last_exit" == "0" ]]; then
        echo "  Last command succeeded — nothing to fix."
        echo "  Try: hm <question>"
        return 0
    fi

    local context
    context=$(_sage_helpme_context)

    local prompt="You are a shell command expert. The user's last command failed. Analyze the error and suggest the corrected command. Return ONLY the corrected command — no explanation, no markdown, no quotes around it.

${context}

Failed command: ${last_cmd}
Exit code: ${last_exit}

Corrected command:"

    local result
    result=$(_sage_helpme_call "$prompt")

    if [[ -z "$result" ]]; then
        echo "  Could not get a suggestion."
        return 1
    fi

    echo ""
    echo "  Failed: ${last_cmd}"
    echo "  Exit code: ${last_exit}"
    _sage_helpme_display "$result"
}

# ── Context gathering ────────────────────────────────────────────

_sage_helpme_context() {
    local dir="$PWD"
    local git_branch=""
    local os_info
    os_info=$(uname -s)

    if command git rev-parse --is-inside-work-tree &>/dev/null; then
        git_branch=$(command git symbolic-ref --short HEAD 2>/dev/null)
    fi

    local recent_cmds=""
    recent_cmds=$(_sage_db_query "SELECT command FROM commands ORDER BY id DESC LIMIT 10;")

    cat <<EOF
Working directory: ${dir}
OS: ${os_info}
Shell: zsh ${ZSH_VERSION}
Git branch: ${git_branch:-none}
Recent commands:
${recent_cmds}
EOF
}

# ── Claude Code call (synchronous, with spinner) ─────────────────

_sage_helpme_call() {
    local prompt="$1"

    # Show spinner on stderr
    _sage_helpme_spinner &
    local spinner_pid=$!

    local raw
    raw=$(claude -p "$prompt" --max-turns 1 --no-session-persistence 2>/dev/null)
    local exit_code=$?

    # Stop spinner
    kill "$spinner_pid" 2>/dev/null
    wait "$spinner_pid" 2>/dev/null
    printf '\r                    \r' >&2

    if (( exit_code != 0 || ${#raw} == 0 )); then
        echo "  Claude Code returned an error." >&2
        return 1
    fi

    # Strip markdown formatting
    raw=$(_sage_helpme_strip "$raw")

    printf '%s' "$raw"
}

# ── Strip markdown formatting ────────────────────────────────────

_sage_helpme_strip() {
    printf '%s' "$1" | python3 -c "
import sys
text = sys.stdin.read().strip()
if text.startswith('\`\`\`') and text.endswith('\`\`\`'):
    text = text[3:-3].strip()
    if '\n' in text:
        first_line = text.split('\n')[0]
        if first_line in ('bash', 'sh', 'zsh', 'shell', 'fish'):
            text = '\n'.join(text.split('\n')[1:]).strip()
if text.startswith('\`') and text.endswith('\`') and text.count('\`') == 2:
    text = text[1:-1]
if (text.startswith('\"') and text.endswith('\"')) or (text.startswith(\"'\") and text.endswith(\"'\")):
    text = text[1:-1]
print(text)
" 2>/dev/null
}

# ── Spinner ──────────────────────────────────────────────────────

_sage_helpme_spinner() {
    local frames=('.' '..' '...')
    local i=0
    while true; do
        printf '\r  thinking%s   ' "${frames[$((i % 3 + 1))]}" >&2
        sleep 0.3
        i=$((i + 1))
    done
}

# ── Display box + action prompt ──────────────────────────────────

_sage_helpme_display() {
    local cmd="$1"

    # Colors
    local g="" r="" c="" d="" b=""
    if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
        g=$'\033[32m'
        r=$'\033[0m'
        c=$'\033[36m'
        d=$'\033[2m'
        b=$'\033[1m'
    fi

    # Build the box
    local cmd_len=${#cmd}
    local pad_len=$((cmd_len + 4))
    (( pad_len < 40 )) && pad_len=40
    local border=$(printf '%*s' "$pad_len" '' | tr ' ' '─')

    echo ""
    echo "  ${d}┌${border}┐${r}"
    printf "  ${d}│${r}  ${b}${g}%s${r}%*s${d}│${r}\n" "$cmd" "$((pad_len - cmd_len - 2))" ""
    echo "  ${d}└${border}┘${r}"
    echo ""

    # Action prompt
    printf "  ${c}Run it?${r} ${d}[y/N/e(dit)]${r} "
    local reply=""
    read -s -k 1 reply
    echo ""

    case "${reply}" in
        y|Y)
            echo ""
            echo "  ${d}>${r} ${cmd}"
            echo ""
            eval "${cmd}"
            ;;
        e|E)
            print -z "${cmd}"
            echo "  ${d}Command placed on your prompt — edit and press Enter.${r}"
            ;;
        *)
            echo "  ${d}Command not executed.${r}"
            ;;
    esac
}
