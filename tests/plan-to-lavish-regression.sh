#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t fba-plan-lavish-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cat > "$TMP/plan.md" <<'MD'
# Link safety

[safe](https://example.com/docs?a=1&b=2)
[relative](docs/guide.md)
[script](javascript:alert)
[quoted](https://example.com/" onmouseover="alert)
MD

(
  cd "$TMP"
  PATH=/usr/bin:/bin "$ROOT/bin/plan-to-lavish" plan.md >/dev/null 2>&1
)
html="$TMP/.lavish/plan.html"
[[ -f "$html" ]] || fail "expected fallback renderer output"
grep -Fq 'href="https://example.com/docs?a=1&amp;b=2"' "$html" || fail "safe URL was not rendered"
grep -Fq 'href="docs/guide.md"' "$html" || fail "relative URL was not rendered"
! grep -Fq 'href="javascript:' "$html" || fail "javascript URL was rendered as a link"
! grep -Fq 'onmouseover="' "$html" || fail "quoted URL escaped its attribute"
grep -Fq '&quot; onmouseover=&quot;' "$html" || fail "quoted URL was not attribute-escaped"

mkdir "$TMP/fake-bin"
cat > "$TMP/fake-bin/pandoc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '<p>safe</p><img src="ignored"><p>after-image</p><script>alert(1)</script><section><img src="ignored">hidden</section><p>after-subtree</p><a href="javascript:alert(1)" onmouseover="alert(2)">bad</a><a href="https://example.com">good</a>'
SH
chmod +x "$TMP/fake-bin/pandoc"
(
  cd "$TMP"
  PATH="$TMP/fake-bin:/usr/bin:/bin" "$ROOT/bin/plan-to-lavish" plan.md >/dev/null 2>&1
)
! grep -Fq '<script>alert(1)</script>' "$html" || fail "pandoc raw script survived sanitization"
! grep -Fq 'javascript:' "$html" || fail "pandoc unsafe link survived sanitization"
! grep -Fq 'onmouseover' "$html" || fail "pandoc event attribute survived sanitization"
grep -Fq '<p>after-image</p>' "$html" || fail "content after a disallowed void tag was removed"
grep -Fq '<p>after-subtree</p>' "$html" || fail "content after a skipped subtree with a void tag was removed"
grep -Fq 'href="https://example.com"' "$html" || fail "pandoc safe link was removed"

echo "plan to lavish regression passed"
