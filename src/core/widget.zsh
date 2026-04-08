#
# Widget — ZLE integration for inline suggestions
#
# Ghost text color reflects confidence:
#   High (>0.7):   sage green  — "I'm sure about this"
#   Medium (0.3-0.7): grey     — "decent guess"
#   Low (<0.3):    faint grey  — "this is a stretch"
#
# Uses the same region_highlight approach as zsh-autosuggestions:
# highlight by absolute buffer position, track last highlight for clean removal.
#

typeset -g _SAGE_CURRENT_SUGGESTION=""
typeset -g _SAGE_LAST_HIGHLIGHT=""
typeset -g _SAGE_AI_PID=0
typeset -g _SAGE_AI_TMPFILE="/tmp/zsh-sage-ai-$$"

# Cached per-signal contributions for the currently shown suggestion
# Used by the collector to record accepts with their signal breakdown
typeset -g _SAGE_CURRENT_FREQ_CONTRIB=0
typeset -g _SAGE_CURRENT_REC_CONTRIB=0
typeset -g _SAGE_CURRENT_DIR_CONTRIB=0
typeset -g _SAGE_CURRENT_SEQ_CONTRIB=0
typeset -g _SAGE_CURRENT_SUCC_CONTRIB=0

# Confidence color thresholds (256-color)
typeset -g ZSH_SAGE_COLOR_HIGH="${ZSH_SAGE_COLOR_HIGH:-108}"    # sage green
typeset -g ZSH_SAGE_COLOR_MED="${ZSH_SAGE_COLOR_MED:-245}"      # medium grey
typeset -g ZSH_SAGE_COLOR_LOW="${ZSH_SAGE_COLOR_LOW:-240}"      # faint grey
typeset -g ZSH_SAGE_CONFIDENCE_HIGH="${ZSH_SAGE_CONFIDENCE_HIGH:-0.7}"
typeset -g ZSH_SAGE_CONFIDENCE_LOW="${ZSH_SAGE_CONFIDENCE_LOW:-0.3}"

# Map a score (0-1) to a highlight style string
_sage_confidence_style() {
    local score="$1"

    # Integer math: score * 100 to avoid bc
    local score_int=${${score%%.*}:-0}
    local score_dec="${score#*.}"
    score_dec="${score_dec:0:2}"
    local score_100=$(( ${score_int:-0} * 100 + ${score_dec:-0} ))

    local high_100=$(( ${ZSH_SAGE_CONFIDENCE_HIGH%%.*} * 100 + ${${ZSH_SAGE_CONFIDENCE_HIGH#*.}:0:2} ))
    local low_100=$(( ${ZSH_SAGE_CONFIDENCE_LOW%%.*} * 100 + ${${ZSH_SAGE_CONFIDENCE_LOW#*.}:0:2} ))

    if (( score_100 >= high_100 )); then
        echo "fg=${ZSH_SAGE_COLOR_HIGH}"
    elif (( score_100 >= low_100 )); then
        echo "fg=${ZSH_SAGE_COLOR_MED}"
    else
        echo "fg=${ZSH_SAGE_COLOR_LOW}"
    fi
}

# Clear all suggestion state (used in several widgets)
_sage_clear_state() {
    _SAGE_CURRENT_SUGGESTION=""
    _SAGE_CURRENT_FREQ_CONTRIB=0
    _SAGE_CURRENT_REC_CONTRIB=0
    _SAGE_CURRENT_DIR_CONTRIB=0
    _SAGE_CURRENT_SEQ_CONTRIB=0
    _SAGE_CURRENT_SUCC_CONTRIB=0
}

# ── Highlight management ─────────────────────────────────────────
# Remove previous sage highlight without touching other highlights
_sage_highlight_reset() {
    if [[ -n "$_SAGE_LAST_HIGHLIGHT" ]]; then
        region_highlight=("${(@)region_highlight:#$_SAGE_LAST_HIGHLIGHT}")
        unset _SAGE_LAST_HIGHLIGHT
    fi
}

# Apply highlight to POSTDISPLAY region using absolute buffer positions
_sage_highlight_apply() {
    local style="$1"

    _sage_highlight_reset

    if (( $#POSTDISPLAY )); then
        typeset -g _SAGE_LAST_HIGHLIGHT="$#BUFFER $(($#BUFFER + $#POSTDISPLAY)) $style"
        region_highlight+=("$_SAGE_LAST_HIGHLIGHT")
    fi
}

# ── Main suggestion widget ───────────────────────────────────────
_sage_suggest_widget() {
    emulate -L zsh
    local -i KEYS_QUEUED_COUNT

    _sage_highlight_reset
    zle .self-insert

    # Skip suggestion if more keys are buffered (paste or fast typing)
    if (( PENDING > 0 || KEYS_QUEUED_COUNT > 0 )); then
        return
    fi

    _sage_update_suggestion
    zle -R
}

# ── Update suggestion based on current buffer ────────────────────
_sage_update_suggestion() {
    local prefix="$BUFFER"

    # Clear if buffer is empty
    if [[ -z "$prefix" ]]; then
        _sage_highlight_reset
        POSTDISPLAY=""
        _sage_clear_state
        return
    fi

    # Get best suggestion with score and signal breakdown
    local result
    result=$(_sage_rank_with_score "$prefix" "$PWD" "$_SAGE_PREV_COMMAND")

    if [[ -n "$result" ]]; then
        # Split pipe-delimited result:
        # score|command|freq_contrib|rec_contrib|dir_contrib|seq_contrib|succ_contrib
        # (sequence override fast path returns only "score|command" — contribs will be empty)
        local -a fields
        fields=("${(@s:|:)result}")
        local score="${fields[1]}"
        local suggestion="${fields[2]}"

        if [[ -n "$suggestion" && "$suggestion" != "$prefix" && "$suggestion" == "$prefix"* ]]; then
            _SAGE_CURRENT_SUGGESTION="$suggestion"
            # Cache signal contributions (default to 0 for fast-path results)
            _SAGE_CURRENT_FREQ_CONTRIB="${fields[3]:-0}"
            _SAGE_CURRENT_REC_CONTRIB="${fields[4]:-0}"
            _SAGE_CURRENT_DIR_CONTRIB="${fields[5]:-0}"
            _SAGE_CURRENT_SEQ_CONTRIB="${fields[6]:-0}"
            _SAGE_CURRENT_SUCC_CONTRIB="${fields[7]:-0}"

            POSTDISPLAY="${suggestion#$prefix}"

            local style
            style=$(_sage_confidence_style "$score")
            _sage_highlight_apply "$style"
            return
        fi
    fi

    # No match — clear
    _sage_highlight_reset
    POSTDISPLAY=""
    _sage_clear_state

    # AI fallback
    if [[ "$ZSH_SAGE_AI_ENABLED" == "true" && -n "$ZSH_SAGE_API_KEY" ]]; then
        _sage_ai_suggest_async "$prefix"
    fi
}

# ── Accept full suggestion (right arrow) ─────────────────────────
_sage_accept_widget() {
    emulate -L zsh

    if [[ -n "$_SAGE_CURRENT_SUGGESTION" ]]; then
        # Record accept asynchronously with cached signal contributions
        if [[ "$ZSH_SAGE_COLLECT_ACCEPTS" == "true" ]]; then
            {
                _sage_db_record_accept \
                    "$_SAGE_CURRENT_FREQ_CONTRIB" \
                    "$_SAGE_CURRENT_REC_CONTRIB" \
                    "$_SAGE_CURRENT_DIR_CONTRIB" \
                    "$_SAGE_CURRENT_SEQ_CONTRIB" \
                    "$_SAGE_CURRENT_SUCC_CONTRIB"
            } &!
        fi

        _sage_highlight_reset
        BUFFER="$_SAGE_CURRENT_SUGGESTION"
        CURSOR=${#BUFFER}
        POSTDISPLAY=""
        _sage_clear_state
        zle -R
    else
        zle .forward-char
    fi
}

# ── Accept word-by-word (Ctrl+Right) ─────────────────────────────
_sage_accept_word_widget() {
    emulate -L zsh

    if [[ -n "$POSTDISPLAY" ]]; then
        _sage_highlight_reset
        local next_word="${POSTDISPLAY%% *}"

        if [[ "$next_word" == "$POSTDISPLAY" ]]; then
            # Last word — accept all
            BUFFER="$_SAGE_CURRENT_SUGGESTION"
            CURSOR=${#BUFFER}
            POSTDISPLAY=""
            _SAGE_CURRENT_SUGGESTION=""
        else
            BUFFER="${BUFFER}${next_word} "
            CURSOR=${#BUFFER}
            _sage_update_suggestion
        fi
        zle -R
    else
        zle .forward-word
    fi
}

# ── Dismiss suggestion ───────────────────────────────────────────
_sage_dismiss_widget() {
    emulate -L zsh
    _sage_highlight_reset
    POSTDISPLAY=""
    _SAGE_CURRENT_SUGGESTION=""
    zle -R
}

# ── Async AI result check ────────────────────────────────────────
_sage_check_ai_result() {
    if [[ -f "$_SAGE_AI_TMPFILE" ]]; then
        local ai_suggestion
        ai_suggestion=$(<"$_SAGE_AI_TMPFILE")
        rm -f "$_SAGE_AI_TMPFILE"

        if [[ -n "$ai_suggestion" && "$ai_suggestion" == "$BUFFER"* && -z "$POSTDISPLAY" ]]; then
            _SAGE_CURRENT_SUGGESTION="$ai_suggestion"
            POSTDISPLAY="${ai_suggestion#$BUFFER}"
            _sage_highlight_apply "fg=${ZSH_SAGE_COLOR_MED}"
            zle -R
        fi
    fi
}

# ── Clear ghost text on Enter before executing ───────────────────
_sage_accept_line_widget() {
    emulate -L zsh
    _sage_highlight_reset
    POSTDISPLAY=""
    _SAGE_CURRENT_SUGGESTION=""
    zle .accept-line
}

# ── Register widgets and keybindings ─────────────────────────────
_sage_widget_init() {
    zle -N sage-suggest _sage_suggest_widget
    zle -N sage-accept _sage_accept_widget
    zle -N sage-accept-word _sage_accept_word_widget
    zle -N sage-dismiss _sage_dismiss_widget
    zle -N sage-accept-line _sage_accept_line_widget
    zle -N self-insert _sage_suggest_widget

    bindkey '^[[C' sage-accept          # Right arrow
    bindkey '^[OC' sage-accept          # Right arrow (alternate)
    bindkey '^[[1;5C' sage-accept-word  # Ctrl+Right
    bindkey '^M' sage-accept-line       # Enter

    zle -N sage-backspace _sage_backspace_widget
    bindkey '^?' sage-backspace         # Backspace
    bindkey '^H' sage-backspace         # Ctrl+H
}

# ── Backspace handler ────────────────────────────────────────────
_sage_backspace_widget() {
    emulate -L zsh
    _sage_highlight_reset
    zle .backward-delete-char
    _sage_update_suggestion
    zle -R
}
