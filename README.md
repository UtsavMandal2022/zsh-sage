# zsh-sage

A drop-in replacement for [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions) with intelligent, multi-signal ranking and confidence-colored ghost text.

While zsh-autosuggestions suggests the most recent history match, zsh-sage scores every candidate across **5 signals** — frequency, recency, directory context, command sequences, and success rate — to surface the suggestion you actually want.

## How it works

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
            ~~~~~~~~~~~~~~~~~~~~~~  (colored ghost text)
```

Press **right arrow** to accept, **Ctrl+Right** to accept word-by-word.

## Why switch from zsh-autosuggestions?

| Feature | zsh-autosuggestions | zsh-sage |
|---|---|---|
| Ranking | Most recent match | Multi-signal scoring |
| Directory awareness | No | Yes — different dirs, different suggestions |
| Sequence awareness | No | Yes — `git add .` → suggests `git commit` |
| Failed command penalty | No | Yes — typos and failures get demoted |
| Recency decay | No (just most recent) | Yes — linear decay over 7 days |
| Confidence colors | No — fixed grey | Yes — color reflects score confidence |
| AI fallback | No | Optional — Anthropic Haiku for novel commands |
| Configurable weights | No | Yes — presets + per-weight tuning |
| Performance | ~0.01ms (in-memory) | ~6ms (SQLite coproc, indexed) |

## Confidence colors

Ghost text color reflects how confident the scorer is about the suggestion:

| Confidence | Color | Meaning |
|---|---|---|
| High (> 0.7) | Sage green | "I'm sure about this" |
| Medium (0.3 - 0.7) | Grey | "Decent guess" |
| Low (< 0.3) | Faint grey | "This is a stretch" |

You'll subconsciously learn to trust bright suggestions and be more skeptical of faint ones.

Customize colors and thresholds in `~/.zshrc`:

```zsh
export ZSH_SAGE_COLOR_HIGH=108          # sage green (256-color)
export ZSH_SAGE_COLOR_MED=245           # medium grey
export ZSH_SAGE_COLOR_LOW=240           # faint grey
export ZSH_SAGE_CONFIDENCE_HIGH=0.70    # threshold for high
export ZSH_SAGE_CONFIDENCE_LOW=0.30     # threshold for low
```

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
zsh -c 'source /path/to/zsh-sage/zsh-sage.plugin.zsh && _sage_db_import_history'
```

This seeds the database with your past commands. Sequence data (what follows what) builds up automatically as you use the shell.

## Configuration

### Profiles

Choose a suggestion style with one line in `~/.zshrc`:

```zsh
export ZSH_SAGE_PROFILE="default"
```

| Profile | Style | Best for |
|---|---|---|
| `default` | Balanced, frequency-driven | Most users |
| `contextual` | Directory + sequence heavy | Devs working across many projects |
| `recent` | Recency-dominant | Rapidly changing workflows |

<details>
<summary>Profile weight details</summary>

| Signal | default | contextual | recent |
|---|---|---|---|
| Frequency | 0.30 | 0.15 | 0.15 |
| Recency | 0.25 | 0.20 | 0.40 |
| Directory | 0.20 | 0.30 | 0.15 |
| Sequence | 0.15 | 0.25 | 0.20 |
| Success | 0.10 | 0.10 | 0.10 |

</details>

### Fine-tuning weights

Override individual weights on top of any profile:

```zsh
export ZSH_SAGE_PROFILE="contextual"
export ZSH_SAGE_W_SEQUENCE="0.35"    # Boost sequence signal
export ZSH_SAGE_W_FREQUENCY="0.10"   # Downplay frequency
```

### AI suggestions (optional)

Enable AI-powered suggestions for commands not in your history. Uses Anthropic's Haiku model (BYOK) — fast and cheap (~$0.01/day for heavy usage).

```zsh
export ZSH_SAGE_AI_ENABLED=true
export ZSH_SAGE_API_KEY="sk-your-anthropic-key"
```

AI suggestions fire asynchronously only when the local scorer has no good match. The ghost text UX is identical — you won't know whether a suggestion came from history or AI. AI suggestions appear with medium confidence color.

## CLI

```zsh
zsage status     # Current config, DB stats, active weights (with visual bars)
zsage profile    # View available profiles with weight breakdowns
zsage stats      # Your top commands by frequency
zsage version    # Show version
zsage help       # Full usage info with color reference
```

## Keybindings

| Key | Action |
|---|---|
| **Right arrow** | Accept full suggestion |
| **Ctrl+Right** | Accept word-by-word |
| **Backspace** | Clear and re-suggest |
| Any typing | New suggestion appears as ghost text |

## Scoring signals explained

**Frequency** — How many times you've run a command. Sqrt-scaled to prevent a single heavily-used command from dominating everything.

**Recency** — How recently you ran the command. Linear decay over 7 days — a command from yesterday scores higher than one from last month.

**Directory** — Whether you run this command in the current directory. `npm test` in `~/webapp` won't be suggested in `~/infra`.

**Sequence** — What you ran before the current command. After `git add .`, the scorer boosts `git commit`. After `cd project`, it boosts commands you typically run there.

**Success rate** — Commands that exit 0 get boosted. That typo you made 50 times before fixing it gets penalized.

## Architecture

```
~/.zsh-sage/
└── sage.db              # SQLite database (persists across sessions)

Keystroke
  → ZLE self-insert widget captures input
  → Single SQL query scores all candidates via coproc
  → Confidence color computed from score
  → Best match shown as colored POSTDISPLAY
  → Right arrow to accept

SQLite coproc stays alive for the session (~1MB RAM, 0% idle CPU).
No fork per keystroke — queries pipe through stdin/stdout.
Auto-respawns if the coproc dies. WAL mode for multi-tab safety.
```

## Performance

Benchmarked on Apple Silicon, 10,000 history entries:

| Operation | Latency |
|---|---|
| Full rank (query + score) | 6ms |
| With in-memory cache hit | 3ms |
| SQLite query alone | 1.8ms |

Target was <50ms per keystroke. We hit 6ms.

### Optimization journey

| Version | Latency | Technique |
|---|---|---|
| v1 (naive) | ~500ms | Fork sqlite3 per candidate, bc per signal |
| v2 (single SQL) | ~11ms | All scoring in one SQL query |
| v3 (coproc) | ~6ms | Persistent sqlite3 process, zero fork overhead |

## Dependencies

- `zsh` 5.0+
- `sqlite3` (pre-installed on macOS and most Linux)
- `python3` (only for AI mode JSON handling)
- `bc` (for scoring math in tests, not used in hot path)

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
