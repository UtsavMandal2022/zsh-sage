#
# AI suggestion layer — async Anthropic API integration
#
# Only called when local strategy has no good match.
# Runs in background to avoid blocking the shell.
#

typeset -g _SAGE_AI_LAST_REQUEST=""
typeset -g _SAGE_AI_DEBOUNCE_TIMER=""

# Trigger an async AI suggestion
_sage_ai_suggest_async() {
    local prefix="$1"

    # Don't fire for very short prefixes
    (( ${#prefix} < 3 )) && return

    # Don't re-request the same prefix
    [[ "$prefix" == "$_SAGE_AI_LAST_REQUEST" ]] && return
    _SAGE_AI_LAST_REQUEST="$prefix"

    # Kill previous pending request
    if (( _SAGE_AI_PID > 0 )); then
        kill "$_SAGE_AI_PID" 2>/dev/null
        _SAGE_AI_PID=0
    fi

    # Build context
    local dir="$PWD"
    local git_branch=""
    if command git rev-parse --is-inside-work-tree &>/dev/null; then
        git_branch=$(command git symbolic-ref --short HEAD 2>/dev/null)
    fi

    local recent_cmds=""
    recent_cmds=$(sqlite3 "$ZSH_SAGE_DB" \
        "SELECT command FROM commands ORDER BY id DESC LIMIT 5;" 2>/dev/null)

    # Fire async request
    {
        _sage_ai_call "$prefix" "$dir" "$git_branch" "$recent_cmds"
    } &!
    _SAGE_AI_PID=$!
}

# Make the actual API call (runs in background)
_sage_ai_call() {
    local prefix="$1"
    local dir="$2"
    local git_branch="$3"
    local recent_cmds="$4"

    local prompt="You are a shell command completion engine. Given the context below, suggest the single most likely complete command the user is typing. Return ONLY the complete command, nothing else — no explanation, no quotes, no markdown.

Current input: ${prefix}
Working directory: ${dir}
Git branch: ${git_branch}
Recent commands:
${recent_cmds}

Complete command:"

    # Use shared provider abstraction
    local suggestion
    suggestion=$(_sage_api_call "$prompt" 100 2>/dev/null)

    # Ensure suggestion starts with the prefix
    if [[ -n "$suggestion" && "$suggestion" == "$prefix"* ]]; then
        echo "$suggestion" > "$_SAGE_AI_TMPFILE"
    fi
}
