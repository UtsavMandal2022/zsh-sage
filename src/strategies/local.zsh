#
# Local strategy — trie-like fast lookup backed by SQLite
#
# This is the primary suggestion strategy. It fetches candidates
# from the local database and scores them using multi-signal ranking.
# Called synchronously on every keystroke — must be fast.
#

zmodload zsh/datetime

# In-memory prefix cache to avoid hitting SQLite on every keystroke
typeset -gA _SAGE_PREFIX_CACHE
typeset -g _SAGE_CACHE_TTL=30  # seconds

_sage_strategy_local() {
    local prefix="$1"
    local dir="$2"
    local prev_cmd="$3"

    # Check in-memory cache first
    local cache_key="${dir}:${prev_cmd}:${prefix}"
    local cached="${_SAGE_PREFIX_CACHE[$cache_key]:-}"

    if [[ -n "$cached" ]]; then
        local cache_time="${cached%%|*}"
        local cache_val="${cached#*|}"
        local now=$EPOCHSECONDS

        if (( now - cache_time < _SAGE_CACHE_TTL )); then
            echo "$cache_val"
            return
        fi
    fi

    # Cache miss — query and rank
    local result
    result=$(_sage_rank_candidates "$prefix" "$dir" "$prev_cmd")

    if [[ -n "$result" ]]; then
        # Store in cache
        local now=$EPOCHSECONDS
        _SAGE_PREFIX_CACHE[$cache_key]="${now}|${result}"
    fi

    echo "$result"
}

# Clear stale cache entries (called periodically)
_sage_cache_cleanup() {
    local now=$EPOCHSECONDS
    local key

    for key in "${(@k)_SAGE_PREFIX_CACHE}"; do
        local cache_time="${_SAGE_PREFIX_CACHE[$key]%%|*}"
        if (( now - cache_time > _SAGE_CACHE_TTL )); then
            unset "_SAGE_PREFIX_CACHE[$key]"
        fi
    done
}
