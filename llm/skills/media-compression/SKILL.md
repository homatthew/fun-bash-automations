---
name: media-compression
description: Compress photo/video folders for storage or iCloud-friendly upload. Use when the user asks to shrink images, videos, camera dumps, or media folders while preserving broadly compatible formats.
---

# Media Compression

Use this for quick, practical media shrinking when the goal is smaller storage usage, not archival quality.

## Defaults

- For iCloud Photos compatibility, prefer:
  - Photos: JPEG, resized and recompressed.
  - Videos: MP4 container, H.264 video, AAC audio.
- Use `balanced` defaults for normal/valued media. Use `lofi` only when the user explicitly wants maximum savings for low-value media.
- Avoid WebP unless the user specifically wants web delivery. It compresses well, but is less reliable for iCloud Photos upload/workflows than JPEG/MP4.
- Avoid converting casual JPEGs to HEIC by default. HEIC can be smaller, but creates more compatibility friction.
- Keep originals in a sibling backup folder unless the user explicitly wants deletion.
- Preserve filesystem modified times. If `exiftool` is installed, also copy photo time/GPS/camera tags and stamp MP4 QuickTime dates from source video dates.

## Quick Workflow

1. Inspect source:
   ```bash
   du -sh "$DIR"
   find "$DIR" -maxdepth 1 -type f -exec file {} +
   ```
2. Run the bundled script:
   ```bash
   llm/skills/media-compression/scripts/icloud_optimize_media.sh "$DIR" --replace
   ```
3. Verify:
   ```bash
   du -sh "$DIR" "$DIR-originals-"*
   find "$DIR" -maxdepth 1 -type f -exec ls -lh {} +
   ```

## Useful Knobs

- Normal media: `--preset balanced` (default: photo edge 1440, JPEG quality 75, video width 1280, CRF 24).
- More savings for lofi media: `--preset lofi` (photo edge 960, JPEG quality 60, video width 960, CRF 30).
- Better quality for keepers: `--preset quality` (photo edge 2048, JPEG quality 85, video width 1920, CRF 20).
- Override any preset: `--max-photo-edge 1600 --jpeg-quality 80 --video-width 1280 --crf 23`.
- Dry output folder only: omit `--replace`; the script writes a sibling `*-icloud-optimized-*` directory.

## Guardrails

- Validate converted files before replacing originals.
- Preserve file modification times where practical.
- Check metadata when dates matter:
  ```bash
  exiftool -time:all -G1 -a -s "$FILE"
  ```
- Do not use `rm -rf`; move originals to a timestamped backup.
- State exactly what changed: original size, optimized size, backup path, output formats.
