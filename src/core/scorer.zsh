#
# Scorer — multi-signal ranking of suggestion candidates
#
# PERFORMANCE-CRITICAL: All scoring happens in a single SQLite query.
# No per-candidate subshells, no bc -l loops.
#
# Approximations used (to avoid needing SQLite math extensions):
#   - Frequency: sqrt-scaled instead of log-scaled (close enough, no ln needed)
#   - Recency: linear decay over 7 days (0→1 scale) instead of exponential
#   - Both produce correct relative ordering with much simpler SQL
#

# Score and rank all candidates in one SQL query — returns the best command
_sage_rank_candidates() {
    local prefix="$1"
    local dir="$2"
    local prev_cmd="$3"

    local e_prefix="$(_sage_sql_escape "$prefix")"
    local e_dir="$(_sage_sql_escape "$dir")"
    local e_prev="$(_sage_sql_escape "$prev_cmd")"

    local like_prefix="${e_prefix//\%/\$%}"
    like_prefix="${like_prefix//_/\$_}"

    local now
    now=$(date +%s)

    # Weights
    local wf="$ZSH_SAGE_W_FREQUENCY"
    local wr="$ZSH_SAGE_W_RECENCY"
    local wd="$ZSH_SAGE_W_DIRECTORY"
    local ws="$ZSH_SAGE_W_SEQUENCE"
    local wk="$ZSH_SAGE_W_SUCCESS"

    # Decay window: 7 days in seconds
    local decay_window=604800

    local sql="
WITH global_max AS (
    SELECT MAX(frequency) as max_freq FROM stats
),
dir_stats AS (
    SELECT command, frequency as dir_freq
    FROM stats
    WHERE directory = '${e_dir}'
),
seq_stats AS (
    SELECT
        command,
        CAST(COUNT(*) AS REAL) / MAX(
            (SELECT COUNT(*) FROM commands WHERE prev_command = '${e_prev}'), 1
        ) as seq_score
    FROM commands
    WHERE prev_command = '${e_prev}'
      AND command LIKE '${like_prefix}%' ESCAPE '$'
    GROUP BY command
)
SELECT
    s.command,
    (
        ${wf} * (CASE WHEN gm.max_freq > 0
                 THEN MIN(1.0, SQRT(CAST(s.frequency AS REAL) / gm.max_freq))
                 ELSE 0 END) +

        ${wr} * MAX(0, 1.0 - (CAST(${now} - s.last_used AS REAL) / ${decay_window})) +

        ${wd} * (CASE WHEN ds.dir_freq IS NOT NULL AND gm.max_freq > 0
                 THEN MIN(1.0, SQRT(CAST(ds.dir_freq AS REAL) / gm.max_freq))
                 ELSE 0 END) +

        ${ws} * COALESCE(ss.seq_score, 0) +

        ${wk} * (CASE WHEN (s.success_count + s.fail_count) > 0
                 THEN CAST(s.success_count AS REAL) / (s.success_count + s.fail_count)
                 ELSE 0.5 END)
    ) as score
FROM stats s
CROSS JOIN global_max gm
LEFT JOIN dir_stats ds ON ds.command = s.command
LEFT JOIN seq_stats ss ON ss.command = s.command
WHERE s.command LIKE '${like_prefix}%' ESCAPE '$'
ORDER BY score DESC
LIMIT 1;"

    local result
    result=$(_sage_db_query "$sql")
    # Result is "command|score" — extract just the command from first line
    [[ -n "$result" ]] && printf '%s' "${result%%|*}"
}

# Same as _sage_rank_candidates but returns "score|command" for confidence coloring
_sage_rank_with_score() {
    local prefix="$1"
    local dir="$2"
    local prev_cmd="$3"

    local e_prefix="$(_sage_sql_escape "$prefix")"
    local e_dir="$(_sage_sql_escape "$dir")"
    local e_prev="$(_sage_sql_escape "$prev_cmd")"

    local like_prefix="${e_prefix//\%/\$%}"
    like_prefix="${like_prefix//_/\$_}"

    local now
    now=$(date +%s)

    local wf="$ZSH_SAGE_W_FREQUENCY"
    local wr="$ZSH_SAGE_W_RECENCY"
    local wd="$ZSH_SAGE_W_DIRECTORY"
    local ws="$ZSH_SAGE_W_SEQUENCE"
    local wk="$ZSH_SAGE_W_SUCCESS"
    local decay_window=604800

    local sql="
WITH global_max AS (
    SELECT MAX(frequency) as max_freq FROM stats
),
dir_stats AS (
    SELECT command, frequency as dir_freq
    FROM stats
    WHERE directory = '${e_dir}'
),
seq_stats AS (
    SELECT
        command,
        CAST(COUNT(*) AS REAL) / MAX(
            (SELECT COUNT(*) FROM commands WHERE prev_command = '${e_prev}'), 1
        ) as seq_score
    FROM commands
    WHERE prev_command = '${e_prev}'
      AND command LIKE '${like_prefix}%' ESCAPE '\$'
    GROUP BY command
)
SELECT
    (
        ${wf} * (CASE WHEN gm.max_freq > 0
                 THEN MIN(1.0, SQRT(CAST(s.frequency AS REAL) / gm.max_freq))
                 ELSE 0 END) +
        ${wr} * MAX(0, 1.0 - (CAST(${now} - s.last_used AS REAL) / ${decay_window})) +
        ${wd} * (CASE WHEN ds.dir_freq IS NOT NULL AND gm.max_freq > 0
                 THEN MIN(1.0, SQRT(CAST(ds.dir_freq AS REAL) / gm.max_freq))
                 ELSE 0 END) +
        ${ws} * COALESCE(ss.seq_score, 0) +
        ${wk} * (CASE WHEN (s.success_count + s.fail_count) > 0
                 THEN CAST(s.success_count AS REAL) / (s.success_count + s.fail_count)
                 ELSE 0.5 END)
    ) as score,
    s.command
FROM stats s
CROSS JOIN global_max gm
LEFT JOIN dir_stats ds ON ds.command = s.command
LEFT JOIN seq_stats ss ON ss.command = s.command
WHERE s.command LIKE '${like_prefix}%' ESCAPE '\$'
ORDER BY score DESC
LIMIT 1;"

    local result
    result=$(_sage_db_query "$sql")
    [[ -n "$result" ]] && printf '%s' "$result"
}

# Score a single candidate (kept for testing — uses the same SQL approach)
_sage_score_candidate() {
    local candidate="$1"
    local current_dir="$2"
    local prev_cmd="$3"
    local now="$4"

    # Parse pipe-delimited fields
    local cmd="${candidate%%|*}";        candidate="${candidate#*|}"
    local freq="${candidate%%|*}";       candidate="${candidate#*|}"
    local last_used="${candidate%%|*}";  candidate="${candidate#*|}"
    local success="${candidate%%|*}";    candidate="${candidate#*|}"
    local fail="$candidate"

    : ${freq:=0} ${last_used:=0} ${success:=0} ${fail:=0}

    local e_cmd="$(_sage_sql_escape "$cmd")"
    local e_dir="$(_sage_sql_escape "$current_dir")"
    local e_prev="$(_sage_sql_escape "$prev_cmd")"
    local decay_window=604800

    local wf="$ZSH_SAGE_W_FREQUENCY"
    local wr="$ZSH_SAGE_W_RECENCY"
    local wd="$ZSH_SAGE_W_DIRECTORY"
    local ws="$ZSH_SAGE_W_SEQUENCE"
    local wk="$ZSH_SAGE_W_SUCCESS"

    # Get max frequency for normalization
    local max_freq
    max_freq=$(_sage_db_query "SELECT MAX(frequency) FROM stats;")
    : ${max_freq:=1}

    # Get dir-specific frequency
    local dir_freq
    dir_freq=$(_sage_db_query "SELECT frequency FROM stats WHERE command='${e_cmd}' AND directory='${e_dir}';")
    : ${dir_freq:=0}

    # Get sequence score
    local seq_score
    seq_score=$(_sage_db_query "SELECT CAST(COUNT(*) AS REAL) / MAX((SELECT COUNT(*) FROM commands WHERE prev_command='${e_prev}'),1) FROM commands WHERE command='${e_cmd}' AND prev_command='${e_prev}';")
    : ${seq_score:=0}

    # Compute score in one bc call
    local total=$((success + fail))
    local success_rate=0.5
    if (( total > 0 )); then
        success_rate=$(echo "$success / $total" | bc -l)
    fi

    local age=$((now - last_used))
    local recency
    if (( age > decay_window )); then
        recency=0
    else
        recency=$(echo "1.0 - ($age / $decay_window)" | bc -l)
    fi

    local freq_norm=0
    if (( max_freq > 0 )); then
        freq_norm=$(echo "x = sqrt($freq / $max_freq); if (x > 1) 1 else x" | bc -l)
    fi

    local dir_norm=0
    if (( max_freq > 0 && dir_freq > 0 )); then
        dir_norm=$(echo "x = sqrt($dir_freq / $max_freq); if (x > 1) 1 else x" | bc -l)
    fi

    local final
    final=$(echo "${wf} * ${freq_norm} + ${wr} * ${recency} + ${wd} * ${dir_norm} + ${ws} * ${seq_score} + ${wk} * ${success_rate}" | bc -l)

    printf '%.6f|%s\n' "$final" "$cmd"
}
