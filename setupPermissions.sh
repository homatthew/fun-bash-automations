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
ln -s .vimrc ~/.vimrc

rm ~/.zshrc
ln -s .zshrc ~/.zshrc