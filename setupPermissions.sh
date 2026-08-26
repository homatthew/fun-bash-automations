#!/bin/bash
# Setup script for zsh configuration
# Run this once to set up symlinks and install dependencies.
# Cross-platform: macOS (Homebrew) + Linux (Homebrew or apt/dnf).

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$ROOT_DIR/scripts/check-push-safety.sh"

echo "=============================================="
echo "Setting up zsh environment..."
echo "=============================================="

# ==============================================================================
# OS detection + portable brew prefix
# ==============================================================================
OS="$(uname -s)"
IS_MAC=false
IS_LINUX=false
case "$OS" in
	Darwin) IS_MAC=true ;;
	Linux)  IS_LINUX=true ;;
esac

# Resolve Homebrew prefix (differs per platform / CPU). Falls back to
# likely candidates if `brew --prefix` isn't available.
if command -v brew &> /dev/null; then
	BREW_PREFIX="$(brew --prefix)"
elif [ -d /opt/homebrew ]; then
	BREW_PREFIX=/opt/homebrew
elif [ -d /home/linuxbrew/.linuxbrew ]; then
	BREW_PREFIX=/home/linuxbrew/.linuxbrew
elif [ -d /usr/local/Homebrew ]; then
	BREW_PREFIX=/usr/local
else
	BREW_PREFIX=""
fi

# ==============================================================================
# Helper functions for symlink protection (macOS only)
# ==============================================================================
# macOS has `chflags uchg` which makes a symlink immutable at the VFS layer.
# Linux has no direct equivalent for symlinks (chattr +i doesn't apply), so
# lock/unlock become no-ops there. Agents already treat lock as best-effort.
unlock_symlink() {
	if $IS_MAC && [ -L "$1" ]; then
		chflags -h nouchg "$1" 2>/dev/null || true
	fi
}

lock_symlink() {
	if $IS_MAC && [ -L "$1" ]; then
		chflags -h uchg "$1"
	fi
}

# Track locked symlinks for summary
LOCKED_SYMLINKS=()

# Set executable permissions
paths=(
	"rp/rp-completion.sh"
	"rp/rp.sh"
)

for path in "${paths[@]}"
do
	chmod +x "$ROOT_DIR/$path"
done

# ==============================================================================
# Oh My Zsh Installation
# ==============================================================================
echo ""
echo "Checking Oh My Zsh..."
if [ ! -d "$HOME/.oh-my-zsh" ]; then
	echo "Installing Oh My Zsh..."
	# --unattended: don't try to change the default shell
	# --keep-zshrc: don't overwrite ~/.zshrc (we use our own symlinked version)
	KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
	echo "✓ Oh My Zsh installed"
else
	echo "✓ Oh My Zsh already installed"
fi

# ==============================================================================
# Homebrew packages for enhanced shell experience
# ==============================================================================
echo ""
echo "Checking Homebrew packages..."
if command -v brew &> /dev/null; then
	# fzf - fuzzy finder
	if ! command -v fzf &> /dev/null; then
		echo "Installing fzf..."
		brew install fzf
		# Install fzf key bindings and completion
		$(brew --prefix)/opt/fzf/install --key-bindings --completion --no-update-rc --no-bash --no-fish
		echo "✓ fzf installed"
	else
		echo "✓ fzf already installed"
	fi

	# fd - faster find alternative (used by fzf)
	if ! command -v fd &> /dev/null; then
		echo "Installing fd..."
		brew install fd
		echo "✓ fd installed"
	else
		echo "✓ fd already installed"
	fi

	# zsh-autosuggestions - fish-like suggestions
	if [ ! -f "$BREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh" ]; then
		echo "Installing zsh-autosuggestions..."
		brew install zsh-autosuggestions
		echo "✓ zsh-autosuggestions installed"
	else
		echo "✓ zsh-autosuggestions already installed"
	fi

	# zsh-syntax-highlighting
	if [ ! -f "$BREW_PREFIX/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]; then
		echo "Installing zsh-syntax-highlighting..."
		brew install zsh-syntax-highlighting
		echo "✓ zsh-syntax-highlighting installed"
	else
		echo "✓ zsh-syntax-highlighting already installed"
	fi

	# jq - JSON processor, used pervasively by hooks and the no-mistakes gate
	if ! command -v jq &> /dev/null; then
		echo "Installing jq..."
		brew install jq
		echo "✓ jq installed"
	else
		echo "✓ jq already installed"
	fi

	# yq (mikefarah) - YAML processor; used for hook/config YAML (e.g. .no-mistakes.yaml)
	if ! command -v yq &> /dev/null; then
		echo "Installing yq..."
		brew install yq
		echo "✓ yq installed"
	else
		echo "✓ yq already installed"
	fi

	# gh - GitHub CLI, used for PR lookup and the code-review skill
	if ! command -v gh &> /dev/null; then
		echo "Installing gh..."
		brew install gh
		echo "✓ gh installed"
	else
		echo "✓ gh already installed"
	fi

	# sqlite3 ships with macOS; beads (bd) uses it for the local issue DB.
	# Verify it's reachable and warn if not.
	if ! command -v sqlite3 &> /dev/null; then
		echo "⚠ sqlite3 not found on PATH — beads (bd) local issue DB will be unavailable."
		echo "  macOS usually ships sqlite3 at /usr/bin/sqlite3; check your PATH."
	else
		echo "✓ sqlite3 available ($(command -v sqlite3))"
	fi
else
	echo "⚠ Homebrew not found. Skipping package installation."
	echo "  Install Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
fi

bash "$ROOT_DIR/scripts/setup-desktop-notifications.sh"

# ==============================================================================
# Git completion scripts
# ==============================================================================
echo ""
echo "Setting up git completion..."
mkdir -p ~/.zsh

# Download git-completion.bash if it doesn't exist or is outdated
if [ ! -f ~/.zsh/git-completion.bash ]; then
	echo "Downloading git-completion.bash..."
	curl -fsSL https://raw.githubusercontent.com/git/git/master/contrib/completion/git-completion.bash -o ~/.zsh/git-completion.bash
	if [ $? -eq 0 ]; then
		echo "✓ git-completion.bash installed successfully"
	else
		echo "✗ Failed to download git-completion.bash"
	fi
else
	echo "✓ git-completion.bash already exists"
fi

# Download git-completion.zsh (_git wrapper) if it doesn't exist or is outdated
if [ ! -f ~/.zsh/_git ]; then
	echo "Downloading _git (zsh wrapper)..."
	curl -fsSL https://raw.githubusercontent.com/git/git/master/contrib/completion/git-completion.zsh -o ~/.zsh/_git
	if [ $? -eq 0 ]; then
		echo "✓ _git installed successfully"
	else
		echo "✗ Failed to download _git"
	fi
else
	echo "✓ _git already exists"
fi

# Create symlinks for dotfiles
rm -f ~/.vimrc
ln -s "$ROOT_DIR/.vimrc" ~/.vimrc

rm -f ~/.zshrc
ln -s "$ROOT_DIR/.zshrc" ~/.zshrc

rm -f ~/.ideavimrc
ln -s ~/.vimrc ~/.ideavimrc

# Create symlinks for zsh config files
echo "Setting up zsh config symlinks..."
rm -f ~/.zsh/personal.zsh
ln -s "$ROOT_DIR/zsh/personal.zsh" ~/.zsh/personal.zsh
echo "✓ personal.zsh symlinked"

# ==============================================================================
# Ghostty Configuration
# ==============================================================================
echo ""
echo "Setting up Ghostty configuration..."
mkdir -p ~/.config/ghostty
rm -f ~/.config/ghostty/config
ln -s "$ROOT_DIR/ghostty/config" ~/.config/ghostty/config
echo "✓ Ghostty config symlinked"

# ==============================================================================
# VS Code OSC notifier fork
# ==============================================================================
# The notify hooks drive a forked VS Code extension that binds an OSC 777
# `tid` to the emitting terminal so banner clicks focus the right tab.
# fba-deploy -> bin/install-osc-notifier handles build + install, but we
# need the clone + vsce + node on PATH before that runs.
if $IS_MAC && [ -n "${OSC_NOTIFIER_REPO_URL:-}" ] && [ -n "${OSC_NOTIFIER_PUBLISHER:-}" ]; then
	echo ""
	echo "Checking configured VS Code OSC notifier..."

	if command -v brew &> /dev/null && ! command -v node &> /dev/null; then
		echo "Installing node (required for VS Code extension build)..."
		brew install node
		echo "✓ node installed"
	fi

	if command -v npm &> /dev/null; then
		if ! npm ls -g --depth=0 @vscode/vsce >/dev/null 2>&1; then
			echo "Installing @vscode/vsce globally..."
			npm install -g @vscode/vsce
			echo "✓ @vscode/vsce installed"
		else
			echo "✓ @vscode/vsce already installed"
		fi
	else
		echo "⚠ npm not found; VS Code extension build will be skipped"
	fi

	OSC_NOTIFIER_REPO_DIR="${OSC_NOTIFIER_REPO_DIR:-$HOME/repos/vscode-terminal-osc-notifier}"
	if [ ! -d "$OSC_NOTIFIER_REPO_DIR" ]; then
		echo "Cloning configured OSC notifier..."
		git clone "$OSC_NOTIFIER_REPO_URL" "$OSC_NOTIFIER_REPO_DIR"
		echo "✓ notifier cloned"
	else
		echo "✓ notifier already cloned at $OSC_NOTIFIER_REPO_DIR"
	fi
fi

# ==============================================================================
# Claude + Codex Configuration
# ==============================================================================
echo ""
echo "Setting up shared LLM configuration..."

# Use the canonical projection path so setupPermissions stays aligned with
# dotfiles installers and the portable LLM config model.
"$ROOT_DIR/bin/fba-deploy"
echo "✓ repo-owned Claude/Codex runtime files projected"

# Re-lock selected symlinks after projection for local safety.
lock_symlink ~/.claude/CLAUDE.md
LOCKED_SYMLINKS+=("~/.claude/CLAUDE.md")
lock_symlink ~/.claude/AGENTS.md
LOCKED_SYMLINKS+=("~/.claude/AGENTS.md")
lock_symlink ~/.codex/AGENTS.md
LOCKED_SYMLINKS+=("~/.codex/AGENTS.md")

for agent in ~/.claude/agents/*.md; do
	[ -L "$agent" ] || continue
	lock_symlink "$agent"
	LOCKED_SYMLINKS+=("~/.claude/agents/$(basename "$agent")")
done
echo "✓ Claude agents symlinked (protected)"

for skill in ~/.claude/skills/*; do
	[ -L "$skill" ] || continue
	lock_symlink "$skill"
	LOCKED_SYMLINKS+=("~/.claude/skills/$(basename "$skill")")
done
echo "✓ shared skills symlinked to ~/.claude/skills (protected)"

for skill in ~/.codex/skills/*; do
	[ -L "$skill" ] || continue
	lock_symlink "$skill"
	LOCKED_SYMLINKS+=("~/.codex/skills/$(basename "$skill")")
done
echo "✓ shared skills symlinked to ~/.codex/skills (protected)"

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "=============================================="
echo "Setup complete!"
echo "=============================================="
echo ""
echo "Key bindings available:"
echo "  Ctrl+R     - Fuzzy history search (fzf)"
echo "  Ctrl+T     - Fuzzy file search"
echo "  Alt+C      - Fuzzy directory change"
echo "  Up/Down    - History search (after typing partial command)"
echo "  Ctrl+Space - Accept autosuggestion"
echo "  Option+←/→ - Word navigation"
echo "  z <dir>    - Jump to frequently used directory"
echo ""
echo "Protected symlinks (immutable, cannot be accidentally overwritten):"
if $IS_MAC; then
	printf '  %s\n' "${LOCKED_SYMLINKS[@]}"
	echo ""
	echo "  To temporarily unlock: chflags -h nouchg <path>"
	echo "  Re-run this script to re-lock after changes"
else
	echo "  (symlink locking only applies on macOS)"
fi
echo ""
if $IS_MAC && [ -n "${OSC_NOTIFIER_REPO_URL:-}" ] && [ -n "${OSC_NOTIFIER_PUBLISHER:-}" ]; then
	echo "VS Code extension:"
	echo "  ${OSC_NOTIFIER_PUBLISHER}.${OSC_NOTIFIER_NAME:-vscode-terminal-osc-notifier} (source: ${OSC_NOTIFIER_REPO_DIR:-$HOME/repos/vscode-terminal-osc-notifier})"
	echo "  Installed by fba-deploy → bin/install-osc-notifier."
	echo ""
fi
echo "Run 'source ~/.zshrc' to reload configuration."
