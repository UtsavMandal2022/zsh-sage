#
# zsh-sage - Intelligent shell suggestions
# Drop-in replacement for zsh-autosuggestions with multi-signal ranking
#

ZSH_SAGE_DIR="${0:A:h}"

# ── Configuration with defaults ──────────────────────────────────────
typeset -g ZSH_SAGE_DB="${ZSH_SAGE_DB:-$HOME/.zsh-sage/sage.db}"
typeset -g ZSH_SAGE_HIGHLIGHT_STYLE="${ZSH_SAGE_HIGHLIGHT_STYLE:-fg=8}"
typeset -g ZSH_SAGE_ACCEPT_KEY="${ZSH_SAGE_ACCEPT_KEY:-forward-char}"
typeset -g ZSH_SAGE_AI_ENABLED="${ZSH_SAGE_AI_ENABLED:-false}"
typeset -g ZSH_SAGE_MAX_CANDIDATES="${ZSH_SAGE_MAX_CANDIDATES:-10}"

# Number of suggestions to cycle through with Ctrl+Space
typeset -g ZSH_SAGE_CYCLE_COUNT="${ZSH_SAGE_CYCLE_COUNT:-8}"

# Recency half-life in seconds — how fast old commands fade
# Default: 3 days (command from 3 days ago scores 0.5, from 1 week ago ~0.2)
typeset -g ZSH_SAGE_RECENCY_HALFLIFE="${ZSH_SAGE_RECENCY_HALFLIFE:-259200}"

# Prefix-length-aware weights — shift rankings based on how much you've typed
# Short prefixes lean toward frequency, long prefixes lean toward recency.
# Set to "false" on slow hardware to save ~3ms per keystroke.
typeset -g ZSH_SAGE_PREFIX_AWARE_WEIGHTS="${ZSH_SAGE_PREFIX_AWARE_WEIGHTS:-true}"

# Learn from your habits
# When you accept a suggestion, zsh-sage remembers which signals helped
# so it can personalize rankings over time. Local only, nothing leaves your machine.
typeset -g ZSH_SAGE_COLLECT_ACCEPTS="${ZSH_SAGE_COLLECT_ACCEPTS:-true}"
typeset -g ZSH_SAGE_ADAPTIVE_WEIGHTS="${ZSH_SAGE_ADAPTIVE_WEIGHTS:-false}"

# ── Profile presets ──────────────────────────────────────────────────
# Users set: export ZSH_SAGE_PROFILE="contextual" in .zshrc
# Or override individual weights with ZSH_SAGE_W_* for fine-tuning.
typeset -g ZSH_SAGE_PROFILE="${ZSH_SAGE_PROFILE:-default}"

_sage_apply_profile() {
    case "$ZSH_SAGE_PROFILE" in
        contextual)
            # Context-heavy: directory + sequence matter most
            # Best for devs working across many projects
            typeset -g _SAGE_P_FREQ=0.15 _SAGE_P_RECENCY=0.20 \
                       _SAGE_P_DIR=0.30  _SAGE_P_SEQ=0.25     _SAGE_P_SUCCESS=0.10
            ;;
        recent)
            # Recency-heavy: recent commands dominate
            # Best for rapidly changing workflows
            typeset -g _SAGE_P_FREQ=0.15 _SAGE_P_RECENCY=0.40 \
                       _SAGE_P_DIR=0.15  _SAGE_P_SEQ=0.20     _SAGE_P_SUCCESS=0.10
            ;;
        *)
            # default: balanced, frequency-driven
            # Safe choice for everyone
            typeset -g _SAGE_P_FREQ=0.30 _SAGE_P_RECENCY=0.25 \
                       _SAGE_P_DIR=0.20  _SAGE_P_SEQ=0.15     _SAGE_P_SUCCESS=0.10
            ;;
    esac

    # User overrides (ZSH_SAGE_W_*) take precedence over profile
    typeset -g ZSH_SAGE_W_FREQUENCY="${ZSH_SAGE_W_FREQUENCY:-$_SAGE_P_FREQ}"
    typeset -g ZSH_SAGE_W_RECENCY="${ZSH_SAGE_W_RECENCY:-$_SAGE_P_RECENCY}"
    typeset -g ZSH_SAGE_W_DIRECTORY="${ZSH_SAGE_W_DIRECTORY:-$_SAGE_P_DIR}"
    typeset -g ZSH_SAGE_W_SEQUENCE="${ZSH_SAGE_W_SEQUENCE:-$_SAGE_P_SEQ}"
    typeset -g ZSH_SAGE_W_SUCCESS="${ZSH_SAGE_W_SUCCESS:-$_SAGE_P_SUCCESS}"
}

_sage_apply_profile

# ── Source core modules ──────────────────────────────────────────────
source "$ZSH_SAGE_DIR/src/core/db.zsh"
source "$ZSH_SAGE_DIR/src/core/collector.zsh"
source "$ZSH_SAGE_DIR/src/core/scorer.zsh"
source "$ZSH_SAGE_DIR/src/core/widget.zsh"
source "$ZSH_SAGE_DIR/src/strategies/local.zsh"
source "$ZSH_SAGE_DIR/src/core/cli.zsh"

# hm command — always loaded, gated at runtime via ZSH_SAGE_AI_ENABLED
source "$ZSH_SAGE_DIR/src/ai/helpme.zsh"

# ── Initialize ───────────────────────────────────────────────────────
_sage_init() {
    # Ensure data directory exists
    mkdir -p "${ZSH_SAGE_DB:h}"

    # Initialize SQLite database
    _sage_db_init

    # Register hooks
    autoload -Uz add-zsh-hook
    add-zsh-hook preexec _sage_collector_preexec
    add-zsh-hook precmd _sage_collector_precmd

    # Bind widgets
    _sage_widget_init

    # Clean shutdown when shell exits
    add-zsh-hook zshexit _sage_shutdown
}

_sage_init
