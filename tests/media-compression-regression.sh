#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/llm/skills/media-compression/scripts/icloud_optimize_media.sh"
TMP="$(mktemp -d -t fba-media-compression-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TMP/fail-bin" "$TMP/media"
for tool in sips ffmpeg ffprobe; do
  cat > "$TMP/fail-bin/$tool" <<'SH'
#!/usr/bin/env bash
exit 99
SH
  chmod +x "$TMP/fail-bin/$tool"
done

touch "$TMP/media/photo.jpg" "$TMP/media/photo.png"
if output="$(PATH="$TMP/fail-bin:$PATH" "$SCRIPT" "$TMP/media" 2>&1)"; then
  fail "expected normalized output collision to abort"
fi
[[ "$output" == *"same output: photo.jpg"* ]] || fail "collision was not reported: $output"
if find "$TMP" -maxdepth 1 -type d -name 'media-icloud-optimized-stage-*' | grep -q .; then
  fail "collision left a staging directory behind"
fi

mkdir -p "$TMP/bin" "$TMP/newline-media"
cat > "$TMP/bin/sips" <<'SH'
#!/usr/bin/env bash
dest=
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--out" ]]; then
    dest=$2
    break
  fi
  shift
done
if [[ -n "$dest" ]]; then
  : > "$dest"
fi
SH
cat > "$TMP/bin/ffmpeg" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "$FFMPEG_ARGS_LOG"
dest=${!#}
: > "$dest"
SH
cat > "$TMP/bin/ffprobe" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$TMP/bin/exiftool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/bin/sips" "$TMP/bin/ffmpeg" "$TMP/bin/ffprobe" "$TMP/bin/exiftool"

video_name=$'clip\nname.mov'
touch "$TMP/newline-media/$video_name"
run_out="$(
  FFMPEG_ARGS_LOG="$TMP/ffmpeg-args" PATH="$TMP/bin:$PATH" \
    "$SCRIPT" "$TMP/newline-media" --video-width 1280
)" || fail "newline filename optimization failed"
optimized_dir=${run_out#*Optimized output: }
optimized_dir=${optimized_dir%%$'\n'*}
[[ -f "$optimized_dir/${video_name%.*}.mp4" ]] ||
  fail "newline filename was not preserved in optimized output"
python3 - "$TMP/ffmpeg-args" <<'PY' || fail "video scale filter can upscale narrow inputs"
import sys

args = open(sys.argv[1], "rb").read().split(b"\0")
assert b"scale='min(iw,1280)':-2" in args
PY

echo "media compression regression passed"
