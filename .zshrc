# Main zshrc - sources personal and Netflix-specific configurations
#
# Setup (run once):
#   ./setupPermissions.sh
#
# This will:
# - Create symlinks for ~/.zshrc, ~/.vimrc, ~/.ideavimrc
# - Create symlinks for ~/.zsh/personal.zsh and ~/.zsh/netflix.zsh
# - Download git completion scripts to ~/.zsh/

# Source personal configurations
[ -f ~/.zsh/personal.zsh ] && source ~/.zsh/personal.zsh

# Source Netflix-specific configurations (if exists)
# This allows the same setup to work on non-Netflix machines
[ -f ~/.zsh/netflix.zsh ] && source ~/.zsh/netflix.zsh

# Mac OS specific settings (run manually if needed)
# defaults write -g com.apple.trackpad.scaling -float 5.0
# defaults write .GlobalPreferences com.apple.mouse.scaling -1
# defaults write -g ApplePressAndHoldEnabled -bool false

fpath+=~/.zfunc; autoload -Uz compinit; compinit

zstyle ':completion:*' menu select
