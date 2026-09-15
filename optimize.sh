#!/usr/bin/env bash
#
# optimize.sh — web video optimizer
#
# Drop videos into inbox/ and run ./optimize.sh (or leave ./optimize.sh --watch
# running), or ask an AI coding agent to do it (see AGENTS.md). Each video gets
# one folder, videos/<name>/, holding its source, settings, report, candidate
# encodes, previews and the web-ready output. Quality is chosen with VMAF.
# Requires only bash and Docker: all video work runs in a pinned container.
# See README.md for the workflow and every setting.

set -euo pipefail

CALLER_DIR="$PWD"  # relative FILE/DIR arguments resolve from here
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
  ./optimize.sh                    Process every video in inbox/ plus unfinished ones
  ./optimize.sh FILE|URL ...       Copy/download into inbox/, then process
  ./optimize.sh --watch [SECONDS]  Keep processing whatever lands in inbox/
  ./optimize.sh --list             Show videos and their status
  ./optimize.sh --redo NAME|all    Re-process videos (cached encodes are reused)
  ./optimize.sh --inspect FILE|NAME  Show source details and the output plan only
  ./optimize.sh --frames FILE|NAME [COUNT]
                                   Save sample frames for visual review
                                   (source vs output for a delivered video)
  ./optimize.sh --collect DIR      Copy every finished MP4 and its posters into DIR
  ./optimize.sh --clean NAME|all   Delete candidate encodes and previews (keeps outputs)
  ./optimize.sh --help

Each video lives in videos/NAME/: source, job.env, report.txt, output/, preview/,
candidates/.
Settings: config.env (all videos) < videos/NAME/job.env (one video) < environment
  e.g.  VMAF=off ./optimize.sh      CRF_FINAL=24 ./optimize.sh --redo intro
EOF
}

main() {
  local interval="" arg
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
    --redo) MODE=redo; shift; [ $# -gt 0 ] || die "--redo needs a video name or 'all'" ;;
    --inspect) MODE=inspect; shift; [ $# -gt 0 ] || die "--inspect needs a file or video name" ;;
    --frames)
      MODE=frames; shift
      { [ $# -ge 1 ] && [ $# -le 2 ]; } || die "--frames needs a file or video name, and optionally a frame count" ;;
    --collect) MODE=collect; shift; [ $# -eq 1 ] || die "--collect needs exactly one destination folder" ;;
    --clean) MODE=clean; shift; [ $# -gt 0 ] || die "--clean needs a video name or 'all'" ;;
    -*) usage >&2; die "Unknown option: $1" ;;
  esac
  case "$MODE" in
    run|redo|inspect|frames|collect|clean) ;;
    *) [ $# -eq 0 ] || die "Unexpected arguments: $*" ;;
  esac

  config_snapshot_env
  config_resolve ""
  ensure_dirs

  # These only read or delete local files, so they don't need Docker
  case "$MODE" in
    list) list_jobs; return 0 ;;
    collect) collect "$1"; return 0 ;;
    clean) lock_acquire; clean_jobs "$@"; return 0 ;;
  esac

  bold "== Preflight =="
  runner_init

  case "$MODE" in
    inspect)
      for arg in "$@"; do inspect "$arg"; done ;;
    frames)
      frames "$@" ;;
    run)
      lock_acquire
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
