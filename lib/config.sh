# lib/config.sh — settings, lowest to highest precedence:
#   built-in defaults < config.env < work/<job>/job.env < environment variables
# Config files are parsed as KEY=VALUE (never executed); unknown keys are ignored.

CONFIG_KEYS="CRF_FINAL CRFS CRF_FALLBACK VMAF VMAF_TARGET MAX_DIMENSION FPS MAX_FPS AUDIO AUDIO_BITRATE X264_PRESET POSTER_TIME FFMPEG_RUNNER FFMPEG_IMAGE WATCH_INTERVAL INBOX_SETTLE"
# These pick the toolchain or drive the inbox, so they can't vary per job
GLOBAL_ONLY_KEYS="FFMPEG_RUNNER FFMPEG_IMAGE WATCH_INTERVAL INBOX_SETTLE"

config_defaults() {  # keep in sync with config.env
  CRF_FINAL=auto
  CRFS="20 22 24 26 28 30 32 34"
  CRF_FALLBACK=26
  VMAF=on
  VMAF_TARGET=90
  MAX_DIMENSION=1920
  FPS=auto
  MAX_FPS=30
  AUDIO=keep
  AUDIO_BITRATE=128k
  X264_PRESET=slow
  POSTER_TIME=1
  FFMPEG_RUNNER=auto
  FFMPEG_IMAGE=linuxserver/ffmpeg:9.0-cli-ls81
  WATCH_INTERVAL=10
  INBOX_SETTLE=10
}

# Remember settings passed as environment variables so they can be re-applied
# after the config files load. Must run before config_defaults.
config_snapshot_env() {
  local k
  for k in $CONFIG_KEYS; do
    if eval "[ -n \"\${$k+set}\" ]"; then
      eval "ENV_SET_$k=1; ENV_VAL_$k=\$$k"
    fi
  done
}

config_load_file() {  # config_load_file <file> <global|job>
  local file="$1" scope="$2" line key val n=0
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="$(trim "$line")"
    case "$line" in ''|'#'*) continue ;; esac
    line="${line#export }"
    case "$line" in
      *=*) ;;
      *) warn "$file:$n: ignoring line without '=': $line"; continue ;;
    esac
    key="$(trim "${line%%=*}")"
    val="$(trim "${line#*=}")"
    case "$val" in
      \"*) val="${val#\"}"; val="${val%%\"*}" ;;
      \'*) val="${val#\'}"; val="${val%%\'*}" ;;
      *)   val="$(trim "${val%%#*}")" ;;
    esac
    if ! in_words "$key" "$CONFIG_KEYS"; then
      warn "$file:$n: unknown setting '$key' ignored"
      continue
    fi
    if [ "$scope" = job ] && in_words "$key" "$GLOBAL_ONLY_KEYS"; then
      warn "$file:$n: $key can only be set in config.env or the environment"
      continue
    fi
    eval "$key=\$val"  # key is whitelisted; the value is assigned literally
  done < "$file"
}

config_resolve() {  # config_resolve [job.env]
  local k
  config_defaults
  config_load_file config.env global
  [ -z "${1:-}" ] || config_load_file "$1" job
  for k in $CONFIG_KEYS; do
    if eval "[ \"\${ENV_SET_$k:-}\" = 1 ]"; then
      eval "$k=\$ENV_VAL_$k"
    fi
  done
  config_validate
}

is_crf() { is_int "$1" && [ "$1" -ge 1 ] && [ "$1" -le 51 ]; }

config_validate() {
  local c
  [ "$CRF_FINAL" = auto ] || is_crf "$CRF_FINAL" || die "CRF_FINAL must be 'auto' or 1-51 (got '$CRF_FINAL')"
  [ -n "$(trim "$CRFS")" ] || die "CRFS is empty"
  for c in $CRFS; do is_crf "$c" || die "CRFS values must be 1-51 (got '$c')"; done
  is_crf "$CRF_FALLBACK" || die "CRF_FALLBACK must be 1-51 (got '$CRF_FALLBACK')"
  in_words "$VMAF" "on off" || die "VMAF must be 'on' or 'off' (got '$VMAF')"
  is_number "$VMAF_TARGET" || die "VMAF_TARGET must be a number (got '$VMAF_TARGET')"
  { is_int "$MAX_DIMENSION" && [ "$MAX_DIMENSION" -ge 16 ]; } || die "MAX_DIMENSION must be a whole number >= 16 (got '$MAX_DIMENSION')"
  case "$FPS" in
    auto|keep) ;;
    *) { is_number "$FPS" && num_gt "$FPS" 0; } || die "FPS must be auto, keep or a number (got '$FPS')" ;;
  esac
  { is_number "$MAX_FPS" && num_gt "$MAX_FPS" 0; } || die "MAX_FPS must be a positive number (got '$MAX_FPS')"
  in_words "$AUDIO" "keep strip" || die "AUDIO must be 'keep' or 'strip' (got '$AUDIO')"
  case "$AUDIO_BITRATE" in
    *[!0-9k]*|k*|'') die "AUDIO_BITRATE must look like 128k (got '$AUDIO_BITRATE')" ;;
  esac
  in_words "$X264_PRESET" "ultrafast superfast veryfast faster fast medium slow slower veryslow placebo" \
    || die "X264_PRESET '$X264_PRESET' is not an x264 preset"
  is_number "$POSTER_TIME" || die "POSTER_TIME must be seconds (got '$POSTER_TIME')"
  in_words "$FFMPEG_RUNNER" "auto docker native" || die "FFMPEG_RUNNER must be auto, docker or native (got '$FFMPEG_RUNNER')"
  { is_int "$WATCH_INTERVAL" && [ "$WATCH_INTERVAL" -ge 1 ]; } || die "WATCH_INTERVAL must be whole seconds >= 1 (got '$WATCH_INTERVAL')"
  is_int "$INBOX_SETTLE" || die "INBOX_SETTLE must be whole seconds (got '$INBOX_SETTLE')"
}
