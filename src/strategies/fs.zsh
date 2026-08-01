#
# Filesystem strategy — glob-based file suggestions (issue #19)
#
# Fallback for when the history DB has no match: suggest a file or
# directory from the filesystem that completes the last word of the
# buffer, like zsh-autosuggestions' completion suggestions but as a
# pure zsh glob — no compsys, no zpty, no forks.
#
# Deliberate punts (never fires): words containing unexpanded ~ or
# $VAR, quotes, backslashes, or glob metacharacters; bare first words
# (command position) unless they start with ./ ../ or /; buffers
# ending in whitespace. Matching is case-sensitive (zsh glob default;
# a user's nocaseglob is not honored). Dotfiles match only when the
# typed base name itself starts with a dot.
#

# _sage_strategy_fs <buffer> [limit=1]
# Prints up to <limit> lines of "score<SEP>full-command-line" — the
# same contract as _sage_rank_top_n — or nothing if no match.
# Emits no contrib fields, so accepted fs suggestions never enter
# weight learning (the accept widget skips all-zero contribs).
_sage_strategy_fs() {
    emulate -L zsh
    local prefix="$1" limit="${2:-1}"

    # Buffer ends in whitespace — no partial word to complete
    [[ "$prefix" == *[[:space:]] ]] && return 1

    local word="${prefix##*[[:space:]]}"

    # Skip flags and empty words
    [[ -z "$word" || "$word" == -* ]] && return 1

    # Command position (first word): only fire for explicit paths,
    # otherwise we'd suggest plain files as commands
    if [[ "$word" == "$prefix" && "$word" != (./|../|/)* ]]; then
        return 1
    fi

    # Skip words containing quoting, expansion, or glob metacharacters —
    # expanding those correctly is completion-system territory
    [[ "$word" == *[\\\`\~\$\*\?\[\]\(\)\{\}\<\>\|\&\;\"\'\ ]* ]] && return 1

    # Glob: N=nullglob, M=mark directories with trailing /,
    # [1,limit]=cap after the default lexicographic sort.
    # $word contains no metacharacters (rejected above), so only the
    # trailing literal * globs.
    local -a matches
    matches=( ${word}*(NM[1,$limit]) )
    (( ${#matches} )) || return 1

    local head="${prefix[1, $#prefix - $#word]}"
    local score="${ZSH_SAGE_FS_SCORE:-0.15}"
    local m sug
    local -a lines=()
    for m in "${matches[@]}"; do
        # Backslash-escape spaces/specials so the accepted command is
        # valid. (q) rather than (qq): quote-wrapping would break the
        # widget's prefix-extending guard, backslash escaping cannot
        # (the typed portion is metacharacter-free, enforced above).
        sug="${head}${(q)m}"
        [[ "$sug" == "$prefix"* && "$sug" != "$prefix" ]] || continue
        lines+=("${score}${_SAGE_SEP}${sug}")
    done

    (( ${#lines} )) || return 1
    printf '%s\n' "${lines[@]}"
}
