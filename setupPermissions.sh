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

rm ~/.vimrc
ln -s ~/repos/fun-bash-automations/.vimrc ~/.vimrc

rm ~/.zshrc
ln -s ~/repos/fun-bash-automations/.zshrc ~/.zshrc

rm ~/.ideavimrc
ln -s ~/.vimrc ~/.ideavimrc
