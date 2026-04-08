#
# CLI — user-facing `zsage` command for status, profile info, and tuning
#

typeset -g _SAGE_VERSION="0.2.0"

# Colors (respects NO_COLOR env var)
_sage_color() {
    if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
        local reset=$'\033[0m'
        local green=$'\033[32m'
        local cyan=$'\033[36m'
        local yellow=$'\033[33m'
        local dim=$'\033[2m'
        local bold=$'\033[1m'
        local magenta=$'\033[35m'
        eval "$1=\"\$$2\""
    else
        eval "$1=''"
    fi
}

_sage_banner() {
    local g r c y d b m
    _sage_color g green; _sage_color r reset; _sage_color c cyan
    _sage_color y yellow; _sage_color d dim; _sage_color b bold
    _sage_color m magenta

    cat <<EOF
${g}          _                                ${r}
${g}  _______| |__        ___  __ _  __ _  ___ ${r}
${g} |_  / __| '_ \ ___  / __|/ _\` |/ _\` |/ _ \\${r}
${g}  / /\__ \ | | |___| \__ \ (_| | (_| |  __/${r}
${g} /___|___/_| |_|     |___/\__,_|\__, |\___|${r}
${g}                                |___/       ${r}
${d}  intelligent shell suggestions    v${_SAGE_VERSION}${r}
EOF
}

zsage() {
    local subcmd="${1:-help}"

    case "$subcmd" in
        status)
            _sage_cli_status
            ;;
        profile)
            _sage_cli_profile "$2"
            ;;
        stats)
            _sage_cli_stats
            ;;
        weights)
            _sage_cli_weights "$2"
            ;;
        version|-v|--version)
            echo "zsh-sage v${_SAGE_VERSION}"
            ;;
        credits|about)
            _sage_cli_credits
            ;;
        help|-h|--help|*)
            _sage_cli_help
            ;;
    esac
}

_sage_cli_help() {
    local g r c y d b m
    _sage_color g green; _sage_color r reset; _sage_color c cyan
    _sage_color y yellow; _sage_color d dim; _sage_color b bold
    _sage_color m magenta

    _sage_banner
    cat <<EOF

${b}USAGE${r}
  ${c}zsage${r} ${d}<command>${r}

${b}COMMANDS${r}
  ${c}status${r}     Show current configuration and DB stats
  ${c}profile${r}    Show available profiles and current weights
  ${c}stats${r}      Show your most frequent commands
  ${c}weights${r}    Show what zsh-sage has learned from your habits
  ${c}version${r}    Show version
  ${c}help${r}       Show this help

${b}CONFIGURATION${r} ${d}(add to ~/.zshrc)${r}
  ${y}export${r} ZSH_SAGE_PROFILE=${g}"default"${r}      ${d}# default | contextual | recent${r}
  ${y}export${r} ZSH_SAGE_W_FREQUENCY=${g}"0.30"${r}     ${d}# Override individual weights${r}
  ${y}export${r} ZSH_SAGE_AI_ENABLED=${g}true${r}        ${d}# Enable AI suggestions${r}
  ${y}export${r} ZSH_SAGE_API_KEY=${g}"sk-..."${r}       ${d}# Anthropic API key for AI mode${r}

${b}KEYBINDINGS${r}
  ${c}right arrow${r}     Accept full suggestion
  ${c}ctrl+right${r}      Accept word-by-word
  ${d}Just type to see suggestions appear as ghost text${r}

${b}CONFIDENCE COLORS${r}
  Ghost text color reflects how confident the suggestion is:
  $(printf '\033[38;5;108m  ████  high   (score > 0.7)  — sage green\033[0m')
  $(printf '\033[38;5;245m  ████  medium (0.3 - 0.7)   — grey\033[0m')
  $(printf '\033[38;5;240m  ████  low    (score < 0.3)  — faint\033[0m')

  ${d}Customize in ~/.zshrc:${r}
  ${y}export${r} ZSH_SAGE_COLOR_HIGH=${g}108${r}             ${d}# high confidence color (256-color)${r}
  ${y}export${r} ZSH_SAGE_COLOR_MED=${g}245${r}              ${d}# medium confidence color${r}
  ${y}export${r} ZSH_SAGE_COLOR_LOW=${g}240${r}              ${d}# low confidence color${r}
  ${y}export${r} ZSH_SAGE_CONFIDENCE_HIGH=${g}0.70${r}       ${d}# threshold for high${r}
  ${y}export${r} ZSH_SAGE_CONFIDENCE_LOW=${g}0.30${r}        ${d}# threshold for low${r}

${d}https://github.com/UtsavMandal2022/zsh-sage${r}
EOF
}

_sage_cli_status() {
    local g r c y d b m
    _sage_color g green; _sage_color r reset; _sage_color c cyan
    _sage_color y yellow; _sage_color d dim; _sage_color b bold
    _sage_color m magenta

    local cmd_count stat_count db_size

    cmd_count=$(_sage_db_query "SELECT COUNT(*) FROM commands;")
    stat_count=$(_sage_db_query "SELECT COUNT(*) FROM stats;")
    db_size=$(du -h "$ZSH_SAGE_DB" 2>/dev/null | cut -f1)

    _sage_banner
    cat <<EOF

${b}STATUS${r}
  ${d}Profile${r}         ${g}$ZSH_SAGE_PROFILE${r}
  ${d}Database${r}        $ZSH_SAGE_DB ${d}($db_size)${r}
  ${d}Commands logged${r} ${c}${cmd_count:-0}${r}
  ${d}Unique commands${r} ${c}${stat_count:-0}${r}
  ${d}AI enabled${r}      $(if [[ "$ZSH_SAGE_AI_ENABLED" == "true" ]]; then echo "${g}yes${r}"; else echo "${d}no${r}"; fi)

${b}WEIGHTS${r}
  ${m}frequency${r}  $ZSH_SAGE_W_FREQUENCY  ${d}$(printf '%-20s' "$(printf '%0.s|' $(seq 1 $(echo "$ZSH_SAGE_W_FREQUENCY * 20 / 1" | bc)))")${r}
  ${m}recency${r}    $ZSH_SAGE_W_RECENCY  ${d}$(printf '%-20s' "$(printf '%0.s|' $(seq 1 $(echo "$ZSH_SAGE_W_RECENCY * 20 / 1" | bc)))")${r}
  ${m}directory${r}   $ZSH_SAGE_W_DIRECTORY  ${d}$(printf '%-20s' "$(printf '%0.s|' $(seq 1 $(echo "$ZSH_SAGE_W_DIRECTORY * 20 / 1" | bc)))")${r}
  ${m}sequence${r}    $ZSH_SAGE_W_SEQUENCE  ${d}$(printf '%-20s' "$(printf '%0.s|' $(seq 1 $(echo "$ZSH_SAGE_W_SEQUENCE * 20 / 1" | bc)))")${r}
  ${m}success${r}     $ZSH_SAGE_W_SUCCESS  ${d}$(printf '%-20s' "$(printf '%0.s|' $(seq 1 $(echo "$ZSH_SAGE_W_SUCCESS * 20 / 1" | bc)))")${r}
EOF
}

_sage_cli_profile() {
    local g r c y d b m
    _sage_color g green; _sage_color r reset; _sage_color c cyan
    _sage_color y yellow; _sage_color d dim; _sage_color b bold
    _sage_color m magenta

    local target="$1"

    if [[ -z "$target" ]]; then
        cat <<EOF
${b}PROFILES${r}

  ${g}default${r}      ${d}Balanced, frequency-driven (safe for everyone)${r}
               ${m}freq${r}=0.30  ${m}recency${r}=0.25  ${m}dir${r}=0.20  ${m}seq${r}=0.15  ${m}success${r}=0.10

  ${c}contextual${r}   ${d}Context-heavy (directory + sequence matter most)${r}
               ${m}freq${r}=0.15  ${m}recency${r}=0.20  ${m}dir${r}=0.30  ${m}seq${r}=0.25  ${m}success${r}=0.10

  ${y}recent${r}       ${d}Recency-heavy (recent commands dominate)${r}
               ${m}freq${r}=0.15  ${m}recency${r}=0.40  ${m}dir${r}=0.15  ${m}seq${r}=0.20  ${m}success${r}=0.10

  ${d}Current:${r} ${b}$ZSH_SAGE_PROFILE${r}

  ${d}To switch, add to ~/.zshrc:${r}
    ${y}export${r} ZSH_SAGE_PROFILE=${g}"contextual"${r}

  ${d}To override individual weights on top of any profile:${r}
    ${y}export${r} ZSH_SAGE_W_FREQUENCY=${g}"0.25"${r}
EOF
        return
    fi

    case "$target" in
        default|contextual|recent)
            echo "To switch to '${target}', add this to your ~/.zshrc:"
            echo "  export ZSH_SAGE_PROFILE=\"$target\""
            echo ""
            echo "Then reload: source ~/.zshrc"
            ;;
        *)
            echo "Unknown profile: $target"
            echo "Available: default, contextual, recent"
            ;;
    esac
}

_sage_cli_stats() {
    local g r c y d b m
    _sage_color g green; _sage_color r reset; _sage_color c cyan
    _sage_color y yellow; _sage_color d dim; _sage_color b bold

    echo ""
    echo "${b}TOP COMMANDS${r}"
    echo "${d}───────────────────────────────────────────${r}"
    # Filter out junk entries: multiline fragments, leading whitespace
    _sage_db_query "SELECT printf('  %4d  %s', frequency, SUBSTR(command, 1, 60)) FROM stats
WHERE TRIM(command) = command
  AND LENGTH(TRIM(command)) > 1
  AND command NOT LIKE '%' || CHAR(92)
ORDER BY frequency DESC LIMIT 15;"
    echo ""
    echo "${d}───────────────────────────────────────────${r}"

    local total=$(_sage_db_query "SELECT COUNT(*) FROM commands;")
    echo "  ${d}Total commands recorded:${r} ${c}${total:-0}${r}"
    echo ""
}

_sage_cli_weights() {
    local g r c y d b m
    _sage_color g green; _sage_color r reset; _sage_color c cyan
    _sage_color y yellow; _sage_color d dim; _sage_color b bold
    _sage_color m magenta

    local sub="${1:-}"

    # Reset: wipe what zsh-sage has learned about your habits
    if [[ "$sub" == "reset" ]]; then
        local count
        count=$(_sage_db_query "SELECT COUNT(*) FROM weight_accepts;")
        : ${count:=0}

        if (( count == 0 )); then
            echo "Nothing to reset — zsh-sage hasn't learned anything yet."
            return
        fi

        echo "${y}This will forget ${count} suggestions zsh-sage has learned from.${r}"
        echo -n "Proceed? [y/N] "
        local reply
        read -r reply
        if [[ "$reply" == "y" || "$reply" == "Y" ]]; then
            _sage_db_exec "DELETE FROM weight_accepts;"
            echo "${g}Done.${r} zsh-sage has forgotten everything it learned."
        else
            echo "Cancelled."
        fi
        return
    fi

    echo ""
    echo "${b}LEARNING FROM YOUR HABITS${r}"
    echo "${d}───────────────────────────────────────────${r}"

    local total_accepts
    total_accepts=$(_sage_db_query "SELECT COUNT(*) FROM weight_accepts;")
    : ${total_accepts:=0}

    echo "  ${d}Suggestions you accepted:${r} ${c}${total_accepts}${r}"
    echo ""

    if (( total_accepts == 0 )); then
        echo "  ${d}Nothing learned yet. Use the shell normally —${r}"
        echo "  ${d}every time you accept a suggestion (with right arrow${r}"
        echo "  ${d}or by typing through the ghost text), zsh-sage learns${r}"
        echo "  ${d}a bit more about what you actually use.${r}"
        echo ""
        return
    fi

    # Show the current active weights
    echo "${b}HOW I'M RANKING SUGGESTIONS${r} ${d}(profile: ${ZSH_SAGE_PROFILE})${r}"
    printf "  ${m}frequency${r}    %s  ${d}how often you use the command${r}\n" "$ZSH_SAGE_W_FREQUENCY"
    printf "  ${m}recency${r}      %s  ${d}how recently you used it${r}\n" "$ZSH_SAGE_W_RECENCY"
    printf "  ${m}directory${r}    %s  ${d}whether you use it in this folder${r}\n" "$ZSH_SAGE_W_DIRECTORY"
    printf "  ${m}sequence${r}     %s  ${d}what you typically run next${r}\n" "$ZSH_SAGE_W_SEQUENCE"
    printf "  ${m}success${r}      %s  ${d}whether the command usually works${r}\n" "$ZSH_SAGE_W_SUCCESS"
    echo ""

    # Compute observed win shares from accept data (last 500)
    echo "${b}WHAT'S ACTUALLY HELPING YOU${r} ${d}(from your last ${total_accepts} accepts, capped at 500)${r}"

    local shares
    shares=$(_sage_db_query "
SELECT
    ROUND(SUM(freq_contrib) / NULLIF(SUM(freq_contrib + recency_contrib + dir_contrib + seq_contrib + success_contrib), 0), 3) as freq_share,
    ROUND(SUM(recency_contrib) / NULLIF(SUM(freq_contrib + recency_contrib + dir_contrib + seq_contrib + success_contrib), 0), 3) as rec_share,
    ROUND(SUM(dir_contrib) / NULLIF(SUM(freq_contrib + recency_contrib + dir_contrib + seq_contrib + success_contrib), 0), 3) as dir_share,
    ROUND(SUM(seq_contrib) / NULLIF(SUM(freq_contrib + recency_contrib + dir_contrib + seq_contrib + success_contrib), 0), 3) as seq_share,
    ROUND(SUM(success_contrib) / NULLIF(SUM(freq_contrib + recency_contrib + dir_contrib + seq_contrib + success_contrib), 0), 3) as succ_share
FROM (SELECT * FROM weight_accepts ORDER BY timestamp DESC LIMIT 500);")

    if [[ -n "$shares" ]]; then
        local -a share_fields
        share_fields=("${(@s:|:)shares}")
        printf "  ${m}frequency${r}    %s\n" "${share_fields[1]:-0}"
        printf "  ${m}recency${r}      %s\n" "${share_fields[2]:-0}"
        printf "  ${m}directory${r}    %s\n" "${share_fields[3]:-0}"
        printf "  ${m}sequence${r}     %s\n" "${share_fields[4]:-0}"
        printf "  ${m}success${r}      %s\n" "${share_fields[5]:-0}"
    fi
    echo ""

    if (( total_accepts < 50 )); then
        echo "  ${y}Still learning:${r} need ~$((50 - total_accepts)) more accepts before zsh-sage"
        echo "  ${d}has enough data to personalize suggestions for you.${r}"
    else
        echo "  ${g}Ready to personalize${r} — zsh-sage has enough data to start"
        echo "  ${d}tailoring suggestions to how you actually use your shell.${r}"
    fi
    echo ""
    echo "${d}───────────────────────────────────────────${r}"
    echo "${d}  Run ${c}zsage weights reset${d} to forget everything${r}"
    echo ""
}

_sage_cli_credits() {
    local g r c y d b m
    _sage_color g green; _sage_color r reset; _sage_color c cyan
    _sage_color y yellow; _sage_color d dim; _sage_color b bold
    _sage_color m magenta

    _sage_banner
    cat <<EOF

  ${d}crafted at late nights by${r}

     ${b}${m}Utsav${r}

  ${d}"Your shell should know you
   better than you know yourself."${r}

  ${d}github.com/UtsavMandal2022/zsh-sage${r}
EOF
}
