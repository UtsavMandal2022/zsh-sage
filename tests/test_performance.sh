#!/usr/bin/env zsh
#
# Performance benchmark: measures latency of the suggestion pipeline
# at various history sizes (1k, 5k, 10k entries)
#

set -uo pipefail

TEST_DB="/tmp/sage-perf-test-$$.db"

export ZSH_SAGE_DB="$TEST_DB"
export ZSH_SAGE_MAX_CANDIDATES=10
export ZSH_SAGE_W_FREQUENCY="0.30"
export ZSH_SAGE_W_RECENCY="0.25"
export ZSH_SAGE_W_DIRECTORY="0.20"
export ZSH_SAGE_W_SEQUENCE="0.15"
export ZSH_SAGE_W_SUCCESS="0.10"

SCRIPT_DIR="$(dirname $0)"
source "$SCRIPT_DIR/../src/core/db.zsh"
source "$SCRIPT_DIR/../src/core/scorer.zsh"
source "$SCRIPT_DIR/../src/strategies/local.zsh"

cleanup() { rm -f "$TEST_DB"; }
trap cleanup EXIT

zmodload zsh/datetime

# Measure time in milliseconds using zsh's high-res timer
time_ms() {
    local start=$EPOCHREALTIME
    eval "$@" > /dev/null 2>&1
    local end=$EPOCHREALTIME
    echo "($end - $start) * 1000" | bc -l
}

# Generate realistic commands
COMMANDS=(
    "git status" "git add ." "git commit -m 'update'" "git push" "git pull"
    "git checkout main" "git checkout -b feature/test" "git log --oneline"
    "git diff" "git stash" "git stash pop" "git merge main" "git rebase main"
    "npm test" "npm install" "npm run build" "npm run dev" "npm start"
    "docker build ." "docker compose up" "docker compose down" "docker ps"
    "kubectl get pods" "kubectl get svc" "kubectl logs -f" "kubectl apply -f"
    "cd ~/projects" "cd .." "ls -la" "cat README.md" "vim config.yaml"
    "python3 main.py" "python3 -m pytest" "pip install -r requirements.txt"
    "make build" "make test" "make clean" "make deploy"
    "curl -s localhost:8080" "ssh dev-server" "scp file.txt remote:/tmp"
    "grep -r TODO ." "find . -name '*.py'" "wc -l src/*.py"
)

DIRS=(
    "/Users/user/project-a"
    "/Users/user/project-b"
    "/Users/user/project-c"
    "/Users/user/infra"
    "/Users/user/scripts"
    "/tmp"
)

seed_database() {
    local count="$1"
    local now=$(date +%s)
    local sql=""
    local i cmd_idx dir_idx cmd dir prev_cmd exit_code ts

    echo -n "  Seeding $count entries... "

    for i in $(seq 1 $count); do
        cmd_idx=$(( (RANDOM % ${#COMMANDS[@]}) + 1 ))
        dir_idx=$(( (RANDOM % ${#DIRS[@]}) + 1 ))
        cmd="${COMMANDS[$cmd_idx]}"
        dir="${DIRS[$dir_idx]}"
        prev_cmd="${COMMANDS[$(( (RANDOM % ${#COMMANDS[@]}) + 1 ))]}"
        exit_code=$(( RANDOM % 10 == 0 ? 1 : 0 ))  # 10% failure rate
        ts=$(( now - RANDOM ))

        local e_cmd="$(_sage_sql_escape "$cmd")"
        local e_dir="$(_sage_sql_escape "$dir")"
        local e_prev="$(_sage_sql_escape "$prev_cmd")"

        sql+="INSERT INTO commands (command, directory, prev_command, exit_code, timestamp, git_branch)
VALUES ('${e_cmd}', '${e_dir}', '${e_prev}', ${exit_code}, ${ts}, 'main');
"
        sql+="INSERT INTO stats (command, directory, frequency, last_used, success_count, fail_count)
VALUES ('${e_cmd}', '${e_dir}', 1, ${ts},
    CASE WHEN ${exit_code} = 0 THEN 1 ELSE 0 END,
    CASE WHEN ${exit_code} != 0 THEN 1 ELSE 0 END)
ON CONFLICT(command, directory) DO UPDATE SET
    frequency = frequency + 1,
    last_used = MAX(last_used, ${ts}),
    success_count = success_count + CASE WHEN ${exit_code} = 0 THEN 1 ELSE 0 END,
    fail_count = fail_count + CASE WHEN ${exit_code} != 0 THEN 1 ELSE 0 END;
"
        # Batch insert every 500 rows. Wrap in BEGIN/COMMIT so sqlite
        # does one fsync per batch instead of one per INSERT (100-1000x
        # faster on disk-backed DBs).
        if (( i % 500 == 0 )); then
            printf 'BEGIN;\n%sCOMMIT;\n' "$sql" | sqlite3 "$ZSH_SAGE_DB"
            sql=""
        fi
    done

    # Insert remaining
    if [[ -n "$sql" ]]; then
        printf 'BEGIN;\n%sCOMMIT;\n' "$sql" | sqlite3 "$ZSH_SAGE_DB"
    fi

    local total_stats=$(printf 'SELECT COUNT(*) FROM stats;' | sqlite3 "$ZSH_SAGE_DB")
    local total_cmds=$(printf 'SELECT COUNT(*) FROM commands;' | sqlite3 "$ZSH_SAGE_DB")
    echo "done ($total_cmds command rows, $total_stats unique stats)"
}

typeset -g _BENCH_LAST_AVG=0

benchmark_operation() {
    local label="$1"
    shift
    local runs=5
    local i t
    local sum=0
    local min=999999
    local max=0
    local measurements=""

    for i in $(seq 1 $runs); do
        t=$(time_ms "$@")
        measurements+="${t}\n"
    done

    # Use bc for all float math
    local stats
    stats=$(printf "$measurements" | python3 -c "
import sys
vals = [float(l.strip()) for l in sys.stdin if l.strip()]
if vals:
    print(f'{min(vals):.1f} {sum(vals)/len(vals):.1f} {max(vals):.1f}')
else:
    print('0.0 0.0 0.0')
")

    local min_v="${stats%% *}"; stats="${stats#* }"
    local avg_v="${stats%% *}"
    local max_v="${stats#* }"

    printf "  %-40s  min:%7sms  avg:%7sms  max:%7sms\n" "$label" "$min_v" "$avg_v" "$max_v"
    _BENCH_LAST_AVG="${avg_v%%.*}"  # Integer for comparison
}

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║            zsh-sage Performance Benchmark                   ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Target: < 50ms per keystroke for smooth typing             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

for size in 1000 5000 10000; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  History size: $size entries"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    rm -f "$TEST_DB"
    _sage_db_init
    seed_database "$size"

    # Clear caches
    typeset -gA _SAGE_PREFIX_CACHE=()

    echo ""
    echo "  Component benchmarks:"

    # Benchmark individual components
    benchmark_operation "SQLite prefix query (git)" \
        '_sage_db_candidates "git" "/Users/user/project-a"'

    benchmark_operation "SQLite dir-specific query (git)" \
        '_sage_db_candidates_dir "git" "/Users/user/project-a"'

    benchmark_operation "Sequence score lookup" \
        '_sage_db_sequence_score "git commit" "git add ."'

    local ts_now=$(date +%s)
    benchmark_operation "Score single candidate" \
        "_sage_score_candidate 'git status|50|${ts_now}|45|5' '/Users/user/project-a' 'git add .' '${ts_now}'"

    benchmark_operation "Full rank (query + score all)" \
        '_sage_rank_candidates "git" "/Users/user/project-a" "git add ."'
    local avg_rank=$_BENCH_LAST_AVG

    benchmark_operation "Local strategy (with cache miss)" \
        '_sage_strategy_local "git" "/Users/user/project-a" "git add ."'

    # Cache hit test
    _sage_strategy_local "git" "/Users/user/project-a" "git add ." > /dev/null
    benchmark_operation "Local strategy (cache hit)" \
        '_sage_strategy_local "git" "/Users/user/project-a" "git add ."'

    # Different prefix lengths
    benchmark_operation "Full rank - short prefix (g)" \
        '_sage_rank_candidates "g" "/Users/user/project-a" ""'

    benchmark_operation "Full rank - long prefix (git commit)" \
        '_sage_rank_candidates "git commit" "/Users/user/project-a" ""'

    echo ""

    # Verdict
    if (( avg_rank < 50 )); then
        echo "  PASS: Full rank avg ${avg_rank}ms (under 50ms target)"
    elif (( avg_rank < 100 )); then
        echo "  WARN: Full rank avg ${avg_rank}ms (over 50ms target, noticeable)"
    else
        echo "  SLOW: Full rank avg ${avg_rank}ms (over 100ms, will feel laggy)"
    fi
    echo ""
done
