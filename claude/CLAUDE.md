## GitHub CLI Usage
- For Netflix GitHub Enterprise repos (github.netflix.net / git.netflix.net):
  - **First, fix the proxy** (required once per repo before any gh commands):
    ```bash
    ghe-fix-proxy /full/path/to/repo --verify
    ```
  - Then use regular `gh` commands:
    - `gh pr list` - auto-detects repo from git remote
    - `gh pr view 123` - works without -R flag when in repo
    - `gh api repos/corp/repo-name/pulls` - works after proxy fix
  - **Reset when done** (restores config for other tools):
    ```bash
    ghe-fix-proxy --reset
    ```
  - Note: `gh pr checkout` doesn't work due to Netflix Git Proxy; use git fetch workaround
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
