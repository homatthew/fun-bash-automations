## GitHub CLI Host Detection
- Check `git remote -v` to determine GitHub host:
  - If remote contains `git.netflix.net` → Netflix enterprise repo
    - Use `GH_HOST=github.netflix.net gh ...` (note: git.netflix.net redirects to github.netflix.net)
  - If remote contains `github.com` → Public GitHub
    - Use regular `gh ...` commands (no GH_HOST needed)

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
