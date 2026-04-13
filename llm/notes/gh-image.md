# gh-image

GitHub CLI extension that uploads images using GitHub's internal upload flow,
producing real `user-attachments` URLs identical to browser drag-and-drop.

Repo: https://github.com/drogers0/gh-image

## Installed version

- **Tag**: `v0.1.0` (published 2026-03-27, commit `2603d2df`)
- **Pinned**: yes — `gh extension upgrade` will not auto-update

Install command used:
```bash
gh extension install drogers0/gh-image --pin v0.1.0
```

## Safe upgrade process

Before upgrading, audit what changed:
```bash
gh api repos/drogers0/gh-image/compare/v0.1.0...main \
  --jq '.commits[].commit.message'
```

If the diff looks clean, upgrade:
```bash
gh extension upgrade gh-image
```

## Caveats

- Requires Chromium-family browser (Chrome, Brave, Edge) — Firefox/Safari not supported
- macOS Keychain prompt on first use is expected
- Uses undocumented GitHub internal API — could break if GitHub changes it
- Needs `--repo owner/repo` when run outside a git workspace

## Common usage

```bash
# Upload and capture markdown reference
IMG=$(gh image screenshot.png --repo owner/repo)

# Post as PR comment
gh pr comment <pr-number> --repo owner/repo --body "$IMG"

# Create issue with embedded image
gh issue create --repo owner/repo \
  --title "Bug: visual regression" \
  --body "Here's what I see:

$IMG"

# Upload multiple images
IMGS=$(gh image before.png after.png --repo owner/repo)
gh pr comment <pr-number> --body "**Before / After:**

$IMGS"

# Upload from clipboard (macOS)
TMP=$(mktemp /tmp/screenshot.XXXX.png)
osascript -e 'tell application "System Events" to write (the clipboard as «class PNGf») to (POSIX file "'"$TMP"'")'
gh image "$TMP" --repo owner/repo
rm "$TMP"
```
