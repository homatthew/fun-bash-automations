# Ghostty Terminal Title Fix

## Problem

When running Claude Code in Ghostty terminal, the tab title showed "claude" instead of useful information like the directory name and git branch.

## Root Cause

1. **Ghostty's shell integration** automatically sets the terminal title to the name of the currently running command. When running `claude`, it overrides any title set by the shell or Claude Code itself.

2. **Claude Code's `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`** environment variable is unreliable:
   - GitHub Issue #4765: Feature request for disabling terminal title
   - GitHub Issue #16572: Reports of the env var not working consistently
   - GitHub Issue #17951: Related terminal title issues

3. **Previous zsh `chpwd` hook** only set the title to the directory basename and would get overridden by Ghostty's shell integration anyway.

## Solution

### 1. Disable Ghostty's Title Override

In `ghostty/config`:
```
shell-integration-features = no-title
```

This tells Ghostty not to override terminal titles based on the running command.

### 2. Custom zsh Hooks for Title Setting

In `zsh/personal.zsh`, we use `add-zsh-hook` instead of overriding `chpwd` directly:

```zsh
function set_terminal_title() {
    local dir="${PWD##*/}"
    local branch=$(git branch --show-current 2>/dev/null)
    if [[ -n "$branch" ]]; then
        printf '\033]2;%s (%s)\007' "$dir" "$branch"
    else
        printf '\033]2;%s\007' "$dir"
    fi
}

autoload -Uz add-zsh-hook
add-zsh-hook chpwd set_terminal_title
set_terminal_title
```

This provides:
- Title format: `dirname (branch)` or just `dirname` if not in a git repo
- Updates on every directory change
- Sets correctly on shell startup
- Doesn't interfere with oh-my-zsh's `precmd` function

## Why Not Rely on Claude Code?

We chose custom zsh hooks rather than leaning on Claude Code's own title behavior
because:

1. **More control**: We can show exactly what we want (directory + git branch)
2. **Reliability**: Works regardless of Claude Code's behavior
3. **Consistency**: Same title format whether or not Claude is running
4. **Future-proof**: Not dependent on Claude Code's implementation details

Note that the hook alone is enough to get those four properties in plain shell
panes. `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` was additionally set to keep
Claude Code from taking the title over during a run; that is now removed, see
below.

## Related GitHub Issues

- https://github.com/anthropics/claude-code/issues/4765 - Terminal title feature request
- https://github.com/anthropics/claude-code/issues/16572 - CLAUDE_CODE_DISABLE_TERMINAL_TITLE issues
- https://github.com/anthropics/claude-code/issues/17951 - Additional terminal title problems

## Removed: CLAUDE_CODE_DISABLE_TERMINAL_TITLE (2026-07-30)

`export CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` is gone from `personal.zsh`. Do not
add it back. It broke Herdr's agent-state detection: every Claude pane reported
`done` while actively working, so the sidebar was useless for knowing which
agents needed attention.

Herdr's claude detection manifest
(`~/.local/state/herdr/agent-detection/remote/claude.toml`) has exactly one
general-purpose `working` rule, `osc_title_working`: a braille-spinner regex
(`^[\x{2800}-\x{28FF}] `) over the OSC title. With titles suppressed that region
is empty, so the highest-priority rule that can still match is
`live_prompt_box` (priority 950, state `idle`) — and Claude Code keeps the `❯`
prompt box rendered while working, for type-ahead. Result: every Claude pane
latched to `idle`, which Herdr renders as `done` for unseen background work.
`blocked` still worked, because its rules are text-based.

The original Root Cause above is what makes removal safe: Ghostty's
`shell-integration-features = no-title` is what actually stops title clobbering.
The env var only enforced a preference on top of that, and it is not needed for
any of the four properties listed under "Why Not Rely on Claude Code?" — the
`chpwd` hook still owns the title in plain shell panes.

What changes: while Claude Code is running, that pane's terminal title is Claude's
status string (`✳ Claude Code` idle, `⠂ Claude Code` working) instead of
`dirname (branch)`. Herdr tab labels come from its own `label` field, so the
Herdr sidebar is unaffected.

Diagnose regressions with `herdr agent explain <pane> --verbose` and look for
`region: bytes=0` on `osc_title`.

Note that the env var *is* reliable, contrary to the Root Cause note above — it
worked here, which is precisely the problem.

## Verification

1. Run `source ~/.zshrc` to reload shell config.
2. Restart Ghostty (needed for config changes).
3. `cd` into a git repo and verify a shell pane shows `dirname (branch)`.
4. Run `claude` and verify its title changes between idle and working status.
5. Inside Herdr, start a fresh `claude` pane, send it work, and confirm
   `herdr agent list` reports `working` rather than `idle`
