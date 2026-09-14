#!/usr/bin/env bash
#
# optimize.sh — drop-folder web video optimizer
#
# Drop videos into inbox/ and run ./optimize.sh (or leave ./optimize.sh --watch
# running). Each video becomes a job in work/<name>/; the web-ready MP4, posters
# and report land in output/<name>/. Quality is picked automatically with VMAF.
# Requires bash 3.2+ and either Docker or ffmpeg with libx264 + libvmaf.
# See README.md for the workflow and every setting.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# shellcheck source=lib/util.sh
. lib/util.sh
# shellcheck source=lib/config.sh
. lib/config.sh
# shellcheck source=lib/media.sh
. lib/media.sh
# shellcheck source=lib/jobs.sh
. lib/jobs.sh

usage() {
  cat <<'EOF'
Usage:
  ./optimize.sh                    Process every video in inbox/ plus unfinished jobs
  ./optimize.sh FILE|URL ...       Copy/download into inbox/, then process
  ./optimize.sh --watch [SECONDS]  Keep processing whatever lands in inbox/
  ./optimize.sh --list             Show jobs and their status
  ./optimize.sh --redo NAME|all    Re-process jobs (cached encodes are reused)
  ./optimize.sh --inspect FILE|NAME  Show source details and the output plan only
  ./optimize.sh --help

Settings: config.env (all videos) < work/NAME/job.env (one video) < environment
  e.g.  VMAF=off ./optimize.sh      CRF_FINAL=24 ./optimize.sh --redo intro
EOF
}

main() {
  local interval=""
  MODE=run
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    --watch)
      MODE=watch; shift
      if [ $# -gt 0 ]; then
        is_int "$1" && [ "$1" -ge 1 ] || die "--watch interval must be a whole number of seconds"
        interval="$1"; shift
      fi ;;
    --list) MODE=list; shift ;;
    --redo) MODE=redo; shift; [ $# -gt 0 ] || die "--redo needs a job name or 'all'" ;;
    --inspect) MODE=inspect; shift; [ $# -gt 0 ] || die "--inspect needs a file or job name" ;;
    -*) usage >&2; die "Unknown option: $1" ;;
  esac
  [ "$MODE" = run ] || [ "$MODE" = redo ] || [ "$MODE" = inspect ] || [ $# -eq 0 ] \
    || die "Unexpected arguments: $*"

  config_snapshot_env
  config_resolve ""
  ensure_dirs

  if [ "$MODE" = list ]; then
    list_jobs
    return 0
  fi

  bold "== Preflight =="
  runner_init

  case "$MODE" in
    inspect)
      local arg
      for arg in "$@"; do inspect "$arg"; done ;;
    run)
      lock_acquire
      local arg
      for arg in "$@"; do add_to_inbox "$arg"; done
      run_once ;;
    redo)
      lock_acquire
      redo_jobs "$@"
      run_once ;;
    watch)
      lock_acquire
      watch_loop "${interval:-$WATCH_INTERVAL}" ;;
  esac
}

main "$@"
