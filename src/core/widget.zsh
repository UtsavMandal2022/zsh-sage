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

# Cached per-signal contributions for the currently shown suggestion
# Used by the collector to record accepts with their signal breakdown
typeset -g _SAGE_CURRENT_FREQ_CONTRIB=0
typeset -g _SAGE_CURRENT_REC_CONTRIB=0
typeset -g _SAGE_CURRENT_DIR_CONTRIB=0
typeset -g _SAGE_CURRENT_SEQ_CONTRIB=0
typeset -g _SAGE_CURRENT_SUCC_CONTRIB=0

# Cycle state — populated on first Ctrl+Space, rotated on subsequent presses
typeset -ga _SAGE_CYCLE_RESULTS=()     # array of "score|command" lines
typeset -g  _SAGE_CYCLE_INDEX=0        # current position in the cycle
typeset -g  _SAGE_CYCLE_PREFIX=""       # the prefix these results are for

# Confidence color thresholds (256-color)
typeset -g ZSH_SAGE_COLOR_HIGH="${ZSH_SAGE_COLOR_HIGH:-108}"    # sage green
typeset -g ZSH_SAGE_COLOR_MED="${ZSH_SAGE_COLOR_MED:-245}"      # medium grey
typeset -g ZSH_SAGE_COLOR_LOW="${ZSH_SAGE_COLOR_LOW:-240}"      # faint grey
typeset -g ZSH_SAGE_CONFIDENCE_HIGH="${ZSH_SAGE_CONFIDENCE_HIGH:-0.45}"
typeset -g ZSH_SAGE_CONFIDENCE_LOW="${ZSH_SAGE_CONFIDENCE_LOW:-0.20}"

# Map a score (0-1) to a highlight style string
_sage_confidence_style() {
    local score="$1"

    # Integer math: score * 100 to avoid bc
    # Pad decimals to 2 digits: "0.7" → "70", "0.27" → "27", "0.511" → "51"
    local score_int=${${score%%.*}:-0}
    local score_dec="${score#*.}00"
    score_dec="${score_dec:0:2}"
    local score_100=$(( ${score_int:-0} * 100 + ${score_dec} ))

    local high_dec="${ZSH_SAGE_CONFIDENCE_HIGH#*.}00"
    local high_100=$(( ${ZSH_SAGE_CONFIDENCE_HIGH%%.*} * 100 + ${high_dec:0:2} ))
    local low_dec="${ZSH_SAGE_CONFIDENCE_LOW#*.}00"
    local low_100=$(( ${ZSH_SAGE_CONFIDENCE_LOW%%.*} * 100 + ${low_dec:0:2} ))

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
    _SAGE_CYCLE_RESULTS=()
    _SAGE_CYCLE_INDEX=0
    _SAGE_CYCLE_PREFIX=""
}

# ── Highlight management ─────────────────────────────────────────
# Remove previous sage highlight without touching other highlights
_sage_highlight_reset() {
    if [[ -n "${_SAGE_LAST_HIGHLIGHT:-}" ]]; then
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
    _sage_invoke_wrapped_widget self-insert

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
}

# ── Accept full suggestion (right arrow) ─────────────────────────
_sage_accept_widget() {
    emulate -L zsh

    if [[ -n "$_SAGE_CURRENT_SUGGESTION" ]]; then
        # Record accept asynchronously with cached signal contributions
        # Skip recording if contributions are all zero (e.g. from a cycled suggestion)
        if [[ "$ZSH_SAGE_COLLECT_ACCEPTS" == "true" ]] \
           && (( _SAGE_CURRENT_FREQ_CONTRIB + _SAGE_CURRENT_REC_CONTRIB + _SAGE_CURRENT_DIR_CONTRIB + _SAGE_CURRENT_SEQ_CONTRIB + _SAGE_CURRENT_SUCC_CONTRIB != 0 )); then
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
        _sage_invoke_wrapped_widget forward-char
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
        _sage_invoke_wrapped_widget forward-word
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

# ── Clear ghost text on Enter before executing ───────────────────
_sage_accept_line_widget() {
    emulate -L zsh
    _sage_highlight_reset
    POSTDISPLAY=""
    _SAGE_CURRENT_SUGGESTION=""
    _sage_invoke_wrapped_widget accept-line
}

# ── Cycle through alternatives (Ctrl+Space) ─────────────────────
_sage_cycle_widget() {
    emulate -L zsh

    local prefix="$BUFFER"
    [[ -z "$prefix" ]] && return

    # If prefix changed since last cycle, or no results cached, fetch fresh
    if [[ "$prefix" != "$_SAGE_CYCLE_PREFIX" || ${#_SAGE_CYCLE_RESULTS} -eq 0 ]]; then
        _SAGE_CYCLE_PREFIX="$prefix"
        _SAGE_CYCLE_INDEX=0

        local raw
        raw=$(_sage_rank_top_n "$prefix" "$PWD" "$_SAGE_PREV_COMMAND" "${ZSH_SAGE_CYCLE_COUNT:-8}")

        _SAGE_CYCLE_RESULTS=()
        if [[ -n "$raw" ]]; then
            local line
            while IFS= read -r line; do
                [[ -n "$line" ]] && _SAGE_CYCLE_RESULTS+=("$line")
            done <<< "$raw"
        fi

        # If only one result (same as the default ghost), nothing to cycle
        if (( ${#_SAGE_CYCLE_RESULTS} <= 1 )); then
            zle -M "No alternatives available"
            return
        fi

        # Start from the second result (first is already shown as ghost text)
        _SAGE_CYCLE_INDEX=2
    else
        # Advance to next result, wrap around
        _SAGE_CYCLE_INDEX=$(( _SAGE_CYCLE_INDEX % ${#_SAGE_CYCLE_RESULTS} + 1 ))
    fi

    # Display the current cycle entry
    local entry="${_SAGE_CYCLE_RESULTS[$_SAGE_CYCLE_INDEX]}"
    local score="${entry%%|*}"
    local suggestion="${entry#*|}"

    if [[ -n "$suggestion" && "$suggestion" == "$prefix"* ]]; then
        _sage_highlight_reset
        _SAGE_CURRENT_SUGGESTION="$suggestion"
        POSTDISPLAY="${suggestion#$prefix}"

        # Zero out contributions — cycled suggestions don't have per-signal breakdown
        # This prevents recording inaccurate data if the user accepts this entry
        _SAGE_CURRENT_FREQ_CONTRIB=0
        _SAGE_CURRENT_REC_CONTRIB=0
        _SAGE_CURRENT_DIR_CONTRIB=0
        _SAGE_CURRENT_SEQ_CONTRIB=0
        _SAGE_CURRENT_SUCC_CONTRIB=0

        local style
        style=$(_sage_confidence_style "$score")
        _sage_highlight_apply "$style"

        # Show position indicator
        zle -M "suggestion ${_SAGE_CYCLE_INDEX}/${#_SAGE_CYCLE_RESULTS}"
    fi

    zle -R
}

# ── Tab completion wrapper ───────────────────────────────────────
# After tab completes a word, the buffer changes but our ghost text
# stays stale. This wrapper clears stale ghost text, runs the real
# completion, then re-suggests.
_sage_complete_widget() {
    _sage_highlight_reset
    POSTDISPLAY=""

    # Call the original expand-or-complete (saved before we override)
    _sage_invoke_wrapped_widget expand-or-complete

    # Re-suggest based on the now-completed buffer
    _sage_update_suggestion
    zle -R
}

# ── Register a function as a wrapper for an existing widget
_sage_register_widget_wrapper() {
    emulate -L zsh
    local wrapper_function="$1"
    local wrapped_widget="$2"
    local wrapped_widget_alias="_sage_orig_$wrapped_widget"
    if (( ! ${+widgets[$wrapped_widget_alias]} )); then
        zle -A "$wrapped_widget" "$wrapped_widget_alias"
    fi
    zle -N "$wrapped_widget" "$wrapper_function"
}

# ── wrapper functions registered using _sage_register_widget_wrapper can
# use this function to invoke the widget they are wrapping
_sage_invoke_wrapped_widget() {
    emulate -L zsh
    setopt local_options no_unset
    local wrapped_widget="$1"
    local wrapped_widget_alias="_sage_orig_$wrapped_widget"
    zle "$wrapped_widget_alias"
}

# ── Register widgets and keybindings ─────────────────────────────
_sage_widget_init() {
    _sage_register_widget_wrapper _sage_accept_widget forward-char
    _sage_register_widget_wrapper _sage_accept_word_widget forward-word
    zle -N sage-dismiss _sage_dismiss_widget
    _sage_register_widget_wrapper _sage_accept_line_widget accept-line
    _sage_register_widget_wrapper _sage_suggest_widget self-insert

    _sage_register_widget_wrapper _sage_complete_widget expand-or-complete

    zle -N sage-cycle _sage_cycle_widget
    bindkey '^N' sage-cycle             # Ctrl+N (next suggestion)

    _sage_register_widget_wrapper _sage_backward_kill_word backward-kill-word
    _sage_register_widget_wrapper _sage_backward_delete_char backward-delete-char
}

# ── Backspace handler ────────────────────────────────────────────
_sage_backward_kill_word() {
    emulate -L zsh
    _sage_highlight_reset
    _sage_invoke_wrapped_widget backward-kill-word
    # skip suggestion if more inputs are pending, e.g. if backspace is held down
    (( PENDING > 0 )) && return
    _sage_update_suggestion
    zle -R
}
_sage_backward_delete_char() {
    emulate -L zsh
    _sage_highlight_reset
    _sage_invoke_wrapped_widget backward-delete-char
    # skip suggestion if more inputs are pending, e.g. if backspace is held down
    (( PENDING > 0 )) && return
    _sage_update_suggestion
    zle -R
}
