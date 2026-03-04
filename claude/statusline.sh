#!/bin/bash
# Claude Code status line — clean & practical
# Input: JSON on stdin from Claude Code

input=$(cat)

# ━━━ Colors (minimal palette) ━━━
RST='\033[0m'
BOLD='\033[1m'
PURPLE='\033[1;38;5;141m'
CYAN='\033[1;38;5;117m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
WHITE='\033[1;97m'
DIM='\033[1;90m'

# ━━━ Parse JSON (single jq call) ━━━
eval "$(echo "$input" | jq -r '
  @sh "MODEL_NAME=\(.model.display_name // "Claude")",
  @sh "USED_PCT=\(.context_window.used_percentage // 0)",
  @sh "CTX_SIZE=\(.context_window.context_window_size // 200000)",
  @sh "INPUT_TOK=\(.context_window.current_usage.input_tokens // 0)",
  @sh "OUTPUT_TOK=\(.context_window.current_usage.output_tokens // 0)",
  @sh "CACHE_TOK=\(.context_window.current_usage.cache_read_input_tokens // 0)",
  @sh "REMAINING_PCT=\(.context_window.remaining_percentage // 0)",
  @sh "COST=\(.cost.total_cost_usd // 0)",
  @sh "DURATION_MS=\(.cost.total_duration_ms // 0)",
  @sh "CWD=\(.cwd // .workspace.current_dir // "")",
  @sh "PROJECT_DIR=\(.workspace.project_dir // "")"
' 2>/dev/null)"

SEP="${DIM} │ ${RST}"

# ━━━ Fix remaining_pct at startup ━━━
USED_TOK=$((INPUT_TOK + OUTPUT_TOK + CACHE_TOK))
REM=$REMAINING_PCT
if [ "$REM" -eq 0 ] && [ "$USED_TOK" -eq 0 ] && [ "$CTX_SIZE" -gt 0 ]; then
  REM=100
fi

# ━━━ Model ━━━
MODEL="${PURPLE}${MODEL_NAME}${RST}"
if [ "$CTX_SIZE" -ge 1000000 ] 2>/dev/null; then
  MODEL+=" ${DIM}1M${RST}"
fi

# ━━━ Git ━━━
BRANCH=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)
else
  BRANCH=$(git branch --show-current 2>/dev/null)
fi

GIT=""
if [ -n "$BRANCH" ]; then
  DIRTY=""
  if [ -n "$CWD" ] && [ -d "$CWD" ]; then
    git -C "$CWD" diff --quiet HEAD 2>/dev/null || DIRTY="${YELLOW}*${RST}"
  fi
  WT=""
  [[ "$CWD" == *"/worktrees/"* ]] && WT=" ${DIM}[wt]${RST}"
  GIT="${CYAN}${BRANCH}${RST}${DIRTY}${WT}"
fi

# ━━━ Directory ━━━
DIR=""
if [ -n "$PROJECT_DIR" ]; then DIR=$(basename "$PROJECT_DIR")
elif [ -n "$CWD" ]; then DIR=$(basename "$CWD")
fi

# ━━━ Context bar (16 wide) + percentage ━━━
USED_INT=${USED_PCT%%.*}
USED_INT=${USED_INT:-0}
FILLED=$(( (USED_INT * 16 + 50) / 100 ))
[ "$FILLED" -gt 16 ] && FILLED=16
[ "$FILLED" -lt 0 ] && FILLED=0

if [ "$REM" -gt 60 ]; then BC="$GREEN"
elif [ "$REM" -gt 30 ]; then BC="$YELLOW"
else BC="$RED"
fi

BAR="${BC}"
for ((i=0; i<FILLED; i++)); do BAR+="█"; done
BAR+="${DIM}"
for ((i=FILLED; i<16; i++)); do BAR+="░"; done
BAR+="${RST}"

WARN=""
[ "$REM" -le 15 ] && WARN=" ${RED}DANGER${RST}"
[ "$REM" -gt 15 ] && [ "$REM" -le 30 ] && WARN=" ${YELLOW}LOW${RST}"

CTX="${BAR} ${BC}${REM}%${RST}${WARN}"

# ━━━ Token count (used/total, human readable) ━━━
fmt_k() {
  local n=$1
  if [ "$n" -ge 1000000 ]; then
    echo "$((n / 1000))k"
  elif [ "$n" -ge 1000 ]; then
    echo "$((n / 1000))k"
  else
    echo "$n"
  fi
}
TOKENS="${WHITE}$(fmt_k $USED_TOK)${RST}${DIM}/${RST}${WHITE}$(fmt_k $CTX_SIZE)${RST}"

# ━━━ Cost ━━━
COST_RAW=$(echo "$COST" | awk '{
  if ($1 >= 1) printf "%.2f", $1
  else if ($1 >= 0.01) printf "%.2f", $1
  else if ($1 > 0) printf "%.3f", $1
  else printf "0.00"
}' 2>/dev/null)
COST_FMT="${DIM}\$${RST}${WHITE}${COST_RAW}${RST}"

# ━━━ Duration ━━━
DUR=""
if [ "$DURATION_MS" -gt 0 ] 2>/dev/null; then
  S=$((DURATION_MS / 1000))
  if [ "$S" -ge 3600 ]; then
    H=$((S / 3600)); M=$(( (S % 3600) / 60 ))
    [ "$M" -gt 0 ] && DUR="${H}h${M}m" || DUR="${H}h"
  elif [ "$S" -ge 60 ]; then DUR="$((S / 60))m"
  else DUR="${S}s"
  fi
  DUR="${DIM}${DUR}${RST}"
fi

# ━━━ Assemble ━━━
OUT="$MODEL"
[ -n "$GIT" ] && OUT+="${SEP}${GIT}"
[ -n "$DIR" ] && OUT+="${SEP}${WHITE}${DIR}${RST}"
OUT+="${SEP}${CTX}"
OUT+="${SEP}${TOKENS}"
[ -n "$COST_FMT" ] && OUT+="${SEP}${COST_FMT}"
[ -n "$DUR" ] && OUT+="${SEP}${DUR}"

printf '%b\n' "$OUT"
