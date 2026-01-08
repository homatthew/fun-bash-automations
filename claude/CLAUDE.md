## GitHub CLI Usage
- For Netflix GitHub Enterprise repos (github.netflix.net / git.netflix.net):
  - Use `ghe` instead of `gh` - it handles GH_HOST and URL transformations automatically
  - Examples:
    - `ghe pr list` - auto-detects repo from git remote
    - `ghe pr view 123` - works without -R flag when in repo
    - `ghe api repos/corp/repo-name/pulls` - auto-sets GH_HOST
    - `ghe search code "pattern" --repo corp/repo-name`
  - Run `ghe-fix-proxy` once per repo to fix git proxy config for `gh` compatibility
  - Note: `ghe pr checkout` doesn't work due to Netflix Git Proxy; use git fetch workaround
- For public GitHub (github.com):
  - Use regular `gh` commands (no special handling needed)

## Multi-Repo Workflow
- All repositories live in `~/repos/*`
- Use the `cross-repo-context` agent when you need patterns from other repos
- When referencing code from another repo, use full paths: `~/repos/<repo-name>/path/to/file`
- Common cross-repo scenarios:
  - Finding similar implementations
  - Checking how other services handle auth, errors, configs
  - Copying patterns for consistency across projects

## Plan Mode Preference
- I prefer to use plan mode for non-trivial changes
- Always persist plans to `.claude/plans/<feature-name>.md`
- Consult the plan file when resuming work
