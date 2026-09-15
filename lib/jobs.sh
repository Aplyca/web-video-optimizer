# lib/jobs.sh — the drop-folder workflow: inbox/ -> work/<job>/ -> output/<job>/
#
# Job state lives in work/<job>/:
#   source.<ext>   the original (moved out of inbox/)
#   job.env        per-video overrides (template written on first run)
#   candidates/    crfNN.mp4 encodes + .settings/.vmaf cache sidecars
#   report.txt     history of every run for this job
#   .done          key=value summary of the last successful run
#   .error         timestamp of the last failed run

VIDEO_EXTS="mp4 m4v mov mkv webm avi wmv flv mpg mpeg mts m2ts ts 3gp ogv"
PARTIAL_EXTS="part crdownload download tmp partial"

RUN_NAMES=(); RUN_STATUS=(); RUN_FAILED=0
ADDED_FILES=""  # newline-delimited inbox paths this run copied in itself (known complete)

ensure_dirs() {
  mkdir -p inbox work output failed
}

lock_acquire() {
  local lock="work/.lock" pid
  if ! mkdir "$lock" 2>/dev/null; then
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      die "Another optimize.sh run (pid $pid) is using this project. Stop it or wait for it to finish."
    fi
    rm -rf "$lock"
    mkdir "$lock"
  fi
  echo "$$" > "$lock/pid"
  trap 'rm -rf "$ROOT_DIR/work/.lock"' EXIT
  trap 'exit 130' INT TERM
}

job_source() {  # job_source <job-dir> — prints the source path
  local s
  for s in "$1"/source.*; do
    if [ -f "$s" ]; then printf '%s' "$s"; return 0; fi
  done
  return 1
}

unique_name() {  # unique_name <slug> — not used by any job, output or failed entry
  local n="$1" i=2
  while [ -e "work/$n" ] || [ -e "output/$n" ] || [ -e "failed/$n" ]; do
    n="$1-$i"; i=$((i + 1))
  done
  printf '%s' "$n"
}

reject() {  # reject <path> <reason> — park an unusable inbox file or job in failed/
  local dest
  dest="failed/$(basename "$1")"
  [ ! -e "$dest" ] || dest="failed/$(date +%Y%m%d-%H%M%S)-$(basename "$1")"
  mv "$1" "$dest"
  if [ -f "$1.env" ]; then mv "$1.env" "$dest.env"; fi  # keep a rejected video's settings with it
  if [ -d "$dest" ]; then
    printf '%s\n' "$2" > "$dest/reason.txt"
  else
    printf '%s\n' "$2" > "$dest.reason.txt"
  fi
  warn "$(basename "$1"): $2 — moved to $dest"
  RUN_NAMES+=("$(basename "$1")"); RUN_STATUS+=(rejected); RUN_FAILED=$((RUN_FAILED + 1))
}

# add_to_inbox <file|url> — copy a local file or download a URL into inbox/
add_to_inbox() {
  local arg="$1" name dest
  case "$arg" in
    http://*|https://*)
      name="${arg%%\?*}"; name="${name##*/}"
      [ -n "$name" ] || name="download.mp4"
      case "$name" in *.*) ;; *) name="$name.mp4" ;; esac
      info "Downloading $arg"
      # Hidden while downloading so a concurrent watcher ignores it
      curl -fL "${CURL_PROGRESS[@]}" -o "inbox/.$name.part" "$arg" || die "Download failed: $arg"
      dest="inbox/$name"
      [ ! -e "$dest" ] || dest="inbox/$(date +%Y%m%d-%H%M%S)-$name"
      mv "inbox/.$name.part" "$dest"
      ;;
    *)
      [ -f "$arg" ] || die "Not a file or URL: $arg"
      [ "$(cd "$(dirname "$arg")" && pwd)" != "$ROOT_DIR/inbox" ] || return 0
      dest="inbox/$(basename "$arg")"
      [ ! -e "$dest" ] || dest="inbox/$(date +%Y%m%d-%H%M%S)-$(basename "$arg")"
      if [ -f "$arg.env" ]; then  # settings sidecar next to the file travels with it
        cp "$arg.env" "$dest.env"
        ADDED_FILES="$ADDED_FILES"$'\n'"$dest.env"$'\n'
        ok "Added settings $(basename "$arg").env"
      fi
      cp "$arg" "$dest"
      ;;
  esac
  ADDED_FILES="$ADDED_FILES"$'\n'"$dest"$'\n'
  ok "Added $(basename "$dest") to inbox/"
}

inbox_age() {  # inbox_age <video> — seconds since it or its .env sidecar changed
  local a="" b      # (empty when both were copied in by this run, so known complete)
  case "$ADDED_FILES" in *$'\n'"$1"$'\n'*) ;; *) a="$(file_age "$1")" ;; esac
  if [ -f "$1.env" ]; then
    case "$ADDED_FILES" in
      *$'\n'"$1.env"$'\n'*) ;;
      *) b="$(file_age "$1.env")"
         if [ -z "$a" ] || [ "$b" -lt "$a" ]; then a="$b"; fi ;;
    esac
  fi
  printf '%s' "$a"
}

# ingest_inbox [wait] — moves settled inbox files into new jobs.
# A file must be unchanged (size and mtime) for INBOX_SETTLE seconds, so a copy
# that is still running, or has stalled, is not processed half-written.
# <video>.env next to a video is its settings sidecar and becomes the job's job.env.
# wait: sleep until fresh files have settled (one-shot runs); without it, fresh
# files are simply left for a later pass (watch mode).
ingest_inbox() {
  local f i ext name files sizes age youngest pause
  files=(); sizes=(); youngest=""
  for f in inbox/*; do
    [ -f "$f" ] || continue
    case "$f" in *.env) continue ;; esac
    files+=("$f"); sizes+=("$(file_bytes "$f")")
    age="$(inbox_age "$f")"
    if [ -n "$age" ] && { [ -z "$youngest" ] || [ "$age" -lt "$youngest" ]; }; then youngest="$age"; fi
  done
  if [ "${1:-}" = wait ]; then
    for f in inbox/*.env; do
      if [ -f "$f" ] && [ ! -f "${f%.env}" ]; then
        warn "inbox/$(basename "$f") has no matching video (expected inbox/$(basename "${f%.env}")). If that video was already queued, put the settings in its work/<job>/job.env"
      fi
    done
  fi
  [ "${#files[@]}" -gt 0 ] || return 0

  pause=2
  if [ "${1:-}" = wait ] && [ -n "$youngest" ] && [ "$youngest" -lt "$INBOX_SETTLE" ]; then
    pause=$((INBOX_SETTLE - youngest))
    [ "$pause" -ge 2 ] || pause=2
    info "Waiting ${pause}s for files added to inbox/ in the last ${INBOX_SETTLE}s to settle…"
  fi
  sleep "$pause"

  for i in "${!files[@]}"; do
    f="${files[$i]}"
    [ -f "$f" ] || continue
    ext=""
    case "$(basename "$f")" in *.*) ext="$(lower "${f##*.}")" ;; esac
    if in_words "$ext" "$PARTIAL_EXTS"; then continue; fi
    if [ "$(file_bytes "$f")" != "${sizes[$i]}" ]; then
      info "$(basename "$f") is still being copied, will retry"
      continue
    fi
    age="$(inbox_age "$f")"
    if [ -n "$age" ] && [ "$age" -lt "$INBOX_SETTLE" ]; then
      info "$(basename "$f")$( [ ! -f "$f.env" ] || printf ' (or its .env)') changed ${age}s ago, will pick it up once it settles"
      continue
    fi
    if [ "${sizes[$i]}" = 0 ]; then reject "$f" "empty file"; continue; fi
    if ! in_words "$ext" "$VIDEO_EXTS"; then reject "$f" "unsupported file type '.$ext'"; continue; fi

    name="$(unique_name "$(slugify "$(basename "${f%.*}")")")"
    mkdir -p "work/$name"
    mv "$f" "work/$name/source.$ext"
    printf 'original_name=%s\nqueued=%s\n' "$(basename "$f")" "$(date '+%Y-%m-%d %H:%M:%S')" > "work/$name/.job"
    if [ -f "$f.env" ]; then
      { echo "# Settings from inbox/$(basename "$f").env"; cat "$f.env"; } > "work/$name/job.env"
      rm -f "$f.env"
      printf 'sidecar=%s\n' "$(basename "$f").env" >> "work/$name/.job"
      ok "Queued $(basename "$f") as job '$name' with settings from $(basename "$f").env"
    else
      ok "Queued $(basename "$f") as job '$name'"
    fi
  done
}

job_pending() {  # not yet delivered, or job.env edited since the last delivery
  local d="work/$1"
  job_source "$d" >/dev/null || return 1
  [ -f "$d/.done" ] || return 0
  [ -f "$d/job.env" ] && [ "$d/job.env" -nt "$d/.done" ]
}

write_job_env() {  # write_job_env <job-dir> <name> — commented template of every setting
  cat > "$1/job.env" <<EOF
# Per-video settings for job '$2'.
# Uncomment and edit a line to override config.env for this video only, then run
# ./optimize.sh again: the job is re-processed automatically, reusing any encodes
# and VMAF scores whose settings still match.
#
# Source:  ${SRC_W}x${SRC_H}$( [ "$SRC_ROT" = 0 ] || printf ' rotated %s° (%sx%s)' "$SRC_ROT" "$DISP_W" "$DISP_H") @ $(fmt_num "$SRC_FPS") fps, $(fmt_num "$SRC_DURATION") s, audio: ${SRC_AUDIO:-none}
# Planned: ${OUT_W}x${OUT_H} @ $( [ "$OUT_FPS" = keep ] && printf 'source fps' || printf '%s fps' "$OUT_FPS"), audio: $AUDIO_PLAN

# auto = smallest CRF in CRFS reaching VMAF_TARGET, or a fixed CRF 1-51
#CRF_FINAL=$CRF_FINAL
#CRFS="$CRFS"
#CRF_FALLBACK=$CRF_FALLBACK

# on | off
#VMAF=$VMAF
#VMAF_TARGET=$VMAF_TARGET

# Longest side in pixels (never upscales)
#MAX_DIMENSION=$MAX_DIMENSION

# auto (cap at MAX_FPS) | keep | a number such as 24
#FPS=$FPS
#MAX_FPS=$MAX_FPS

# keep | strip
#AUDIO=$AUDIO
#AUDIO_BITRATE=$AUDIO_BITRATE

#X264_PRESET=$X264_PRESET
#POSTER_TIME=$POSTER_TIME
EOF
}

rlog() { printf '%s\n' "$*" >> "$REPORT_RUN"; }

# Runs inside a subshell with `set -e` (see run_job); any failure aborts the job only.
process_job() {
  local name="$1" d="work/$1" src overrides key sidecar crf_list mode crf pct kbps chosen="" score="" lowest="" lowest_score="" od warnings=0
  src="$(job_source "$d")" || die "No source file in $d"
  REPORT_RUN="$d/.report.run"
  : > "$REPORT_RUN"
  rm -f "$d/.done"

  bold ""
  bold "== $name =="
  config_resolve "$d/job.env"

  if ! probe_source "$src"; then
    rm -f "$REPORT_RUN"
    reject "$d" "no readable video stream (ffprobe failed)"
    exit 2
  fi
  plan_output
  if [ ! -f "$d/job.env" ]; then
    write_job_env "$d" "$name"
  elif ! grep -q '^# Per-video settings for job' "$d/job.env"; then
    # Seeded from an inbox sidecar: add the documented template above those settings
    mv "$d/job.env" "$d/.job.env.seed"
    write_job_env "$d" "$name"
    { echo; echo "# --- Active settings from the inbox sidecar (these override config.env) ---"; cat "$d/.job.env.seed"; } >> "$d/job.env"
    rm -f "$d/.job.env.seed"
  fi
  sidecar="$(kv_get "$d/.job" sidecar)"
  overrides=""  # settings job.env actually applies (ignored keys and repeats left out)
  for key in $(sed -n 's/^[[:space:]]*\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "$d/job.env"); do
    if in_words "$key" "$CONFIG_KEYS" && ! in_words "$key" "$GLOBAL_ONLY_KEYS" && ! in_words "$key" "$overrides"; then
      overrides="${overrides:+$overrides }$key"
    fi
  done

  info "Source: $(human_size "$SRC_BYTES") | ${DISP_W}x${DISP_H} @ $(fmt_num "$SRC_FPS") fps | $(fmt_num "$SRC_DURATION") s | audio: ${SRC_AUDIO:-none}"
  info "Output: ${OUT_W}x${OUT_H} @ $( [ "$OUT_FPS" = keep ] && printf 'source fps' || printf '%s fps' "$OUT_FPS") | audio: $AUDIO_PLAN | preset $X264_PRESET"
  rlog "##### Run $(date '+%Y-%m-%d %H:%M:%S') #####"
  rlog "Source:  $(kv_get "$d/.job" original_name) | $(human_size "$SRC_BYTES") | ${SRC_W}x${SRC_H}$( [ "$SRC_ROT" = 0 ] || printf ' rotated %s°' "$SRC_ROT") @ $(fmt_num "$SRC_FPS") fps | $(fmt_num "$SRC_DURATION") s | ${SRC_PIXFMT} | audio: ${SRC_AUDIO:-none}"
  rlog "Output:  ${OUT_W}x${OUT_H} @ $( [ "$OUT_FPS" = keep ] && printf 'source fps' || printf '%s fps' "$OUT_FPS") | audio: $AUDIO_PLAN | x264 preset $X264_PRESET | $FFMPEG_ID"
  rlog "job.env: ${overrides:-no overrides}${sidecar:+ (seeded from inbox/$sidecar)}"

  case "$SRC_TRANSFER" in
    smpte2084|arib-std-b67)
      warn "HDR source ($SRC_TRANSFER): output is SDR without tone mapping, colors may look washed out"
      rlog "WARNING: HDR source ($SRC_TRANSFER) converted to SDR without tone mapping" ;;
  esac

  # Choose which CRFs to try
  if [ "$CRF_FINAL" != auto ]; then
    mode=fixed; crf_list="$CRF_FINAL"
    rlog "Quality: fixed CRF $CRF_FINAL$( [ "$VMAF" = on ] && printf ' (VMAF target %s)' "$VMAF_TARGET")"
  elif [ "$VMAF" = on ]; then
    # Highest CRF (smallest, fastest) first; stop at the first that meets the target
    mode=search; crf_list="$(printf '%s\n' $CRFS | sort -rn | uniq | tr '\n' ' ')"
    rlog "Quality: auto, VMAF >= $VMAF_TARGET, trying CRF $(trim "$crf_list")"
  else
    mode=fallback; crf_list="$CRF_FALLBACK"
    rlog "Quality: auto with VMAF off, using CRF_FALLBACK=$CRF_FALLBACK"
  fi

  for crf in $crf_list; do
    encode_candidate "$d" "$src" "$crf"
    score=""
    if [ "$VMAF" = on ]; then
      candidate_vmaf "$src" "$crf"
      score="$CAND_SCORE"
    fi
    pct="$(awk -v a="$(file_bytes "$CAND")" -v b="$SRC_BYTES" 'BEGIN{ printf "%.1f", 100 - a / b * 100 }')"
    if [ -n "$score" ]; then
      if num_ge "$score" "$VMAF_TARGET"; then score_note="VMAF $score"; else score_note="VMAF $score (below $VMAF_TARGET)"; fi
    else
      score_note="VMAF not measured"
    fi
    ok "CRF $crf -> $(human_size "$(file_bytes "$CAND")") (-$pct%), $score_note [$CAND_STATUS]"
    rlog "  CRF $crf: $(human_size "$(file_bytes "$CAND")") (-$pct%), $score_note [$CAND_STATUS]"
    if [ -n "$CAND_WARN" ]; then
      warnings=$((warnings + 1))
      warn "ffmpeg reported errors reading the source (truncated or corrupt?): $CAND_WARN"
      rlog "  WARNING: ffmpeg reported: $CAND_WARN"
    fi

    if [ "$mode" = search ]; then
      if num_ge "$score" "$VMAF_TARGET"; then chosen="$crf"; break; fi
      lowest="$crf"; lowest_score="$score"
    else
      chosen="$crf"
    fi
  done

  if [ -z "$chosen" ]; then
    chosen="$lowest"; score="$lowest_score"
    warn "No CRF in '$CRFS' reached VMAF $VMAF_TARGET; delivering the best one tried (CRF $chosen, VMAF $score). Add lower CRFs to CRFS."
    rlog "WARNING: no CRF reached VMAF $VMAF_TARGET; delivered best tried"
  elif [ -n "$score" ] && ! num_ge "$score" "$VMAF_TARGET"; then
    warn "CRF $chosen scores VMAF $score, below target $VMAF_TARGET"
    rlog "WARNING: CRF $chosen is below the VMAF target"
  fi

  # Deliver
  od="output/$name"
  mkdir -p "$od"
  cp -f "$d/candidates/crf$chosen.mp4" "$od/$name.mp4"
  make_posters "$od/$name.mp4" "$od/$name-poster"
  local out_bytes; out_bytes="$(file_bytes "$od/$name.mp4")"
  pct="$(awk -v a="$out_bytes" -v b="$SRC_BYTES" 'BEGIN{ printf "%.1f", 100 - a / b * 100 }')"
  kbps="$(awk -v a="$out_bytes" -v d="$SRC_DURATION" 'BEGIN{ if (d > 0) printf "%d", a * 8 / d / 1000; else print "?" }')"
  rlog "Chosen:  CRF $chosen${score:+, VMAF $score} | $(human_size "$out_bytes") (-$pct% vs source, $kbps kb/s)"
  rlog "Output:  $od/$name.mp4, $name-poster.jpg, $name-poster.webp"

  cat "$REPORT_RUN" >> "$d/report.txt"
  cp -f "$REPORT_RUN" "$od/report.txt"
  rm -f "$REPORT_RUN" "$d/.error"
  {
    echo "finished=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "crf=$chosen"
    echo "vmaf=${score:-}"
    echo "source_bytes=$SRC_BYTES"
    echo "output_bytes=$out_bytes"
    echo "reduction=$pct"
    echo "warnings=$warnings"
  } > "$d/.done"
  ok "Delivered $od/$name.mp4 — $(human_size "$out_bytes") (-$pct%), CRF $chosen${score:+, VMAF $score}"
  if [ "$warnings" -gt 0 ]; then
    warn "Delivered with warnings; check the source and $od/report.txt"
  fi
}

run_job() {
  local name="$1" d="work/$1" rc
  set +e
  ( set -e; process_job "$name" )
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    RUN_NAMES+=("$name"); RUN_STATUS+=("done")
    return 0
  fi
  if [ "$rc" -eq 2 ] && [ ! -d "$d" ]; then  # rejected: already recorded by reject()
    RUN_NAMES+=("$name"); RUN_STATUS+=(rejected); RUN_FAILED=$((RUN_FAILED + 1))
    return 0
  fi
  RUN_NAMES+=("$name"); RUN_STATUS+=(error); RUN_FAILED=$((RUN_FAILED + 1))
  if [ -f "$d/.report.run" ]; then
    { cat "$d/.report.run"; echo "FAILED (exit $rc)"; } >> "$d/report.txt"
    rm -f "$d/.report.run"
  fi
  date '+%Y-%m-%d %H:%M:%S' > "$d/.error"
  warn "Job '$name' failed (exit $rc). Fix the cause and run again; see $d/report.txt"
}

process_pending() {
  local d name
  for d in work/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    job_pending "$name" || continue
    # The watcher doesn't retry a failed job in a loop; editing job.env or --redo does
    if [ "$MODE" = watch ] && [ -f "$d/.error" ] && ! { [ -f "$d/job.env" ] && [ "$d/job.env" -nt "$d/.error" ]; }; then
      continue
    fi
    run_job "$name"
  done
}

print_summary() {
  local i name st d
  [ "${#RUN_NAMES[@]}" -gt 0 ] || return 0
  bold ""
  bold "== Summary =="
  printf '  %-30s %11s %11s %7s %4s %6s  %s\n' JOB SOURCE OUTPUT SAVED CRF VMAF STATUS
  for i in "${!RUN_NAMES[@]}"; do
    name="${RUN_NAMES[$i]}"; st="${RUN_STATUS[$i]}"; d="work/$name"
    if [ "$st" = "done" ]; then
      printf '  %-30s %11s %11s %6s%% %4s %6s  %s\n' "$name" \
        "$(human_size "$(kv_get "$d/.done" source_bytes)")" "$(human_size "$(kv_get "$d/.done" output_bytes)")" \
        "$(kv_get "$d/.done" reduction)" "$(kv_get "$d/.done" crf)" "$(kv_get "$d/.done" vmaf)" \
        "output/$name/$( [ "$(kv_get "$d/.done" warnings)" = 0 ] || printf ' (WARNINGS, see report)')"
    else
      printf '  %-30s %11s %11s %7s %4s %6s  %s\n' "$name" - - - - - "$st"
    fi
  done
}

run_once() {  # run_once [watch] — watch: no settle wait, no "nothing to do" line
  RUN_NAMES=(); RUN_STATUS=(); RUN_FAILED=0
  if [ -n "${1:-}" ]; then ingest_inbox; else ingest_inbox wait; fi
  process_pending
  if [ "${#RUN_NAMES[@]}" -eq 0 ]; then
    [ -n "${1:-}" ] || ok "Nothing to do: inbox/ is empty and every job is up to date (see --list)"
    return 0
  fi
  print_summary
  [ "$RUN_FAILED" -eq 0 ]
}

watch_loop() {
  local interval="$1"
  bold "Watching $ROOT_DIR/inbox every ${interval}s — drop videos there. Ctrl-C to stop."
  while :; do
    run_once watch || true
    sleep "$interval"
  done
}

redo_jobs() {  # redo_jobs <name|all>... — mark jobs pending again
  local n d
  for n in "$@"; do
    if [ "$n" = all ]; then
      for d in work/*/; do [ -d "$d" ] && rm -f "$d/.done" "$d/.error"; done
      ok "All jobs marked for re-processing"
    else
      [ -d "work/$n" ] || die "No job named '$n' (see ./optimize.sh --list)"
      rm -f "work/$n/.done" "work/$n/.error"
      ok "Job '$n' marked for re-processing"
    fi
  done
}

list_jobs() {
  local d name st n=0 f
  printf '  %-30s %-26s %11s %4s %6s\n' JOB STATUS OUTPUT CRF VMAF
  for d in work/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"; n=$((n + 1))
    if [ -f "$d/.done" ]; then
      st="done"
      if [ -f "$d/job.env" ] && [ "$d/job.env" -nt "$d/.done" ]; then st="pending (job.env edited)"; fi
    elif [ -f "$d/.error" ]; then
      st="error (see report.txt)"
    else
      st=pending
    fi
    if [ -f "$d/.done" ]; then
      printf '  %-30s %-26s %11s %4s %6s\n' "$name" "$st" \
        "$(human_size "$(kv_get "$d/.done" output_bytes)")" "$(kv_get "$d/.done" crf)" "$(kv_get "$d/.done" vmaf)"
    else
      printf '  %-30s %-26s %11s %4s %6s\n' "$name" "$st" - - -
    fi
  done
  [ "$n" -gt 0 ] || echo "  (no jobs yet)"
  n=0; for f in inbox/*; do case "$f" in *.env) ;; *) [ -f "$f" ] && n=$((n + 1)) ;; esac; done
  echo "  inbox/: $n video(s) waiting"
  for f in inbox/*.env; do
    [ -f "$f" ] || continue
    if [ -f "${f%.env}" ]; then
      echo "    $(basename "$f"): settings for $(basename "${f%.env}")"
    else
      echo "    $(basename "$f"): no matching video (orphaned settings)"
    fi
  done
  n=0; for f in failed/*; do case "$f" in *.reason.txt) ;; *) [ -e "$f" ] && n=$((n + 1)) ;; esac; done
  echo "  failed/: $n rejected item(s)"
}

# inspect <file|job> — print what would be done, without encoding
inspect() {
  local arg="$1" path host_path
  if [ -d "work/$arg" ]; then
    path="$(job_source "work/$arg")" || die "Job '$arg' has no source"
    host_path="$path"
    config_resolve "work/$arg/job.env"
  else
    [ -f "$arg" ] || die "Not a file or job name: $arg"
    if [ -f "$arg.env" ]; then
      info "Applying settings sidecar $(basename "$arg").env"
      config_resolve "$arg.env"
    else
      config_resolve ""
    fi
    host_path="$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")"
    path="$host_path"
    case "$path" in
      "$ROOT_DIR"/*) path="${path#"$ROOT_DIR"/}" ;;
      *) if [ "$RUNNER" = docker ]; then FF_MOUNT_DIR="$(dirname "$path")"; path="/in/$(basename "$path")"; fi ;;
    esac
  fi
  probe_source "$path" "$host_path" || die "$arg: no readable video stream"
  plan_output
  bold "== $arg =="
  local transfer="$SRC_TRANSFER"
  [ "$transfer" != unknown ] || transfer=""
  echo "  Source:  $(human_size "$SRC_BYTES") | ${SRC_W}x${SRC_H}$( [ "$SRC_ROT" = 0 ] || printf ' rotated %s° -> %sx%s' "$SRC_ROT" "$DISP_W" "$DISP_H") @ $(fmt_num "$SRC_FPS") fps | $(fmt_num "$SRC_DURATION") s | $SRC_PIXFMT${transfer:+ | $transfer} | audio: ${SRC_AUDIO:-none}${SRC_AUDIO_CH:+ ${SRC_AUDIO_CH}ch}"
  echo "  Planned: ${OUT_W}x${OUT_H} @ $( [ "$OUT_FPS" = keep ] && printf 'source fps' || printf '%s fps' "$OUT_FPS") | audio: $AUDIO_PLAN | filters: $FILTERS"
  if [ "$CRF_FINAL" != auto ]; then
    echo "  Quality: fixed CRF $CRF_FINAL"
  elif [ "$VMAF" = on ]; then
    echo "  Quality: auto — highest CRF in '$CRFS' with VMAF >= $VMAF_TARGET"
  else
    echo "  Quality: CRF_FALLBACK=$CRF_FALLBACK (VMAF off)"
  fi
  FF_MOUNT_DIR=""
}
