# gh-image

GitHub CLI extension that uploads images using GitHub's internal upload flow,
producing real `user-attachments` URLs identical to browser drag-and-drop.

Works on **both github.com and GitHub Enterprise Server** (git.netflix.net).

## Source

Local fork at `~/repos/gh-image`:
- **origin**: `https://git.netflix.net/matthewho/gh-image.git`
- **upstream**: `https://github.com/drogers0/gh-image.git`

Key additions over upstream:
- GHES host-awareness (auto-detects from git remote)
- GHES same-origin upload flow (not S3-based like github.com)
- GHES CSRF handling (URL-scoped tokens from `/releases/new`, `X-Fetch-Nonce`)

## Install

```bash
cd ~/repos/gh-image
make install-local
```

This builds `~/bin/gh-image`, ad-hoc codesigns it (prevents macOS from
quarantining unsigned binaries), and installs a shell wrapper as a `gh` extension.

Do **not** use `gh extension install drogers0/gh-image` — the upstream version
does not support GHES.

Do **not** use `gh extension install .` — `gh` sees `go.mod` and tries to
rebuild on every invocation, which fails and deletes the binary.

## Caveats

- Requires Chromium-family browser (Chrome, Brave, Edge) — Firefox/Safari not supported
- macOS Keychain prompt on first use is expected
- Uses undocumented GitHub internal API — could break if GitHub changes it
- `--repo` flag infers host from current git remote, so GHES users don't need `GH_HOST`

## Common usage

```bash
# Upload and capture markdown reference (infers repo + host from git remote)
IMG=$(gh image screenshot.png)

# Explicit repo
IMG=$(gh image screenshot.png --repo owner/repo)

# Post as PR comment
gh pr comment <pr-number> --body "$IMG"

# Create issue with embedded image
gh issue create --title "Bug" --body "Screenshot:

$IMG"

# Upload multiple images
IMGS=$(gh image before.png after.png)

# Upload from clipboard (macOS)
TMP=$(mktemp /tmp/screenshot.XXXX.png)
osascript -e 'tell application "System Events" to write (the clipboard as «class PNGf») to (POSIX file "'"$TMP"'")'
gh image "$TMP"
rm "$TMP"
```

## Updating

Pull from upstream, merge, test:
```bash
cd ~/repos/gh-image
git fetch upstream
git log upstream/main --oneline -5   # audit changes
git merge upstream/main
make test
make install-local
```
