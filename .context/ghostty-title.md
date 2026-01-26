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

While Claude Code has `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`, we chose custom zsh hooks because:

1. **More control**: We can show exactly what we want (directory + git branch)
2. **Reliability**: Works regardless of Claude Code's behavior
3. **Consistency**: Same title format whether or not Claude is running
4. **Future-proof**: Not dependent on Claude Code's implementation details

## Related GitHub Issues

- https://github.com/anthropics/claude-code/issues/4765 - Terminal title feature request
- https://github.com/anthropics/claude-code/issues/16572 - CLAUDE_CODE_DISABLE_TERMINAL_TITLE issues
- https://github.com/anthropics/claude-code/issues/17951 - Additional terminal title problems

## Verification

1. Run `source ~/.zshrc` to reload shell config
2. Restart Ghostty (needed for config changes)
3. `cd` into a git repo and verify title shows `dirname (branch)`
4. Run `claude` and verify the title persists (not overwritten to "claude")
