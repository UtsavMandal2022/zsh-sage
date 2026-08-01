#
# Database layer — all SQLite interactions go through here
#
# Uses a persistent sqlite3 coprocess to avoid fork-per-query overhead.
# The coproc stays alive for the shell session (~1-2MB RAM, 0% idle CPU).
#

typeset -g _SAGE_COPROC_ALIVE=0
typeset -g _SAGE_EOF_SENTINEL="__SAGE_e0f_7d2b9k__"
# ASCII Unit Separator — used as field delimiter for sqlite output so
# commands containing '|' (e.g. `ps -ef | grep foo`) don't corrupt parsing.
typeset -g _SAGE_SEP=$'\x1f'

# ── Coprocess management ─────────────────────────────────────────

# Start the persistent sqlite3 coprocess
_sage_coproc_start() {
    # Already running?
    if (( _SAGE_COPROC_ALIVE )) && _sage_coproc_check; then
        return 0
    fi

    # Disable job-control monitoring locally so zsh doesn't print
    # "[N] PID" when the coproc starts. `disown` only stops the later
    # "done" notification — by the time it runs, the spawn message is
    # already on screen. NO_MONITOR suppresses both. The coproc is an
    # internal implementation detail, not user-visible work; the fds
    # stay valid and `.quit` from _sage_coproc_stop still gives it a
    # clean shutdown.
    setopt local_options no_monitor no_notify
    # NOTE: ".separator" must come as a -cmd AFTER ".mode list" — the
    # -separator flag is applied first and ".mode list" resets the
    # separator back to the default '|'.
    # -batch -init /dev/null: skip the user's ~/.sqliterc — settings like
    # ".headers on" or ".mode column" there leak a header row (or reformat
    # output) into every query result, which the widgets then parse as a
    # suggestion named "clean_cmd" with score "score" (issue #17).
    # ".headers off" is belt-and-braces on top.
    coproc sqlite3 -batch -init /dev/null -cmd ".headers off" -cmd ".mode list" -cmd ".separator ${_SAGE_SEP}" "$ZSH_SAGE_DB" 2>/dev/null
    disown 2>/dev/null

    # Verify the coproc actually started
    if ! print -p "SELECT 1;" 2>/dev/null; then
        _SAGE_COPROC_ALIVE=0
        return 1
    fi
    print -p ".print ${_SAGE_EOF_SENTINEL}" 2>/dev/null
    local line
    while IFS= read -r -p -t 2 line 2>/dev/null; do
        [[ "$line" == *"${_SAGE_EOF_SENTINEL}"* ]] && break
    done

    _SAGE_COPROC_ALIVE=1

    # Prevent "you have running jobs" warning on shell exit
    # The coproc is our internal implementation detail, not a user job
    setopt NO_CHECK_JOBS NO_HUP 2>/dev/null

    # Enable WAL mode for better concurrent access (multiple tabs)
    _sage_db_query_raw "PRAGMA journal_mode=WAL;" > /dev/null 2>&1
    # Wait up to 5s when another connection holds the write lock
    # instead of failing immediately with "database is locked". Matters
    # for tests and for concurrent activity across multiple terminals.
    _sage_db_query_raw "PRAGMA busy_timeout=5000;" > /dev/null 2>&1
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
    while IFS= read -r -p -t 2 line 2>/dev/null; do
        [[ "$line" == "$_SAGE_EOF_SENTINEL" ]] && break
    done
    return 0
}

# Stop the coprocess gracefully
_sage_coproc_stop() {
    if (( _SAGE_COPROC_ALIVE )); then
        # Tell sqlite3 to quit
        print -p ".quit" 2>/dev/null
        _SAGE_COPROC_ALIVE=0
    fi
}

# Shutdown hook — clean exit without "you have running jobs" warning
_sage_shutdown() {
    _sage_coproc_stop
    wait 2>/dev/null
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

    # Send query + sentinel.
    # `-r` (raw) is essential: without it, zsh's `print` interprets backslash
    # escapes in the SQL string, so a user command like `echo foo\ bar` reaches
    # sqlite as `echo foo bar` (backslash stripped) and gets stored that way.
    print -r -p "$sql" 2>/dev/null || {
        # Coproc died — respawn and retry once
        _SAGE_COPROC_ALIVE=0
        _sage_coproc_start
        print -r -p "$sql" 2>/dev/null || return 1
    }
    print -r -p ".print ${_SAGE_EOF_SENTINEL}" 2>/dev/null

    # Read until sentinel (with timeout to prevent hangs)
    # Use short timeout — queries should complete in <100ms.
    # `-r` (raw) is essential: without it, zsh's `read` strips backslashes from
    # the input line, so a stored command like `echo foo\ bar` comes back as
    # `echo foo bar` and the suggestion shown / accepted is missing the escape.
    local line
    local result=""
    while IFS= read -r -p -t 1 line 2>/dev/null; do
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
# Falls back to fork if coproc is unavailable (e.g. non-interactive CI)
# Set ZSH_SAGE_NO_COPROC=1 to force fork mode (useful for testing/CI)
_sage_db_query() {
    if (( ${ZSH_SAGE_NO_COPROC:-0} )); then
        _sage_db_fork "$1"
    elif (( _SAGE_COPROC_ALIVE )); then
        _sage_db_query_raw "$1"
    else
        _sage_coproc_start 2>/dev/null
        if (( _SAGE_COPROC_ALIVE )); then
            _sage_db_query_raw "$1"
        else
            _sage_db_fork "$1"
        fi
    fi
}

# Execute a write query (no output expected)
_sage_db_exec() {
    _sage_db_query "$1" > /dev/null 2>&1
}

# Fallback: run via sqlite3 fork (for init and import where coproc isn't ready)
_sage_db_fork() {
    printf '%s' "$1" | sqlite3 -batch -init /dev/null -cmd ".headers off" -separator "$_SAGE_SEP" -cmd ".timeout 5000" "$ZSH_SAGE_DB"
}

# ── Database initialization ──────────────────────────────────────

_sage_db_init() {
    # Stop any existing coproc (in case the DB file changed, e.g. during tests)
    _sage_coproc_stop 2>/dev/null
    _SAGE_COPROC_ALIVE=0

    # Schema must be created via fork since coproc needs the DB to exist first
    sqlite3 -batch -init /dev/null "$ZSH_SAGE_DB" <<'SQL'
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

-- Accepted suggestion log for adaptive weights
-- Each row records which signals contributed to a correct prediction
CREATE TABLE IF NOT EXISTS weight_accepts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp       INTEGER NOT NULL,
    freq_contrib    REAL DEFAULT 0,
    recency_contrib REAL DEFAULT 0,
    dir_contrib     REAL DEFAULT 0,
    seq_contrib     REAL DEFAULT 0,
    success_contrib REAL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_commands_prefix ON commands(command COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_commands_dir ON commands(directory);
CREATE INDEX IF NOT EXISTS idx_commands_prev ON commands(prev_command);
CREATE INDEX IF NOT EXISTS idx_stats_dir ON stats(directory);
CREATE INDEX IF NOT EXISTS idx_weight_accepts_ts ON weight_accepts(timestamp DESC);
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

# Record an accepted suggestion with its signal breakdown
# Args: freq_contrib recency_contrib dir_contrib seq_contrib success_contrib
_sage_db_record_accept() {
    local ts=$(date +%s)
    _sage_db_exec "INSERT INTO weight_accepts
(timestamp, freq_contrib, recency_contrib, dir_contrib, seq_contrib, success_contrib)
VALUES (${ts}, ${1:-0}, ${2:-0}, ${3:-0}, ${4:-0}, ${5:-0});"
}

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

    local like_prefix="${prefix//\$/\$\$}"
    like_prefix="${like_prefix//\%/\$%}"
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

    local like_prefix="${prefix//\$/\$\$}"
    like_prefix="${like_prefix//\%/\$%}"
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

    local like_cmd="${cmd//\$/\$\$}"
    like_cmd="${like_cmd//\%/\$%}"
    like_cmd="${like_cmd//_/\$_}"

    _sage_db_query "SELECT CAST(COUNT(*) AS FLOAT) /
    MAX((SELECT COUNT(*) FROM commands WHERE prev_command = '${prev_cmd}'), 1)
FROM commands
WHERE command LIKE '${like_cmd}%' ESCAPE '$'
  AND prev_command = '${prev_cmd}';"
}

# Import existing zsh history with sequence inference
#
# Uses zsh's own history machinery (fc) to parse the file rather than
# reading it line by line: histfiles are metafied (non-ASCII bytes are
# 0x83-escaped), multiline commands are stored as backslash
# continuations, and timestamps are optional — hand-parsing gets all
# three wrong. All rows stream through a single sqlite3 process on
# stdin, so import works and stays fast regardless of history size,
# command length, or shell options like ALL_EXPORT (building batches
# in shell variables broke ARG_MAX and silently dropped rows — #9).
_sage_db_import_history() {
    emulate -L zsh
    setopt local_options extended_glob no_all_export

    local histfile="${1:-$HISTFILE}"
    if [[ ! -r "$histfile" ]]; then
        echo "Cannot read history file: ${histfile:-\$HISTFILE is not set}"
        return 1
    fi

    echo "Importing history from $histfile..."

    local before after
    before=$(_sage_db_fork "SELECT COUNT(*) FROM commands;")

    # Switch to an isolated history list loaded from $histfile.
    # savesize 0 guarantees nothing is ever written back to the file.
    # NOTE: fc -p is NOT restored automatically on function return —
    # the always-block below is what protects the session history.
    if ! builtin fc -p "$histfile" 9999999 0 2>/dev/null; then
        echo "Could not load history from $histfile"
        return 1
    fi

    {
        # Event number -> epoch timestamp from one builtin listing.
        # fc -l prints one line per event (embedded newlines render as
        # literal backslash-n) as "<event>[*] <epoch>  <command>", so
        # whitespace splitting is unambiguous. Dumped to a temp file
        # and slurped with $(<file): reading builtin output through a
        # pipe (via `while read` or $(...)) degrades to byte-sized
        # read() syscalls in zsh — ~50x slower on big histories.
        local -A ts_for
        local tsdump="${TMPDIR:-/tmp}/.zsh-sage-import.$$" listing line
        local -a parts
        builtin fc -l -t '%s' 1 > "$tsdump" 2>/dev/null
        listing="$(<$tsdump)"
        command rm -f "$tsdump"
        for line in "${(@f)listing}"; do
            parts=(${=line})
            (( ${#parts} >= 2 )) && ts_for[${parts[1]%\*}]="${parts[2]}"
        done
        unset listing

        # Fallback timestamp for events without one (no fork needed)
        local now="${(%):-%D{%s}}"

        # $history's key listing omits the newest event ($HISTCMD) even
        # though it is subscriptable — add it back explicitly.
        local -a events
        events=(${(kon)history})
        if [[ -n "${history[$HISTCMD]:-}" ]] && (( ${events[(I)$HISTCMD]} == 0 )); then
            events+=($HISTCMD)
        fi

        # Quote-doubling via variables: backslashes in the replacement
        # side of ${var//pat/repl} are literal, so \'\' would inject
        # actual backslashes (same reason _sage_sql_escape uses vars).
        local sq="'" dsq="''"
        local evt cmd prev="" e_cmd e_prev ts count=0
        {
            print 'BEGIN;'
            for evt in $events; do
                cmd="${history[$evt]}"
                [[ -z "$cmd" ]] && continue
                (( ${#cmd} < 2 )) && continue

                ts="${ts_for[$evt]:-$now}"
                [[ "$ts" == <-> ]] || ts="$now"

                e_cmd="${cmd//$sq/$dsq}"
                e_prev="${prev//$sq/$dsq}"

                print -r -- "INSERT INTO commands (command, directory, prev_command, exit_code, timestamp, git_branch)
VALUES ('${e_cmd}', '~', '${e_prev}', 0, ${ts}, '');"
                print -r -- "INSERT INTO stats (command, directory, frequency, last_used, success_count, fail_count)
VALUES ('${e_cmd}', '~', 1, ${ts}, 1, 0)
ON CONFLICT(command, directory) DO UPDATE SET
    frequency = frequency + 1,
    last_used = MAX(last_used, ${ts});"

                prev="$cmd"
                (( ++count % 2000 )) || print -u2 "  ...prepared $count entries"
            done
            print 'COMMIT;'
        } | command sqlite3 -batch -init /dev/null "$ZSH_SAGE_DB"
        local sqlite_status=$pipestatus[2]

        # Report what actually landed in the DB, not what we attempted
        after=$(_sage_db_fork "SELECT COUNT(*) FROM commands;")
        if (( sqlite_status != 0 )); then
            echo "Import finished with errors (sqlite3 exit ${sqlite_status})."
        fi
        echo "Imported $(( after - before )) history entries (with sequence data)."
        (( sqlite_status == 0 ))
    } always {
        # Restore the session's real history
        builtin fc -P 2>/dev/null
    }
}
