paths=(
	"build-scripts/gobblin-snap.sh"
	"rebase-all-branches/rebaseAllBranches.sh"
	"review-board/rb_create.sh"
	"rp/rp-completion.sh"
	"rp/rp.sh"
)

for path in ${paths[@]}
do
	chmod +x "$path"
done