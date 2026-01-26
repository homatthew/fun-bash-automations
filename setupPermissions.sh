#!/bin/bash
# Setup script for zsh configuration
# Run this once to set up symlinks and install dependencies

set -e

echo "=============================================="
echo "Setting up zsh environment..."
echo "=============================================="

# ==============================================================================
# Helper functions for symlink protection
# ==============================================================================
# Unlock a symlink (remove immutable flag) - silently succeeds if file doesn't exist
unlock_symlink() {
	[ -L "$1" ] && chflags -h nouchg "$1" 2>/dev/null || true
}

# Lock a symlink (set immutable flag) - prevents accidental deletion/replacement
lock_symlink() {
	[ -L "$1" ] && chflags -h uchg "$1"
}

# Track locked symlinks for summary
LOCKED_SYMLINKS=()

# Set executable permissions
paths=(
	"rebase-all-branches/rebaseAllBranches.sh"
	"rp/rp-completion.sh"
	"rp/rp.sh"
	"ghe-cli/ghe"
	"ghe-cli/ghe-fix-proxy"
)

for path in ${paths[@]}
do
	chmod +x "$path"
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
	if [ ! -f /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]; then
		echo "Installing zsh-autosuggestions..."
		brew install zsh-autosuggestions
		echo "✓ zsh-autosuggestions installed"
	else
		echo "✓ zsh-autosuggestions already installed"
	fi

	# zsh-syntax-highlighting
	if [ ! -f /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]; then
		echo "Installing zsh-syntax-highlighting..."
		brew install zsh-syntax-highlighting
		echo "✓ zsh-syntax-highlighting installed"
	else
		echo "✓ zsh-syntax-highlighting already installed"
	fi

	# terminal-notifier - for Claude Code completion notifications
	if ! command -v terminal-notifier &> /dev/null; then
		echo "Installing terminal-notifier..."
		brew install terminal-notifier
		echo "✓ terminal-notifier installed"
	else
		echo "✓ terminal-notifier already installed"
	fi
else
	echo "⚠ Homebrew not found. Skipping package installation."
	echo "  Install Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
fi

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
ln -s ~/repos/fun-bash-automations/.vimrc ~/.vimrc

rm -f ~/.zshrc
ln -s ~/repos/fun-bash-automations/.zshrc ~/.zshrc

rm -f ~/.ideavimrc
ln -s ~/.vimrc ~/.ideavimrc

# Create symlinks for zsh config files
echo "Setting up zsh config symlinks..."
rm -f ~/.zsh/personal.zsh
ln -s ~/repos/fun-bash-automations/zsh/personal.zsh ~/.zsh/personal.zsh
echo "✓ personal.zsh symlinked"

rm -f ~/.zsh/netflix.zsh
ln -s ~/repos/fun-bash-automations/zsh/netflix.zsh ~/.zsh/netflix.zsh
echo "✓ netflix.zsh symlinked"

# ==============================================================================
# Ghostty Configuration
# ==============================================================================
echo ""
echo "Setting up Ghostty configuration..."
mkdir -p ~/.config/ghostty
rm -f ~/.config/ghostty/config
ln -s ~/repos/fun-bash-automations/ghostty/config ~/.config/ghostty/config
echo "✓ Ghostty config symlinked"

# ==============================================================================
# Claude Code Configuration
# ==============================================================================
echo ""
echo "Setting up Claude Code configuration..."

# Create ~/.claude directory structure if it doesn't exist
mkdir -p ~/.claude/agents ~/.claude/skills

# Symlink CLAUDE.md (NOT protected - Claude writes to this file)
rm -f ~/.claude/CLAUDE.md
ln -s ~/repos/fun-bash-automations/claude/CLAUDE.md ~/.claude/CLAUDE.md
echo "✓ CLAUDE.md symlinked"

# Symlink settings.json (NOT protected - Claude writes to this file)
rm -f ~/.claude/settings.json
ln -s ~/repos/fun-bash-automations/claude/settings.json ~/.claude/settings.json
echo "✓ settings.json symlinked"

# Symlink agents (individual files, protected)
for agent in ~/repos/fun-bash-automations/claude/agents/*.md; do
	name=$(basename "$agent")
	unlock_symlink ~/.claude/agents/"$name"
	rm -f ~/.claude/agents/"$name"
	ln -s "$agent" ~/.claude/agents/"$name"
	lock_symlink ~/.claude/agents/"$name"
	LOCKED_SYMLINKS+=("~/.claude/agents/$name")
done
echo "✓ agents symlinked (protected)"

# Symlink skills (directories, protected)
for skill in ~/repos/fun-bash-automations/claude/skills/*/; do
	name=$(basename "$skill")
	unlock_symlink ~/.claude/skills/"$name"
	rm -rf ~/.claude/skills/"$name"
	ln -s "$skill" ~/.claude/skills/"$name"
	lock_symlink ~/.claude/skills/"$name"
	LOCKED_SYMLINKS+=("~/.claude/skills/$name")
done
echo "✓ skills symlinked (protected)"

# ==============================================================================
# ghe-cli Installation (Netflix GitHub Enterprise CLI wrapper)
# ==============================================================================
echo ""
echo "Setting up ghe-cli..."

# Initialize ghe-cli submodule if needed
if [ ! -f ~/repos/fun-bash-automations/ghe-cli/ghe ]; then
	echo "Initializing ghe-cli submodule..."
	git -C ~/repos/fun-bash-automations submodule update --init --recursive
fi

# Create ~/.local/bin if it doesn't exist
mkdir -p ~/.local/bin

# Symlink ghe scripts
rm -f ~/.local/bin/ghe
ln -s ~/repos/fun-bash-automations/ghe-cli/ghe ~/.local/bin/ghe
echo "✓ ghe symlinked to ~/.local/bin/ghe"

rm -f ~/.local/bin/ghe-fix-proxy
ln -s ~/repos/fun-bash-automations/ghe-cli/ghe-fix-proxy ~/.local/bin/ghe-fix-proxy
echo "✓ ghe-fix-proxy symlinked to ~/.local/bin/ghe-fix-proxy"

# Remind about PATH
if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
	echo ""
	echo "⚠ Note: ~/.local/bin may not be in your PATH"
	echo "  Add this to your ~/.zshrc if not present:"
	echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

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
printf '  %s\n' "${LOCKED_SYMLINKS[@]}"
echo ""
echo "  To temporarily unlock: chflags -h nouchg <path>"
echo "  Re-run this script to re-lock after changes"
echo ""
echo "Run 'source ~/.zshrc' to reload configuration."
