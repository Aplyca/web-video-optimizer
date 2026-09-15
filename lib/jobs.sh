# lib/jobs.sh — the drop-folder workflow: inbox/ -> videos/<name>/
#
# Everything about one video lives in videos/<name>/:
#   source.<ext>   the original (moved out of inbox/)
#   job.env        per-video settings (template written on first run)
#   report.txt     history of every run
#   compare.html   plays the original and any encode side by side, with the
#                  results (lib/compare.sh; rebuilt on every delivery)
#   output/       <name>.mp4, <name>-poster.jpg/.webp, report.txt (latest run)
#   preview/       frames sampled with --frames (scratch)
#   candidates/    crfNN.mp4 encodes + .settings/.vmaf cache sidecars (scratch)
#   .job .done .error   bookkeeping
# videos/_previews/<name>/ holds frames sampled from files that aren't jobs yet;
# job names are slugs ([a-z0-9-]), so they never start with "_".

VIDEO_EXTS="mp4 m4v mov mkv webm avi wmv flv mpg mpeg mts m2ts ts 3gp ogv"
PARTIAL_EXTS="part crdownload download tmp partial"

RUN_NAMES=(); RUN_STATUS=(); RUN_FAILED=0
ADDED_FILES=""  # newline-delimited inbox paths this run copied in itself (known complete)

ensure_dirs() {
  mkdir -p inbox videos failed
  if [ -d work ] || [ -d output ]; then
    warn "Found work/ or output/ from an older version. Jobs now live in videos/<name>/ (outputs in videos/<name>/output/); move them there or re-run the sources."
  fi
}

abs_path() {  # abs_path <path> — relative paths resolve from where optimize.sh was run
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

is_job() {  # is_job <name> — an existing job folder (not _previews, not a path)
  case "$1" in ''|_*|.*|*/*) return 1 ;; esac
  [ -d "videos/$1" ]
}

job_names() {  # prints one job name per line
  local d name
  for d in videos/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    case "$name" in _*) continue ;; esac
    printf '%s\n' "$name"
  done
}

lock_acquire() {
  local lock="videos/.lock" pid
  if ! mkdir "$lock" 2>/dev/null; then
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      die "Another optimize.sh run (pid $pid) is using this project. Stop it or wait for it to finish."
    fi
    rm -rf "$lock"
    mkdir "$lock"
  fi
  echo "$$" > "$lock/pid"
  trap 'rm -rf "$ROOT_DIR/videos/.lock"' EXIT
  trap 'exit 130' INT TERM
}

job_source() {  # job_source <job-dir> — prints the source path
  local s
  for s in "$1"/source.*; do
    if [ -f "$s" ]; then printf '%s' "$s"; return 0; fi
  done
  return 1
}

unique_name() {  # unique_name <slug> — not used by any job or failed entry
  local n="$1" i=2
  while [ -e "videos/$n" ] || [ -e "failed/$n" ]; do
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
      # curl runs inside the Docker image like everything else. Hidden while
      # downloading so a concurrent watcher ignores it
      if ! ff curl -fL "${CURL_PROGRESS[@]}" -o "inbox/.$name.part" "$arg"; then
        rm -f "inbox/.$name.part"
        case "$arg" in
          *://localhost*|*://127.0.0.1*)
            die "Download failed: $arg — downloads run inside Docker, where localhost is the container; use host.docker.internal instead" ;;
          *) die "Download failed: $arg" ;;
        esac
      fi
      dest="inbox/$name"
      [ ! -e "$dest" ] || dest="inbox/$(date +%Y%m%d-%H%M%S)-$name"
      mv "inbox/.$name.part" "$dest"
      ;;
    *)
      arg="$(abs_path "$arg")"
      [ -f "$arg" ] || die "Not a file or URL: $1"
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
        warn "inbox/$(basename "$f") has no matching video (expected inbox/$(basename "${f%.env}")). If that video was already queued, put the settings in its videos/<name>/job.env"
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
    mkdir -p "videos/$name"
    mv "$f" "videos/$name/source.$ext"
    printf 'original_name=%s\nqueued=%s\n' "$(basename "$f")" "$(date '+%Y-%m-%d %H:%M:%S')" > "videos/$name/.job"
    if [ -f "$f.env" ]; then
      { echo "# Settings from inbox/$(basename "$f").env"; cat "$f.env"; } > "videos/$name/job.env"
      rm -f "$f.env"
      printf 'sidecar=%s\n' "$(basename "$f").env" >> "videos/$name/.job"
      ok "Queued $(basename "$f") as videos/$name/ with settings from $(basename "$f").env"
    else
      ok "Queued $(basename "$f") as videos/$name/"
    fi
  done
}

job_pending() {  # not yet delivered, or job.env edited since the last delivery
  local d="videos/$1"
  job_source "$d" >/dev/null || return 1
  [ -f "$d/.done" ] || return 0
  [ -f "$d/job.env" ] && [ "$d/job.env" -nt "$d/.done" ]
}

write_job_env() {  # write_job_env <job-dir> <name> — commented template of every setting
  cat > "$1/job.env" <<EOF
# Per-video settings for '$2'.
# Uncomment and edit a line to override config.env for this video only, then run
# ./optimize.sh again: the video is re-processed automatically, reusing any
# encodes and VMAF scores whose settings still match.
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
# auto | mono | stereo
#AUDIO_CHANNELS=$AUDIO_CHANNELS

#X264_PRESET=$X264_PRESET
# none | film | animation | grain | stillimage
#X264_TUNE=$X264_TUNE
# none, or a peak video bitrate cap such as 900k or 3M
#MAX_BITRATE=$MAX_BITRATE
#POSTER_TIME=$POSTER_TIME
EOF
}

rlog() { printf '%s\n' "$*" >> "$REPORT_RUN"; }

# Runs inside a subshell with `set -e` (see run_job); any failure aborts the job only.
process_job() {
  local name="$1" d="videos/$1" src overrides key sidecar crf_list mode crf pct kbps chosen="" score="" lowest="" lowest_score="" od warnings=0
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
  elif ! grep -q '^# Per-video settings for' "$d/job.env"; then
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
  info "Output: ${OUT_W}x${OUT_H} @ $( [ "$OUT_FPS" = keep ] && printf 'source fps' || printf '%s fps' "$OUT_FPS") | audio: $AUDIO_PLAN | preset $X264_PRESET${VIDEO_PLAN:+ | $VIDEO_PLAN}"
  rlog "##### Run $(date '+%Y-%m-%d %H:%M:%S') #####"
  rlog "Source:  $(kv_get "$d/.job" original_name) | $(human_size "$SRC_BYTES") | ${SRC_W}x${SRC_H}$( [ "$SRC_ROT" = 0 ] || printf ' rotated %s°' "$SRC_ROT") @ $(fmt_num "$SRC_FPS") fps | $(fmt_num "$SRC_DURATION") s | ${SRC_PIXFMT} | audio: ${SRC_AUDIO:-none}"
  rlog "Output:  ${OUT_W}x${OUT_H} @ $( [ "$OUT_FPS" = keep ] && printf 'source fps' || printf '%s fps' "$OUT_FPS") | audio: $AUDIO_PLAN | x264 preset $X264_PRESET${VIDEO_PLAN:+ | $VIDEO_PLAN} | $FFMPEG_ID"
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
  od="$d/output"
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
  # A page problem never fails a delivered video; --compare can rebuild it
  if write_compare_page "$name"; then
    ok "Comparison page: $d/compare.html"
  else
    warn "Could not write $d/compare.html (retry with ./optimize.sh --compare $name)"
  fi
}

run_job() {
  local name="$1" d="videos/$1" rc
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
  warn "'$name' failed (exit $rc). Fix the cause and run again; see $d/report.txt"
}

process_pending() {
  local d name
  for name in $(job_names); do
    d="videos/$name"
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
  printf '  %-30s %11s %11s %7s %4s %6s  %s\n' VIDEO SOURCE OUTPUT SAVED CRF VMAF STATUS
  for i in "${!RUN_NAMES[@]}"; do
    name="${RUN_NAMES[$i]}"; st="${RUN_STATUS[$i]}"; d="videos/$name"
    if [ "$st" = "done" ]; then
      printf '  %-30s %11s %11s %6s%% %4s %6s  %s\n' "$name" \
        "$(human_size "$(kv_get "$d/.done" source_bytes)")" "$(human_size "$(kv_get "$d/.done" output_bytes)")" \
        "$(kv_get "$d/.done" reduction)" "$(kv_get "$d/.done" crf)" "$(kv_get "$d/.done" vmaf)" \
        "$d/output/$( [ "$(kv_get "$d/.done" warnings)" = 0 ] || printf ' (WARNINGS, see report)')"
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
    [ -n "${1:-}" ] || ok "Nothing to do: inbox/ is empty and every video is up to date (see --list)"
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

redo_jobs() {  # redo_jobs <name|all>... — mark videos pending again
  local n
  for n in "$@"; do
    if [ "$n" = all ]; then
      for n in $(job_names); do rm -f "videos/$n/.done" "videos/$n/.error"; done
      ok "All videos marked for re-processing"
      return 0
    fi
    is_job "$n" || die "No video named '$n' (see ./optimize.sh --list)"
    rm -f "videos/$n/.done" "videos/$n/.error"
    ok "'$n' marked for re-processing"
  done
}

# collect <dir> — copy every delivered MP4 and its posters into one flat folder
collect() {
  local dest name od f n=0
  dest="$(abs_path "$1")"
  mkdir -p "$dest"
  for name in $(job_names); do
    od="videos/$name/output"
    if [ ! -f "videos/$name/.done" ] || [ ! -f "$od/$name.mp4" ]; then continue; fi
    for f in "$od/$name.mp4" "$od/$name-poster.jpg" "$od/$name-poster.webp"; do
      if [ -f "$f" ]; then cp -f "$f" "$dest/"; fi
    done
    n=$((n + 1))
  done
  if [ "$n" -eq 0 ]; then
    warn "No delivered videos to collect yet (see ./optimize.sh --list)"
  else
    ok "Copied $n video(s) and their posters to $dest"
  fi
}

# clean <name|all>... — delete candidate encodes and sampled frames. Sources,
# settings, reports and outputs stay; a later re-run simply encodes again.
clean_jobs() {
  local n targets p kb
  targets=()
  for n in "$@"; do
    if [ "$n" = all ]; then
      for n in $(job_names); do targets+=("videos/$n/candidates" "videos/$n/preview"); done
      targets+=("videos/_previews")
    else
      is_job "$n" || die "No video named '$n' (see ./optimize.sh --list)"
      targets+=("videos/$n/candidates" "videos/$n/preview")
    fi
  done
  kb=0
  for p in ${targets[@]+"${targets[@]}"}; do
    if [ -d "$p" ]; then
      kb=$((kb + $(du -sk "$p" | awk '{print $1}')))
      rm -rf "$p"
    fi
  done
  ok "Removed candidate encodes and previews, freed $(human_size $((kb * 1024))). Outputs, sources and reports are kept."
  info "Comparison pages still compare the original and the delivered file; run ./optimize.sh --compare to drop removed encodes from them."
}

list_jobs() {
  local d name st n=0 f
  printf '  %-30s %-26s %11s %4s %6s\n' VIDEO STATUS OUTPUT CRF VMAF
  for name in $(job_names); do
    d="videos/$name"; n=$((n + 1))
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
  [ "$n" -gt 0 ] || echo "  (no videos yet)"
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

# resolve_input <file|name> — sets IN_PATH (as ffmpeg sees it), IN_HOST (host
# path), IN_NAME and IN_JOB (video name, or empty for a plain file), and resolves
# settings: the video's job.env, or a <file>.env sidecar next to a plain file.
resolve_input() {
  local arg="$1"
  IN_JOB=""; FF_MOUNT_DIR=""
  if is_job "$arg"; then
    IN_JOB="$arg"; IN_NAME="$arg"
    IN_PATH="$(job_source "videos/$arg")" || die "'$arg' has no source file"
    IN_HOST="$IN_PATH"
    config_resolve "videos/$arg/job.env"
    return 0
  fi
  arg="$(abs_path "$arg")"
  [ -f "$arg" ] || die "Not a file or video name: $1"
  IN_NAME="$(slugify "$(basename "${arg%.*}")")"
  if [ -f "$arg.env" ]; then
    info "Applying settings sidecar $(basename "$arg").env"
    config_resolve "$arg.env"
  else
    config_resolve ""
  fi
  IN_HOST="$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")"
  IN_PATH="$IN_HOST"
  case "$IN_PATH" in
    "$ROOT_DIR"/*) IN_PATH="${IN_PATH#"$ROOT_DIR"/}" ;;
    *) FF_MOUNT_DIR="$(dirname "$IN_PATH")"; IN_PATH="/in/$(basename "$IN_PATH")" ;;  # mounted read-only
  esac
}

# inspect <file|name> — print what would be done, without encoding
inspect() {
  local transfer kbps d
  resolve_input "$1"
  probe_source "$IN_PATH" "$IN_HOST" || die "$1: no readable video stream"
  plan_output
  transfer="$SRC_TRANSFER"
  [ "$transfer" != unknown ] || transfer=""
  kbps="$(awk -v a="$SRC_BYTES" -v d="$SRC_DURATION" 'BEGIN{ if (d > 0) printf "%d", a * 8 / d / 1000; else print "?" }')"
  bold "== $1 =="
  echo "  Source:  $(human_size "$SRC_BYTES") | ${SRC_W}x${SRC_H}$( [ "$SRC_ROT" = 0 ] || printf ' rotated %s° -> %sx%s' "$SRC_ROT" "$DISP_W" "$DISP_H") @ $(fmt_num "$SRC_FPS") fps | $(fmt_num "$SRC_DURATION") s | $kbps kb/s | $SRC_PIXFMT${transfer:+ | $transfer} | audio: ${SRC_AUDIO:-none}${SRC_AUDIO_CH:+ ${SRC_AUDIO_CH}ch}"
  echo "  Planned: ${OUT_W}x${OUT_H} @ $( [ "$OUT_FPS" = keep ] && printf 'source fps' || printf '%s fps' "$OUT_FPS") | audio: $AUDIO_PLAN | preset $X264_PRESET${VIDEO_PLAN:+ | $VIDEO_PLAN} | filters: $FILTERS"
  if [ "$CRF_FINAL" != auto ]; then
    echo "  Quality: fixed CRF $CRF_FINAL"
  elif [ "$VMAF" = on ]; then
    echo "  Quality: auto — highest CRF in '$CRFS' with VMAF >= $VMAF_TARGET"
  else
    echo "  Quality: CRF_FALLBACK=$CRF_FALLBACK (VMAF off)"
  fi
  d="videos/$IN_JOB"
  if [ -n "$IN_JOB" ] && [ -f "$d/.done" ]; then
    echo "  Last run: CRF $(kv_get "$d/.done" crf)$( [ -z "$(kv_get "$d/.done" vmaf)" ] || printf ', VMAF %s' "$(kv_get "$d/.done" vmaf)"), $(human_size "$(kv_get "$d/.done" output_bytes)") (-$(kv_get "$d/.done" reduction)%) on $(kv_get "$d/.done" finished)"
  fi
  FF_MOUNT_DIR=""
}

# frames <file|name> [count] — save evenly spaced frames for visual review, to
# videos/<name>/preview/ for a video, or videos/_previews/<name>/ for a plain file.
# Before encoding they are capped at 1280 px wide to stay light. For a delivered
# video each timestamp gets a source frame scaled to the output size and the
# output frame at native size, so artifacts aren't hidden by scaling.
frames() {
  local count="${2:-6}" out delivered="" i t label scale f
  { is_int "$count" && [ "$count" -ge 1 ] && [ "$count" -le 60 ]; } || die "Frame count must be 1-60 (got '$count')"
  resolve_input "$1"
  probe_source "$IN_PATH" "$IN_HOST" || die "$1: no readable video stream"
  plan_output
  scale="scale='min(1280,iw)':-2"
  if [ -n "$IN_JOB" ]; then
    out="videos/$IN_JOB/preview"
    if [ -f "videos/$IN_JOB/output/$IN_JOB.mp4" ]; then
      delivered="videos/$IN_JOB/output/$IN_JOB.mp4"
      scale="scale=$OUT_W:$OUT_H:flags=lanczos"
    fi
  else
    out="videos/_previews/$IN_NAME"
  fi
  rm -rf "$out"
  mkdir -p "$out"
  info "Sampling $count frame(s) from $1$( [ -z "$delivered" ] || printf ' and %s' "$delivered")…"
  for i in $(seq 1 "$count"); do
    t="$(awk -v d="$SRC_DURATION" -v i="$i" -v n="$count" 'BEGIN{ printf "%.2f", d * (i - 0.5) / n }')"
    label="$(printf '%02d' "$i")"
    ff ffmpeg -hide_banner -loglevel error -y -ss "$t" -i "$IN_PATH" -frames:v 1 -vf "$scale" -q:v 2 "$out/$label-source-${t}s.jpg"
    if [ -n "$delivered" ]; then
      ff ffmpeg -hide_banner -loglevel error -y -ss "$t" -i "$delivered" -frames:v 1 -q:v 2 "$out/$label-output-${t}s.jpg"
    fi
  done
  FF_MOUNT_DIR=""
  ok "Frames written to $out/"
  for f in "$out"/*.jpg; do echo "    $f"; done
}
