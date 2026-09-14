# lib/util.sh — logging and small portable helpers (bash 3.2+, macOS & Linux)

if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_RESET=$'\033[0m'
  CURL_PROGRESS=(--progress-bar)
else
  # Not a terminal (agent, CI, log file): no colors or progress spam
  C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_RESET=""
  CURL_PROGRESS=(-sS)
fi

bold() { printf '%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }
info() { printf '  %s•%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

in_words() {  # in_words <word> "<space-separated list>"
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

is_int() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

is_number() {  # non-negative integer or decimal
  case "$1" in ''|.*|*.|*[!0-9.]*|*.*.*) return 1 ;; esac
}

num_gt() {  # num_gt <a> <b> — a > b, with a 0.01 tolerance for fps like 29.97
  awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a > b + 0.01) }'
}

num_ge() {  # num_ge <a> <b> — a >= b
  awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a >= b) }'
}

fmt_num() {  # fmt_num <number> — up to 3 decimals, trailing zeros removed
  awk -v n="$1" 'BEGIN{ s = sprintf("%.3f", n); sub(/\.?0+$/, "", s); print s }'
}

human_size() {  # bytes -> decimal units (1 MB = 1,000,000 B), matching CDN billing
  awk -v b="$1" 'BEGIN{
    split("B KB MB GB", u); s = 1
    while (b >= 1000 && s < 4) { b /= 1000; s++ }
    printf (s == 1 ? "%d %s" : "%.2f %s"), b, u[s]
  }'
}

file_bytes() {  # GNU stat first: BSD `stat -f` means something else on Linux
  stat -c%s "$1" 2>/dev/null || stat -f%z "$1"
}

file_age() {  # seconds since the file was last modified
  local m
  m="$(stat -c%Y "$1" 2>/dev/null || stat -f%m "$1")"
  printf '%s' "$(( $(date +%s) - m ))"
}

slugify() {  # "My Clip (Final).MOV" -> "my-clip-final"
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  printf '%s' "${s:-video}"
}

kv_get() {  # kv_get <file> <key> — value from a key=value file
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | tail -n 1
}
