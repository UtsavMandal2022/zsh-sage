<div align="center">
<pre>
 _______ _  _     ___   _   ___ ___
|_  / __| || |___/ __| /_\ / __| __|
 / /\__ \ __ |___\__ \/ _ \ (_ | _|
/___|___/_||_|   |___/_/ \_\___|___|
</pre>

**Your shell should know you better than you know yourself.**

Intelligent zsh autosuggestions that learn from your habits — powered by multi-signal ranking and confidence-colored ghost text.

[![Tests](https://github.com/UtsavMandal2022/zsh-sage/actions/workflows/test.yml/badge.svg)](https://github.com/UtsavMandal2022/zsh-sage/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

</div>

---

<div align="center">

https://github.com/user-attachments/assets/aa039fdf-dd2b-49b7-851e-8f322cdd54a3

</div>

## What makes it different

zsh-sage doesn't just match your most recent command. It scores every candidate across **5 signals** — frequency, recency, directory context, command sequences, and success rate — then shows the winner as colored ghost text that reflects how confident it is.

```
You type:   git co
                   ╭──────────────────────────────────────╮
                   │  frequency    git commit: 300 uses   │
                   │  recency      used 2 minutes ago     │
                   │  directory    in ~/project (common)   │
                   │  sequence     after "git add ."       │
                   │  success      100% exit code 0        │
                   ╰──────────────────────────────────────╯
Suggestion: git commit -m 'update'
            ~~~~~~~~~~~~~~~~~~~~~~  (sage green = high confidence)
```

Press **right arrow** to accept, **Ctrl+Right** to accept word-by-word, **Ctrl+N** to cycle through alternatives.

## Features

Everything below works out of the box — no configuration needed.

- **Multi-signal ranking** — frequency, recency, directory, command sequences, and success rate
- **Confidence colors** — ghost text turns sage green when confident, faint grey when guessing
- **Directory-aware** — different projects, different suggestions
- **Sequence-aware** — `git add .` → suggests `git commit`, not `git config`
- **Prefix-length-aware** — short prefixes lean on frequency, long prefixes lean on recency
- **Exponential recency decay** — smooth fade with a 3-day half-life, no cliffs
- **Failure penalty** — typos and broken commands get demoted
- **Learns from you** — every accepted suggestion tunes the ranking over time
- **Cycle through alternatives** — press Ctrl+N to browse ranked suggestions, confidence color updates with each one
- **`hm` command** — ask AI for commands in plain English, powered by Claude Code
- **~9ms per keystroke** — SQLite coproc, single-query scoring, zero fork overhead

## Confidence colors

Ghost text color reflects how confident the scorer is about the suggestion:

| Confidence | Color | Meaning |
|---|---|---|
| High (> 0.7) | Sage green | "I'm sure about this" |
| Medium (0.3 - 0.7) | Grey | "Decent guess" |
| Low (< 0.3) | Faint grey | "This is a stretch" |

You'll subconsciously learn to trust bright suggestions and be more skeptical of faint ones. Colors and thresholds are customizable — see [Advanced tuning](#advanced-manual-tuning).

## Installation

### Oh My Zsh

```zsh
# Clone
git clone https://github.com/UtsavMandal2022/zsh-sage.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-sage

# Add to plugins in ~/.zshrc (replacing zsh-autosuggestions if present)
plugins=(git zsh-sage zsh-syntax-highlighting)

# Reload
source ~/.zshrc
```

### Homebrew

```zsh
brew tap UtsavMandal2022/zsh-sage
brew install zsh-sage
```

### Manual

```zsh
git clone https://github.com/UtsavMandal2022/zsh-sage.git ~/zsh-sage
echo 'source ~/zsh-sage/zsh-sage.plugin.zsh' >> ~/.zshrc
source ~/.zshrc
```

## Import existing history

On first install, import your zsh history so suggestions work immediately:

```zsh
zsh -ic '_sage_db_import_history'
```

This seeds the database with your past commands. Sequence data (what follows what) builds up automatically as you use the shell.

## Configuration

**Most users don't need to configure anything.** zsh-sage adapts to your habits automatically — it shifts between frequency-heavy and recency-heavy ranking based on how much you've typed, learns which command follows which from your history, and scopes suggestions to the current directory. Just install it and use your shell normally.

### AI commands (`hm`)

Ask for shell commands in plain English — or get a fix for your last failed command.

```
$ hm find files larger than 1GB

  ┌────────────────────────────────────────────┐
  │  find / -type f -size +1G 2>/dev/null      │
  └────────────────────────────────────────────┘

  Run it? [y/N/e(dit)]
```

```
$ git push origin main
error: failed to push some refs...

$ hm

  Failed: git push origin main
  Exit code: 1

  ┌──────────────────────────────────────────────────────────────┐
  │  git pull --rebase origin main && git push origin main       │
  └──────────────────────────────────────────────────────────────┘

  Run it? [y/N/e(dit)]
```

**Setup** — requires [Claude Code](https://claude.ai/claude-code) CLI installed:

```zsh
zsage ai    # one-time setup, explains what happens, asks permission
```

How it works: each `hm` call runs `claude -p` with your shell context (directory, git branch, recent commands). No sessions are saved — calls are ephemeral. Uses your existing Claude Code subscription.

### Advanced: manual tuning

<details>
<summary>Profiles and weights (for power users)</summary>

If the defaults don't feel right, you can nudge the ranking manually. Three presets are available:

```zsh
export ZSH_SAGE_PROFILE="default"      # balanced, frequency-driven (default)
export ZSH_SAGE_PROFILE="contextual"   # directory + sequence heavy
export ZSH_SAGE_PROFILE="recent"       # recency-dominant
```

| Signal | default | contextual | recent |
|---|---|---|---|
| Frequency | 0.30 | 0.15 | 0.15 |
| Recency | 0.25 | 0.20 | 0.40 |
| Directory | 0.20 | 0.30 | 0.15 |
| Sequence | 0.15 | 0.25 | 0.20 |
| Success | 0.10 | 0.10 | 0.10 |

You can also override individual weights on top of any profile:

```zsh
export ZSH_SAGE_W_SEQUENCE="0.35"
export ZSH_SAGE_W_FREQUENCY="0.10"
```

Other knobs:

```zsh
export ZSH_SAGE_RECENCY_HALFLIFE=259200         # 3 days (in seconds)
export ZSH_SAGE_PREFIX_AWARE_WEIGHTS=true       # set false on very slow hardware
export ZSH_SAGE_CYCLE_COUNT=8                   # alternatives shown on Ctrl+N
export ZSH_SAGE_COLOR_HIGH=108                  # high confidence color (256-color)
export ZSH_SAGE_COLOR_MED=245                   # medium
export ZSH_SAGE_COLOR_LOW=240                   # low
export ZSH_SAGE_CONFIDENCE_HIGH=0.70            # threshold for high
export ZSH_SAGE_CONFIDENCE_LOW=0.30             # threshold for low
```

Note: profile presets are being de-emphasized as the automatic behavior improves. Future versions will rely on learned weights rather than manual profiles.

</details>

## CLI

```zsh
zsage status     # Current config, DB stats, active weights (with visual bars)
zsage ai         # Enable/disable AI commands (hm)
zsage stats      # Your top commands by frequency
zsage weights    # What zsh-sage has learned from your habits
zsage profile    # View the profile presets (for advanced tuning)
zsage version    # Show version
zsage help       # Full usage info with color reference
```

## Keybindings

| Key / Command | Action |
|---|---|
| **Right arrow** | Accept full suggestion |
| **Option+Right** / **Ctrl+Right** | Accept word-by-word |
| **Ctrl+N** | Cycle through alternatives (up to 8 ranked suggestions) |
| **Backspace** | Clear and re-suggest |
| Any typing | New suggestion appears as ghost text |
| `hm <question>` | Ask AI for a command |
| `hm` | AI suggests a fix for your last failed command |

## Scoring signals explained

**Frequency** — How many times you've run a command. Sqrt-scaled to prevent a single heavily-used command from dominating everything.

**Recency** — How recently you ran the command. Exponential decay with a 3-day half-life — a command from 3 days ago scores 0.5, from a week ago 0.2. No cliff, smooth fade.

**Directory** — Whether you run this command in the current directory. `npm test` in `~/webapp` won't be suggested in `~/infra`.

**Sequence** — What you ran before the current command. After `git add .`, the scorer boosts `git commit`. After `cd project`, it boosts commands you typically run there. When a command is the overwhelming follow-up (>60% share), it takes a fast-path override regardless of other signals.

**Success rate** — Commands that exit 0 get boosted. That typo you made 50 times before fixing it gets penalized.

### Prefix-length-aware weights

The weights aren't static — they shift based on how much you've typed:

- **Short prefix (1-3 chars)** — you're exploring, frequency matters most
- **Medium prefix (4-8 chars)** — balanced, use profile defaults
- **Long prefix (9+ chars)** — you know what you want, recency and directory matter most

This is why typing `git co` gives you your most common `git co*` command, but typing `git commit -m "f` gives you the most recent `git commit -m` variant — the system adapts to how much context you've provided.

## Architecture

```
~/.zsh-sage/
└── sage.db              # SQLite database (persists across sessions)

Keystroke
  → ZLE self-insert widget captures input
  → Single SQL query scores all candidates via coproc
  → Confidence color computed from score
  → Best match shown as colored POSTDISPLAY
  → Right arrow to accept, Ctrl+N to cycle alternatives

SQLite coproc stays alive for the session (~1MB RAM, 0% idle CPU).
No fork per keystroke — queries pipe through stdin/stdout.
Auto-respawns if the coproc dies. WAL mode for multi-tab safety.
```

## Performance

Benchmarked on Apple Silicon, 10,000 history entries:

| Operation | Latency |
|---|---|
| Full rank (query + score) | ~9ms |
| With in-memory cache hit | ~4ms |
| SQLite query alone | ~2ms |

Target was <50ms per keystroke. We hit 9ms — imperceptible for typing.

### Journey

The first three versions were pure **optimizations** — same behavior, faster. The fourth was an **algorithmic improvement** — slightly slower, significantly smarter.

| Version | Latency | Change | Type |
|---|---|---|---|
| v1 (naive) | ~500ms | Fork sqlite3 per candidate, bc per signal | baseline |
| v2 (single SQL) | ~11ms | All scoring in one SQL query | optimization (45×) |
| v3 (coproc) | ~6ms | Persistent sqlite3 process, zero fork overhead | optimization (2×) |
| v4 (prefix-aware) | ~9ms | Prefix-length-aware weights + exponential recency decay | improvement (traded 3ms for smarter ranking) |

## Dependencies

- `zsh` 5.0+
- `sqlite3` (pre-installed on macOS and most Linux)
- `python3` (only for AI mode formatting)
- `bc` (for scoring math in tests, not used in hot path)
- [Claude Code](https://claude.ai/claude-code) CLI (optional, for `hm` command)

## Uninstall

```zsh
# Remove from plugins in ~/.zshrc, then:
rm -rf ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-sage
rm -rf ~/.zsh-sage    # Remove command database
```

## License

MIT

---

Created by [Utsav](https://github.com/UtsavMandal2022) — *"Your shell should know you better than you know yourself."*
