#
# Database layer — all SQLite interactions go through here
#
# Uses a persistent sqlite3 coprocess to avoid fork-per-query overhead.
# The coproc stays alive for the shell session (~1-2MB RAM, 0% idle CPU).
#

typeset -g _SAGE_COPROC_ALIVE=0
typeset -g _SAGE_EOF_SENTINEL="__SAGE_e0f_7d2b9k__"

# ── Coprocess management ─────────────────────────────────────────

# Start the persistent sqlite3 coprocess
_sage_coproc_start() {
    # Already running?
    if (( _SAGE_COPROC_ALIVE )) && _sage_coproc_check; then
        return 0
    fi

    coproc sqlite3 -separator '|' -cmd ".mode list" "$ZSH_SAGE_DB" 2>/dev/null
    _SAGE_COPROC_ALIVE=1

    # Enable WAL mode for better concurrent access (multiple tabs)
    _sage_db_query_raw "PRAGMA journal_mode=WAL;" > /dev/null 2>&1
}

# Check if coproc is still alive
_sage_coproc_check() {
    # Try to send a no-op query; if it fails, coproc is dead
    print -p "SELECT 1;" 2>/dev/null && print -p ".print ${_SAGE_EOF_SENTINEL}" 2>/dev/null || {
        _SAGE_COPROC_ALIVE=0
        return 1
    }
    # Drain the response
    local line
    while IFS= read -p -t 2 line 2>/dev/null; do
        [[ "$line" == "$_SAGE_EOF_SENTINEL" ]] && break
    done
    return 0
}

# Stop the coprocess gracefully
_sage_coproc_stop() {
    if (( _SAGE_COPROC_ALIVE )); then
        print -p ".quit" 2>/dev/null
        _SAGE_COPROC_ALIVE=0
    fi
}

# ── Query execution ──────────────────────────────────────────────

# Execute a query via the coproc and return results
# Handles auto-respawn if the coproc died
_sage_db_query_raw() {
    local sql="$1"

    # Ensure coproc is alive
    if (( ! _SAGE_COPROC_ALIVE )); then
        _sage_coproc_start
    fi

    # Send query + sentinel
    print -p "$sql" 2>/dev/null || {
        # Coproc died — respawn and retry once
        _SAGE_COPROC_ALIVE=0
        _sage_coproc_start
        print -p "$sql" 2>/dev/null || return 1
    }
    print -p ".print ${_SAGE_EOF_SENTINEL}" 2>/dev/null

    # Read until sentinel (with timeout to prevent hangs)
    # Use short timeout — queries should complete in <100ms
    local line
    local result=""
    while IFS= read -p -t 1 line 2>/dev/null; do
        [[ "$line" == *"${_SAGE_EOF_SENTINEL}"* ]] && break
        if [[ -n "$result" ]]; then
            result+=$'\n'"${line}"
        else
            result="${line}"
        fi
    done

    printf '%s' "$result"
}

# Execute a query and return results (convenience wrapper)
_sage_db_query() {
    _sage_db_query_raw "$1"
}

# Execute a write query (no output expected)
_sage_db_exec() {
    _sage_db_query_raw "$1" > /dev/null 2>&1
}

# Fallback: run via sqlite3 fork (for init and import where coproc isn't ready)
_sage_db_fork() {
    printf '%s' "$1" | sqlite3 "$ZSH_SAGE_DB"
}

# ── Database initialization ──────────────────────────────────────

_sage_db_init() {
    # Schema must be created via fork since coproc needs the DB to exist first
    sqlite3 "$ZSH_SAGE_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS commands (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    command     TEXT    NOT NULL,
    directory   TEXT    NOT NULL,
    prev_command TEXT   DEFAULT '',
    exit_code   INTEGER DEFAULT 0,
    timestamp   INTEGER NOT NULL,
    git_branch  TEXT    DEFAULT ''
);

CREATE TABLE IF NOT EXISTS stats (
    command     TEXT    NOT NULL,
    directory   TEXT    NOT NULL,
    frequency   INTEGER DEFAULT 1,
    last_used   INTEGER NOT NULL,
    success_count INTEGER DEFAULT 0,
    fail_count    INTEGER DEFAULT 0,
    PRIMARY KEY (command, directory)
);

CREATE INDEX IF NOT EXISTS idx_commands_prefix ON commands(command COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_commands_dir ON commands(directory);
CREATE INDEX IF NOT EXISTS idx_stats_dir ON stats(directory);
CREATE INDEX IF NOT EXISTS idx_stats_freq ON stats(frequency DESC);
SQL

    # Now start the persistent coproc
    _sage_coproc_start
}

# ── SQL escaping ─────────────────────────────────────────────────

_sage_sql_escape() {
    local s="$1"
    local sq="'"
    local dsq="''"
    printf '%s' "${s//$sq/$dsq}"
}

# ── CRUD operations ──────────────────────────────────────────────

# Record a command execution
_sage_db_record() {
    local cmd="$(_sage_sql_escape "$1")"
    local dir="$(_sage_sql_escape "$2")"
    local prev_cmd="$(_sage_sql_escape "$3")"
    local exit_code="$4"
    local timestamp="$5"
    local git_branch="$(_sage_sql_escape "$6")"

    _sage_db_exec "INSERT INTO commands (command, directory, prev_command, exit_code, timestamp, git_branch)
VALUES ('${cmd}', '${dir}', '${prev_cmd}', ${exit_code}, ${timestamp}, '${git_branch}');

INSERT INTO stats (command, directory, frequency, last_used, success_count, fail_count)
VALUES ('${cmd}', '${dir}', 1, ${timestamp},
    CASE WHEN ${exit_code} = 0 THEN 1 ELSE 0 END,
    CASE WHEN ${exit_code} != 0 THEN 1 ELSE 0 END)
ON CONFLICT(command, directory) DO UPDATE SET
    frequency = frequency + 1,
    last_used = ${timestamp},
    success_count = success_count + CASE WHEN ${exit_code} = 0 THEN 1 ELSE 0 END,
    fail_count = fail_count + CASE WHEN ${exit_code} != 0 THEN 1 ELSE 0 END;"
}

# Fetch candidates matching a prefix
_sage_db_candidates() {
    local prefix="$(_sage_sql_escape "$1")"
    local dir="$(_sage_sql_escape "$2")"
    local limit="${3:-$ZSH_SAGE_MAX_CANDIDATES}"

    local like_prefix="${prefix//\%/\$%}"
    like_prefix="${like_prefix//_/\$_}"

    _sage_db_query "SELECT s.command, s.frequency, s.last_used, s.success_count, s.fail_count
FROM stats s
WHERE s.command LIKE '${like_prefix}%' ESCAPE '$'
ORDER BY s.frequency DESC
LIMIT ${limit};"
}

# Fetch directory-specific candidates
_sage_db_candidates_dir() {
    local prefix="$(_sage_sql_escape "$1")"
    local dir="$(_sage_sql_escape "$2")"
    local limit="${3:-$ZSH_SAGE_MAX_CANDIDATES}"

    local like_prefix="${prefix//\%/\$%}"
    like_prefix="${like_prefix//_/\$_}"

    _sage_db_query "SELECT s.command, s.frequency, s.last_used, s.success_count, s.fail_count
FROM stats s
WHERE s.command LIKE '${like_prefix}%' ESCAPE '$'
  AND s.directory = '${dir}'
ORDER BY s.frequency DESC
LIMIT ${limit};"
}

# Get the most recent previous command
_sage_db_prev_command() {
    _sage_db_query "SELECT command FROM commands ORDER BY id DESC LIMIT 1;"
}

# Get sequence score: how often cmd follows prev_cmd
_sage_db_sequence_score() {
    local cmd="$(_sage_sql_escape "$1")"
    local prev_cmd="$(_sage_sql_escape "$2")"

    local like_cmd="${cmd//\%/\$%}"
    like_cmd="${like_cmd//_/\$_}"

    _sage_db_query "SELECT CAST(COUNT(*) AS FLOAT) /
    MAX((SELECT COUNT(*) FROM commands WHERE prev_command = '${prev_cmd}'), 1)
FROM commands
WHERE command LIKE '${like_cmd}%' ESCAPE '$'
  AND prev_command = '${prev_cmd}';"
}

# Import existing zsh history with sequence inference
# Parses consecutive history lines to build prev_command relationships
_sage_db_import_history() {
    local histfile="${1:-$HISTFILE}"
    local count=0
    local prev_cmd=""
    local prev_ts=0

    echo "Importing history from $histfile..."

    # Build batch SQL for speed
    local batch_sql=""
    while IFS= read -r line; do
        # Parse zsh extended history format: ": timestamp:0;command"
        local ts=0
        local cmd=""

        if [[ "$line" == ": "* ]]; then
            # Extract timestamp
            local meta="${line#: }"
            ts="${meta%%:*}"
            # Extract command (everything after the first ;)
            cmd="${line#*;}"
        else
            # Plain command (no timestamp)
            cmd="$line"
            ts=$(date +%s)
        fi

        # Skip empty, very short, or multiline continuation
        [[ -z "$cmd" ]] && continue
        (( ${#cmd} < 2 )) && continue

        local escaped="$(_sage_sql_escape "$cmd")"
        local escaped_prev="$(_sage_sql_escape "$prev_cmd")"

        # Insert into commands table (with sequence data)
        batch_sql+="INSERT INTO commands (command, directory, prev_command, exit_code, timestamp, git_branch)
VALUES ('${escaped}', '~', '${escaped_prev}', 0, ${ts}, '');
"
        # Upsert into stats table
        batch_sql+="INSERT INTO stats (command, directory, frequency, last_used, success_count, fail_count)
VALUES ('${escaped}', '~', 1, ${ts}, 1, 0)
ON CONFLICT(command, directory) DO UPDATE SET
    frequency = frequency + 1,
    last_used = MAX(last_used, ${ts});
"
        count=$((count + 1))
        prev_cmd="$cmd"
        prev_ts="$ts"

        # Flush every 300 rows
        if (( count % 300 == 0 )); then
            _sage_db_fork "BEGIN; ${batch_sql} COMMIT;"
            batch_sql=""
            echo "  ...imported $count entries"
        fi
    done < "$histfile"

    # Flush remaining
    if [[ -n "$batch_sql" ]]; then
        _sage_db_fork "BEGIN; ${batch_sql} COMMIT;"
    fi

    echo "Imported $count history entries (with sequence data)."
}

# ── Cleanup hook ─────────────────────────────────────────────────

# Register shutdown hook to cleanly stop coproc when shell exits
_sage_shutdown() {
    _sage_coproc_stop
}
