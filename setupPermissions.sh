paths=(
	"build-scripts/gobblin-snap.sh"
	"rebase-all-branches/rebaseAllBranches.sh"
	"rp/rp-completion.sh"
	"rp/rp.sh"
)

for path in ${paths[@]}
do
	chmod +x "$path"
done

# Install git completion scripts
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
