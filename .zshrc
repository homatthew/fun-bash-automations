# Main zshrc - sources portable and machine-local configurations
#
# Setup (run once):
#   ./setupPermissions.sh
#
# This will:
# - Create symlinks for ~/.zshrc, ~/.vimrc, ~/.ideavimrc
# - Create a symlink for ~/.zsh/personal.zsh
# - Download git completion scripts to ~/.zsh/

# Source personal configurations
[ -f ~/.zsh/personal.zsh ] && source ~/.zsh/personal.zsh

# Source an optional private or machine-specific overlay.
[ -f ~/.zsh/local.zsh ] && source ~/.zsh/local.zsh

# Mac OS specific settings (run manually if needed)
# defaults write -g com.apple.trackpad.scaling -float 5.0
# defaults write .GlobalPreferences com.apple.mouse.scaling -1
# defaults write -g ApplePressAndHoldEnabled -bool false

fpath+=~/.zfunc; autoload -Uz compinit; compinit

zstyle ':completion:*' menu select

# bun completions
[ -s "${BUN_INSTALL:-$HOME/.bun}/_bun" ] && source "${BUN_INSTALL:-$HOME/.bun}/_bun"
