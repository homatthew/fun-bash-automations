#!/bin/bash
# Claude Code status line — rich context at a glance
# Input: JSON on stdin with model, context_window, cost, workspace, etc.
# Supports ANSI colors. Use printf '%b' for reliable escape handling.

input=$(cat)

# -- Colors --
RST='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'
MAGENTA='\033[35m'
BLUE='\033[34m'
WHITE='\033[37m'
BOLD_CYAN='\033[1;36m'
BOLD_YELLOW='\033[1;33m'
BOLD_RED='\033[1;31m'
BOLD_GREEN='\033[1;32m'
BOLD_MAGENTA='\033[1;35m'

# Single jq call to extract all values for performance
eval "$(echo "$input" | jq -r '
  @sh "MODEL_NAME=\(.model.display_name // "Claude")",
  @sh "MODEL_ID=\(.model.id // "")",
  @sh "USED=\(.context_window.used_percentage // 0)",
  @sh "CTX_SIZE=\(.context_window.context_window_size // 200000)",
  @sh "COST=\(.cost.total_cost_usd // 0)",
  @sh "DURATION_MS=\(.cost.total_duration_ms // 0)",
  @sh "LINES_ADD=\(.cost.total_lines_added // 0)",
  @sh "LINES_DEL=\(.cost.total_lines_removed // 0)",
  @sh "CWD=\(.cwd // .workspace.current_dir // "")",
  @sh "PROJECT_DIR=\(.workspace.project_dir // "")"
' 2>/dev/null)"

# -- Model display (compact, colored) --
MODEL="${BOLD_MAGENTA}${MODEL_NAME}${RST}"
if [ "$CTX_SIZE" -ge 1000000 ] 2>/dev/null; then
  MODEL="${BOLD_MAGENTA}${MODEL_NAME}${RST}${DIM} 1M${RST}"
fi

# -- Git branch --
BRANCH=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)
else
  BRANCH=$(git branch --show-current 2>/dev/null)
fi

# -- Git dirty state --
DIRTY=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  if ! git -C "$CWD" diff --quiet HEAD 2>/dev/null; then
    DIRTY="${YELLOW}*${RST}"
  fi
fi

# -- Worktree detection --
WORKTREE_TAG=""
if [[ "$CWD" == *"/worktrees/"* ]]; then
  WORKTREE_TAG=" ${DIM}[wt]${RST}"
fi

# -- Directory name --
DIR_NAME=""
if [ -n "$PROJECT_DIR" ]; then
  DIR_NAME=$(basename "$PROJECT_DIR")
elif [ -n "$CWD" ]; then
  DIR_NAME=$(basename "$CWD")
fi

# -- Context bar (10 segments, color-coded) --
USED_INT=${USED%%.*}
USED_INT=${USED_INT:-0}
REMAINING=$((100 - USED_INT))
FILLED=$(( (USED_INT + 5) / 10 ))
[ "$FILLED" -gt 10 ] && FILLED=10
[ "$FILLED" -lt 0 ] && FILLED=0
EMPTY=$((10 - FILLED))

# Color based on remaining context
if [ "$REMAINING" -le 15 ]; then
  BAR_COLOR="$BOLD_RED"
  PCT_COLOR="$BOLD_RED"
  WARN=" !!"
elif [ "$REMAINING" -le 30 ]; then
  BAR_COLOR="$YELLOW"
  PCT_COLOR="$BOLD_YELLOW"
  WARN=" !"
elif [ "$REMAINING" -le 50 ]; then
  BAR_COLOR="$YELLOW"
  PCT_COLOR="$YELLOW"
  WARN=""
else
  BAR_COLOR="$GREEN"
  PCT_COLOR="$GREEN"
  WARN=""
fi

BAR="${BAR_COLOR}"
for ((i=0; i<FILLED; i++)); do BAR+="█"; done
BAR+="${RST}${DIM}"
for ((i=0; i<EMPTY; i++)); do BAR+="░"; done
BAR+="${RST}"

CTX="${BAR} ${PCT_COLOR}${REMAINING}%${WARN}${RST}"

# -- Session cost --
COST_FMT=""
if command -v awk >/dev/null 2>&1; then
  COST_RAW=$(echo "$COST" | awk '{
    if ($1 >= 1) printf "%.2f", $1
    else if ($1 >= 0.01) printf "%.2f", $1
    else if ($1 > 0) printf "%.3f", $1
    else printf "0"
  }')
  COST_FMT="${DIM}\$${RST}${CYAN}${COST_RAW}${RST}"
else
  COST_FMT="${DIM}\$${RST}${CYAN}${COST}${RST}"
fi

# -- Session duration (human readable) --
DUR=""
if [ "$DURATION_MS" -gt 0 ] 2>/dev/null; then
  TOTAL_SEC=$((DURATION_MS / 1000))
  if [ "$TOTAL_SEC" -ge 3600 ]; then
    HOURS=$((TOTAL_SEC / 3600))
    MINS=$(( (TOTAL_SEC % 3600) / 60 ))
    if [ "$MINS" -gt 0 ]; then
      DUR_RAW="${HOURS}h${MINS}m"
    else
      DUR_RAW="${HOURS}h"
    fi
  elif [ "$TOTAL_SEC" -ge 60 ]; then
    MINS=$((TOTAL_SEC / 60))
    DUR_RAW="${MINS}m"
  else
    DUR_RAW="${TOTAL_SEC}s"
  fi
  DUR="${DIM}${DUR_RAW}${RST}"
fi

# -- Lines changed (green adds, red deletes) --
LINES=""
if [ "$LINES_ADD" -gt 0 ] || [ "$LINES_DEL" -gt 0 ]; then
  LINES="${GREEN}+${LINES_ADD}${RST}${DIM}/${RST}${RED}-${LINES_DEL}${RST}"
fi

# -- Current time --
TIME_RAW=$(date +"%l:%M %p" | sed 's/^ //')
TIME="${DIM}${TIME_RAW}${RST}"

# -- Separator --
SEP="${DIM} | ${RST}"

# -- Assemble status line --
OUTPUT="$MODEL"

if [ -n "$BRANCH" ]; then
  OUTPUT+="${SEP}${BOLD_CYAN}${BRANCH}${RST}${DIRTY}${WORKTREE_TAG}"
elif [ -n "$WORKTREE_TAG" ]; then
  OUTPUT+="${SEP}${CYAN}worktree${RST}"
fi

[ -n "$DIR_NAME" ] && OUTPUT+="${SEP}${WHITE}${DIR_NAME}${RST}"
OUTPUT+="${SEP}${CTX}"
[ -n "$COST_FMT" ] && OUTPUT+="${SEP}${COST_FMT}"
[ -n "$LINES" ] && OUTPUT+="${SEP}${LINES}"
[ -n "$DUR" ] && OUTPUT+="${SEP}${DUR}"
OUTPUT+="${SEP}${TIME}"

printf '%b\n' "$OUTPUT"
