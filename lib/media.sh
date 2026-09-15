# lib/media.sh — ffmpeg runner (native or Docker), probing, output planning,
# encoding, VMAF scoring and posters. All paths are relative to the project root.

RUNNER=""        # native | docker
FFMPEG_ID=""     # identifies the exact ffmpeg build; part of every cache key
HAS_LIBVMAF=0
FF_MOUNT_DIR=""  # extra host dir exposed read-only at /in (Docker), for --inspect

ff() {  # ff <ffmpeg|ffprobe> <args...>
  local tool="$1" extra
  shift
  if [ "$RUNNER" = native ]; then
    "$tool" "$@"
    return
  fi
  extra=()
  [ -z "$FF_MOUNT_DIR" ] || extra=(-v "$FF_MOUNT_DIR":/in:ro)
  docker run --rm --user "$(id -u):$(id -g)" \
    -v "$ROOT_DIR":/work -w /work ${extra[@]+"${extra[@]}"} \
    --entrypoint "$tool" "$FFMPEG_IMAGE" "$@"
}

runner_init() {
  local have_native=0 caps v
  if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    have_native=1
  fi

  case "$FFMPEG_RUNNER" in
    native)
      [ "$have_native" = 1 ] || die "FFMPEG_RUNNER=native but ffmpeg/ffprobe are not on PATH"
      RUNNER=native ;;
    docker)
      RUNNER=docker ;;
    auto)
      RUNNER=docker
      if [ "$have_native" = 1 ]; then
        caps="$(ffmpeg -hide_banner -encoders 2>/dev/null; ffmpeg -hide_banner -filters 2>/dev/null)" || caps=""
        case "$caps" in
          *libx264*)
            case "$VMAF" in off) RUNNER=native ;; esac
            case "$caps" in *libvmaf*) RUNNER=native ;; esac ;;
        esac
      fi ;;
  esac

  if [ "$RUNNER" = docker ]; then
    command -v docker >/dev/null 2>&1 \
      || die "No usable ffmpeg. Install Docker (https://docs.docker.com/get-docker/) or an ffmpeg build with libx264 + libvmaf."
    docker info >/dev/null 2>&1 \
      || die "Docker is installed but not running. Start it and re-run."
    if ! docker image inspect "$FFMPEG_IMAGE" >/dev/null 2>&1; then
      info "Pulling $FFMPEG_IMAGE (first run only)…"
      docker pull -q "$FFMPEG_IMAGE" >/dev/null || die "Could not pull $FFMPEG_IMAGE"
    fi
    FFMPEG_ID="$(docker image inspect -f '{{.Id}}' "$FFMPEG_IMAGE")"
    FFMPEG_ID="${FFMPEG_ID#sha256:}"
    FFMPEG_ID="docker:${FFMPEG_ID:0:12}"
  else
    v="$(ffmpeg -version 2>/dev/null)" || v=""
    set -- ${v%%$'\n'*}
    FFMPEG_ID="native:${3:-unknown}"
  fi

  # Capture before matching: piping into `grep -q` SIGPIPEs ffmpeg under pipefail
  caps="$(ff ffmpeg -hide_banner -encoders 2>/dev/null; ff ffmpeg -hide_banner -filters 2>/dev/null)" || caps=""
  case "$caps" in *libx264*) ;; *) die "The $RUNNER ffmpeg has no libx264 encoder" ;; esac
  case "$caps" in *libvmaf*) HAS_LIBVMAF=1 ;; *) HAS_LIBVMAF=0 ;; esac

  if [ "$HAS_LIBVMAF" = 1 ]; then
    ok "ffmpeg: $RUNNER ($FFMPEG_ID)"
  else
    ok "ffmpeg: $RUNNER ($FFMPEG_ID, no libvmaf — VMAF=on jobs will fail)"
  fi
}

# probe_source <path> [host-path] — sets SRC_* for <path>. The host path is only
# needed when ffmpeg sees the file elsewhere (Docker /in mount, for --inspect).
# Returns 1 when there is no readable video stream.
probe_source() {
  local path="$1" host_path="${2:-$1}" out key val avg="" rfr=""
  SRC_W=""; SRC_H=""; SRC_ROT=0; SRC_FPS=0; SRC_DURATION=0
  SRC_PIXFMT=""; SRC_TRANSFER=""; SRC_HAS_AUDIO=0; SRC_AUDIO=""; SRC_AUDIO_CH=""

  # V (capital) skips attached pictures such as cover art
  out="$(ff ffprobe -v error -select_streams V:0 \
    -show_entries stream=width,height,avg_frame_rate,r_frame_rate,pix_fmt,color_transfer:stream_side_data=rotation:format=duration \
    -of default=noprint_wrappers=1 "$path" 2>/dev/null)" || return 1
  while IFS='=' read -r key val; do
    case "$key" in
      width) SRC_W="$val" ;;
      height) SRC_H="$val" ;;
      avg_frame_rate) avg="$val" ;;
      r_frame_rate) rfr="$val" ;;
      pix_fmt) SRC_PIXFMT="$val" ;;
      color_transfer) SRC_TRANSFER="$val" ;;
      rotation) SRC_ROT="$val" ;;
      duration) SRC_DURATION="$val" ;;
    esac
  done <<EOF
$out
EOF
  is_int "$SRC_W" && is_int "$SRC_H" || return 1
  is_number "$SRC_DURATION" || SRC_DURATION=0

  SRC_ROT="$(awk -v r="$SRC_ROT" 'BEGIN{ r = int(r) % 360; if (r < 0) r += 360; print r }')"
  SRC_FPS="$(awk -v a="$avg" -v r="$rfr" 'BEGIN{
    n = split(a, x, "/"); f = (n == 2 && x[2] > 0) ? x[1] / x[2] : 0
    if (f <= 0) { n = split(r, y, "/"); f = (n == 2 && y[2] > 0) ? y[1] / y[2] : 0 }
    printf "%.3f", f }')"

  out="$(ff ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,channels \
    -of default=noprint_wrappers=1 "$path" 2>/dev/null)" || out=""
  while IFS='=' read -r key val; do
    case "$key" in
      codec_name) SRC_AUDIO="$val"; SRC_HAS_AUDIO=1 ;;
      channels) SRC_AUDIO_CH="$val" ;;
    esac
  done <<EOF
$out
EOF
  SRC_BYTES="$(file_bytes "$host_path")"
}

# Derives OUT_W/OUT_H/OUT_FPS, the ffmpeg filter chain and audio args from SRC_*
# and the current settings. The same FILTERS are applied to the VMAF reference.
plan_output() {
  local size parts=""
  DISP_W="$SRC_W"; DISP_H="$SRC_H"
  case "$SRC_ROT" in 90|270) DISP_W="$SRC_H"; DISP_H="$SRC_W" ;; esac  # ffmpeg autorotates

  # Cap the longest side (works for landscape, portrait and square) and keep
  # dimensions even, as yuv420p requires. Never upscales.
  size="$(awk -v w="$DISP_W" -v h="$DISP_H" -v m="$MAX_DIMENSION" 'BEGIN{
    long = (w > h) ? w : h; s = (long > m) ? m / long : 1
    ow = int(w * s / 2) * 2; oh = int(h * s / 2) * 2
    if (ow < 2) ow = 2; if (oh < 2) oh = 2
    print ow " " oh }')"
  OUT_W="${size% *}"; OUT_H="${size#* }"
  if [ "$OUT_W" != "$DISP_W" ] || [ "$OUT_H" != "$DISP_H" ]; then
    parts="scale=$OUT_W:$OUT_H:flags=lanczos"
  fi

  # The fps filter (not -r) so VMAF can select the identical frames from the source
  OUT_FPS=keep
  case "$FPS" in
    keep) ;;
    auto) if num_gt "$SRC_FPS" "$MAX_FPS"; then OUT_FPS="$MAX_FPS"; fi ;;
    *)    if num_gt "$SRC_FPS" "$FPS"; then OUT_FPS="$FPS"; fi ;;
  esac
  if [ "$OUT_FPS" != keep ]; then
    parts="${parts:+$parts,}fps=$OUT_FPS"
  fi
  FILTERS="${parts:-null}"

  # Encoder tuning and rate cap; recorded in VIDEO_PLAN only when set, so default
  # runs keep their existing cache keys
  VIDEO_ARGS=(); VIDEO_PLAN=""
  if [ "$X264_TUNE" != none ]; then
    VIDEO_ARGS+=(-tune "$X264_TUNE")
    VIDEO_PLAN="tune=$X264_TUNE"
  fi
  if [ "$MAX_BITRATE" != none ]; then
    local rate="${MAX_BITRATE%[kM]}" unit="${MAX_BITRATE#"${MAX_BITRATE%[kM]}"}"
    VIDEO_ARGS+=(-maxrate "$MAX_BITRATE" -bufsize "$((rate * 2))$unit")
    VIDEO_PLAN="${VIDEO_PLAN:+$VIDEO_PLAN }maxrate=$MAX_BITRATE"
  fi

  if [ "$AUDIO" = keep ] && [ "$SRC_HAS_AUDIO" = 1 ]; then
    AUDIO_PLAN="aac-$AUDIO_BITRATE"
    AUDIO_ARGS=(-map 0:a:0 -c:a aac -b:a "$AUDIO_BITRATE")
    case "$AUDIO_CHANNELS" in
      mono)
        AUDIO_ARGS+=(-ac 1); AUDIO_PLAN="$AUDIO_PLAN-mono" ;;
      stereo)
        AUDIO_ARGS+=(-ac 2); AUDIO_PLAN="$AUDIO_PLAN-stereo" ;;
      auto)  # downmix surround, leave mono and stereo alone
        if is_int "$SRC_AUDIO_CH" && [ "$SRC_AUDIO_CH" -gt 2 ]; then
          AUDIO_ARGS+=(-ac 2); AUDIO_PLAN="$AUDIO_PLAN-stereo"
        fi ;;
    esac
  else
    AUDIO_PLAN=none
    AUDIO_ARGS=(-an)
  fi
}

candidate_key() {  # everything that affects a candidate's bytes
  printf 'crf=%s size=%sx%s fps=%s preset=%s audio=%s engine=%s%s' \
    "$1" "$OUT_W" "$OUT_H" "$OUT_FPS" "$X264_PRESET" "$AUDIO_PLAN" "$FFMPEG_ID" "${VIDEO_PLAN:+ $VIDEO_PLAN}"
}

# encode_candidate <job-dir> <source> <crf> — sets CAND, CAND_KEY, CAND_STATUS and
# CAND_WARN (errors ffmpeg logged while still exiting 0, e.g. a truncated source).
# Reuses an existing encode only when its .settings sidecar matches exactly.
encode_candidate() {
  local dir="$1/candidates" src="$2" crf="$3" tmp log
  CAND="$dir/crf$crf.mp4"
  CAND_KEY="$(candidate_key "$crf")"
  mkdir -p "$dir"

  if [ -s "$CAND" ] && [ -f "$CAND.settings" ] && [ "$(cat "$CAND.settings")" = "$CAND_KEY" ]; then
    CAND_STATUS=cached
  else
    CAND_STATUS=encoded
    info "Encoding CRF $crf…"
    rm -f "$CAND.settings" "$CAND.vmaf" "$CAND.log"
    tmp="$dir/.crf$crf.partial.mp4"
    log="$dir/.crf$crf.partial.log"
    if ! ff ffmpeg -hide_banner -loglevel error -nostats -y \
      -i "$src" -map 0:V:0 "${AUDIO_ARGS[@]}" \
      -map_metadata -1 -map_chapters -1 \
      -c:v libx264 -crf "$crf" -preset "$X264_PRESET" ${VIDEO_ARGS[@]+"${VIDEO_ARGS[@]}"} \
      -profile:v high -pix_fmt yuv420p \
      -vf "$FILTERS" -movflags +faststart \
      "$tmp" 2> "$log"; then
      cat "$log" >&2
      die "ffmpeg failed encoding CRF $crf"
    fi
    mv -f "$tmp" "$CAND"
    if [ -s "$log" ]; then mv -f "$log" "$CAND.log"; else rm -f "$log"; fi
    # Written only after a successful encode, so an interrupted one is redone
    printf '%s\n' "$CAND_KEY" > "$CAND.settings"
  fi

  CAND_WARN=""
  if [ -s "$CAND.log" ]; then
    CAND_WARN="$(sed 's/^\[[^]]*\] //' "$CAND.log" | sort -u | head -n 3 | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
  fi
}

# candidate_vmaf <source> <crf> — sets CAND_SCORE for $CAND (cached in $CAND.vmaf).
# The reference is the source through the same FILTERS, so frames align and the
# score reflects compression loss only. n_threads=0 is deliberate: libvmaf's
# thread pool queues decoded frames without bound and got OOM-killed on a 58 s
# 1080p source with 8 GB for Docker; single-threaded stays near 420 MB.
candidate_vmaf() {
  local log
  if [ -f "$CAND.vmaf" ] && [ "$(sed -n 1p "$CAND.vmaf")" = "$CAND_KEY" ]; then
    CAND_SCORE="$(sed -n 2p "$CAND.vmaf")"
    return 0
  fi
  [ "$HAS_LIBVMAF" = 1 ] || die "VMAF=on but this ffmpeg has no libvmaf (set VMAF=off or use the Docker runner)"

  info "Measuring VMAF for CRF $2 (roughly real-time)…"
  log="$(ff ffmpeg -hide_banner -nostats -i "$CAND" -i "$1" \
    -lavfi "[0:v:0]format=yuv420p,setsar=1,settb=AVTB,setpts=PTS-STARTPTS[d];[1:V:0]$FILTERS,format=yuv420p,setsar=1,settb=AVTB,setpts=PTS-STARTPTS[r];[d][r]libvmaf=n_threads=0" \
    -f null - 2>&1)" || die "VMAF measurement failed for $CAND"
  CAND_SCORE="$(printf '%s\n' "$log" | sed -n 's/.*VMAF score: \([0-9.]*\).*/\1/p' | tail -n 1)"
  [ -n "$CAND_SCORE" ] || die "VMAF produced no score for $CAND"
  CAND_SCORE="$(awk -v s="$CAND_SCORE" 'BEGIN{ printf "%.2f", s }')"
  printf '%s\n%s\n' "$CAND_KEY" "$CAND_SCORE" > "$CAND.vmaf"
}

make_posters() {  # make_posters <video> <output-prefix> — taken from the delivered encode
  local t
  t="$(awk -v p="$POSTER_TIME" -v d="$SRC_DURATION" 'BEGIN{ if (d > 0 && p > d / 2) p = d / 2; printf "%.3f", p }')"
  ff ffmpeg -hide_banner -loglevel error -y -ss "$t" -i "$1" -frames:v 1 -q:v 3 "$2.jpg"
  ff ffmpeg -hide_banner -loglevel error -y -ss "$t" -i "$1" -frames:v 1 -quality 80 "$2.webp"
}
