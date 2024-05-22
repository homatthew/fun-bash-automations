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

rm ~/.vimrc
ln -s ~/repos/fun-bash-automations/.vimrc ~/.vimrc

rm ~/.zshrc
ln -s ~/repos/fun-bash-automations/.zshrc ~/.zshrc