#!/usr/bin/env bash
#
# zsh-sage installer
#

set -euo pipefail

SAGE_HOME="$HOME/.zsh-sage"
PLUGIN_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-sage"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== zsh-sage installer ==="
echo ""

# Check dependencies
echo "Checking dependencies..."

if ! command -v sqlite3 &>/dev/null; then
    echo "ERROR: sqlite3 is required but not found."
    echo "  macOS: it should be pre-installed"
    echo "  Linux: sudo apt install sqlite3"
    exit 1
fi

echo "  sqlite3 ✓"
echo ""

# Create data directory
echo "Creating data directory at $SAGE_HOME..."
mkdir -p "$SAGE_HOME"

# Symlink or copy plugin into oh-my-zsh custom plugins
if [[ -d "$HOME/.oh-my-zsh" ]]; then
    echo "Detected oh-my-zsh. Installing as custom plugin..."
    mkdir -p "$(dirname "$PLUGIN_DIR")"

    if [[ -L "$PLUGIN_DIR" ]]; then
        rm "$PLUGIN_DIR"
    fi

    ln -sf "$SCRIPT_DIR" "$PLUGIN_DIR"
    echo "  Symlinked $SCRIPT_DIR -> $PLUGIN_DIR"
    echo ""
    echo "Add 'zsh-sage' to your plugins in ~/.zshrc:"
    echo '  plugins=(git zsh-sage)'
else
    echo "oh-my-zsh not found. Add this to your ~/.zshrc:"
    echo "  source $SCRIPT_DIR/zsh-sage.plugin.zsh"
fi

echo ""

# Offer to import existing history
read -p "Import existing zsh history into zsh-sage? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Importing... (this may take a moment)"
    zsh -c "source $SCRIPT_DIR/zsh-sage.plugin.zsh && _sage_db_import_history"
    echo "Done!"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "Optional: Enable AI commands (requires Claude Code CLI):"
echo '  zsage ai'
echo ""
echo "Restart your shell or run: source ~/.zshrc"
