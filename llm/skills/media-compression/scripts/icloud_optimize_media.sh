#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: icloud_optimize_media.sh DIR [--replace] [--preset balanced|lofi|quality]
       [--max-photo-edge N] [--jpeg-quality N] [--video-width N] [--crf N]

Converts casual media folders to iCloud-friendly small files:
  photos -> JPEG
  videos -> MP4/H.264/AAC

Without --replace, writes a sibling optimized folder.
With --replace, moves originals to DIR-originals-YYYYmmdd-HHMMSS first.
USAGE
}

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 2
fi

src=$1
shift

replace=false
preset=balanced
max_photo_edge=
jpeg_quality=
video_width=
crf=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --replace)
      replace=true
      shift
      ;;
    --preset)
      preset=$2
      shift 2
      ;;
    --max-photo-edge)
      max_photo_edge=$2
      shift 2
      ;;
    --jpeg-quality)
      jpeg_quality=$2
      shift 2
      ;;
    --video-width)
      video_width=$2
      shift 2
      ;;
    --crf)
      crf=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$preset" in
  lofi)
    default_max_photo_edge=960
    default_jpeg_quality=60
    default_video_width=960
    default_crf=30
    ;;
  balanced)
    default_max_photo_edge=1440
    default_jpeg_quality=75
    default_video_width=1280
    default_crf=24
    ;;
  quality)
    default_max_photo_edge=2048
    default_jpeg_quality=85
    default_video_width=1920
    default_crf=20
    ;;
  *)
    echo "Unknown preset: $preset" >&2
    usage >&2
    exit 2
    ;;
esac

max_photo_edge=${max_photo_edge:-$default_max_photo_edge}
jpeg_quality=${jpeg_quality:-$default_jpeg_quality}
video_width=${video_width:-$default_video_width}
crf=${crf:-$default_crf}

if [ ! -d "$src" ]; then
  echo "Not a directory: $src" >&2
  exit 1
fi

if ! command -v sips >/dev/null 2>&1; then
  echo "Missing required command: sips" >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Missing required command: ffmpeg" >&2
  exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Missing required command: ffprobe" >&2
  exit 1
fi

timestamp=$(date +%Y%m%d-%H%M%S)
parent=$(cd "$(dirname "$src")" && pwd)
name=$(basename "$src")
stage="$parent/$name-icloud-optimized-stage-$timestamp"
out="$parent/$name-icloud-optimized-$timestamp"
backup="$parent/$name-originals-$timestamp"

mkdir -p "$stage"

copy_photo_metadata() {
  source_file=$1
  dest_file=$2

  if command -v exiftool >/dev/null 2>&1; then
    exiftool -overwrite_original -P -q -q -TagsFromFile "$source_file" \
      -time:all -gps:all -make -model -software \
      "$dest_file" || true
  fi
}

copy_video_dates() {
  source_file=$1
  dest_file=$2

  if ! command -v exiftool >/dev/null 2>&1; then
    return
  fi

  date_created=$(exiftool -s3 -DateTimeOriginal "$source_file" 2>/dev/null | head -1)
  if [ -z "$date_created" ]; then
    date_created=$(exiftool -s3 -CreateDate "$source_file" 2>/dev/null | head -1)
  fi
  if [ -z "$date_created" ]; then
    date_created=$(exiftool -s3 -DateCreated "$source_file" 2>/dev/null | head -1)
  fi
  if [ -z "$date_created" ]; then
    return
  fi

  case "$date_created" in
    *:*:*" "*:*:*)
      date_time=$date_created
      ;;
    *:*:*)
      date_time="$date_created 00:00:00"
      ;;
    *)
      return
      ;;
  esac

  exiftool -overwrite_original -P -q -q \
    "-QuickTime:CreateDate=$date_time" \
    "-QuickTime:ModifyDate=$date_time" \
    "-TrackCreateDate=$date_time" \
    "-TrackModifyDate=$date_time" \
    "-MediaCreateDate=$date_time" \
    "-MediaModifyDate=$date_time" \
    "-ContentCreateDate=$date_time" \
    "$dest_file" || true
}

find "$src" -maxdepth 1 -type f | while IFS= read -r file; do
  base=$(basename "$file")
  stem=${base%.*}
  ext=${base##*.}
  lower=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')

  case "$lower" in
    jpg|jpeg|png|tif|tiff)
      dest="$stage/$stem.jpg"
      sips -Z "$max_photo_edge" \
        --setProperty format jpeg \
        --setProperty formatOptions "$jpeg_quality" \
        "$file" --out "$dest" >/dev/null
      copy_photo_metadata "$file" "$dest"
      touch -r "$file" "$dest"
      ;;
    avi|mov|mp4|m4v)
      dest="$stage/$stem.mp4"
      ffmpeg -hide_banner -loglevel error -nostdin -y -i "$file" \
        -vf "scale=${video_width}:-2" \
        -c:v libx264 -preset slow -crf "$crf" -pix_fmt yuv420p \
        -c:a aac -b:a 64k -movflags +faststart "$dest"
      copy_video_dates "$file" "$dest"
      touch -r "$file" "$dest"
      ;;
  esac
done

if ! find "$stage" -maxdepth 1 -type f | grep -q .; then
  rmdir "$stage"
  echo "No supported media found in $src" >&2
  exit 1
fi

find "$stage" -maxdepth 1 -type f -name '*.jpg' -print0 |
  while IFS= read -r -d '' file; do
    sips -g pixelWidth -g pixelHeight "$file" >/dev/null
  done

find "$stage" -maxdepth 1 -type f -name '*.mp4' -print0 |
  while IFS= read -r -d '' file; do
    ffprobe -v error "$file" >/dev/null
  done

if [ "$replace" = true ]; then
  if [ -e "$backup" ]; then
    echo "Backup path already exists: $backup" >&2
    exit 1
  fi
  mkdir -p "$backup"
  find "$src" -maxdepth 1 -type f -exec mv {} "$backup" \;
  find "$stage" -maxdepth 1 -type f -exec mv {} "$src" \;
  rmdir "$stage"
  echo "Optimized in place: $src"
  echo "Originals: $backup"
else
  mv "$stage" "$out"
  echo "Optimized output: $out"
fi

du -sh "$src" 2>/dev/null || true
if [ "$replace" = true ]; then
  du -sh "$backup"
else
  du -sh "$out"
fi
