# Video Optimization

Drop a video in a folder, get back a web-ready MP4 that is as small as possible
without visible quality loss, plus poster images and a report.

- **Portable:** plain bash (3.2+, so stock macOS works) plus either Docker or a
  local ffmpeg with libx264 and libvmaf. Copy the folder anywhere and run it.
- **Generic:** any container ffmpeg reads, landscape, portrait, square, rotated
  phone clips, odd sizes, high frame rates, with or without audio.
- **Quality-gated:** the encode level (CRF) is picked automatically by measuring
  each attempt with [VMAF](https://github.com/Netflix/vmaf), Netflix's perceptual
  quality score, instead of guessing.

## Quick start

```bash
cp ~/Downloads/my-video.mov inbox/
./optimize.sh
```

Results land in `output/my-video/`:

| File | What it is |
|---|---|
| `my-video.mp4` | H.264 High / yuv420p / AAC, `+faststart`, metadata stripped |
| `my-video-poster.jpg`, `.webp` | Poster frame for `<video poster="…">` |
| `report.txt` | Source details, every CRF tried with size and VMAF, the choice |

Or leave a watcher running and just drop files into `inbox/`:

```bash
./optimize.sh --watch
```

## Commands

| Command | Does |
|---|---|
| `./optimize.sh` | Process every video in `inbox/`, plus unfinished jobs |
| `./optimize.sh FILE\|URL …` | Copy or download into `inbox/`, then process |
| `./optimize.sh --watch [SECONDS]` | Keep processing whatever lands in `inbox/` |
| `./optimize.sh --list` | Show jobs and their status |
| `./optimize.sh --redo NAME\|all` | Re-process jobs (matching encodes are reused) |
| `./optimize.sh --inspect FILE\|NAME` | Show source details and the output plan, no encoding |

The exit code is non-zero when any job failed or a file was rejected.

## How it works

```
inbox/ ──ingest──▶ work/<name>/ ──encode + VMAF──▶ output/<name>/
   │                  source.<ext>                   <name>.mp4
   │                  job.env                        <name>-poster.jpg/.webp
   │                  candidates/crfNN.mp4           report.txt
   │                  report.txt (history)
   └──unusable──▶ failed/ (+ reason)
```

1. **Ingest.** Each file in `inbox/` is moved into its own job folder,
   `work/<name>/`, where `<name>` is a slug of the filename (`My Clip.MOV` →
   `my-clip`, with `-2`, `-3`… for repeats). A file is picked up only after it
   has been unchanged for `INBOX_SETTLE` seconds (default 10), so a copy in
   progress isn't processed half-written. For transfers that may stall longer,
   copy under a temporary name such as `video.mp4.part` and rename it when done;
   `.part`, `.crdownload`, `.download` and `.tmp` files are always skipped.
   Non-video, empty and unreadable files go to `failed/` with a `.reason.txt`.
   If ffmpeg reports read errors (a truncated or corrupt source), the job is
   still delivered but flagged with warnings in the summary and report.
2. **Plan.** ffprobe reads the source and the output is planned from the
   settings: the longest side capped at `MAX_DIMENSION` (never upscaled, always
   even), the frame rate capped at `MAX_FPS`, audio kept or stripped. Rotated
   phone videos are turned upright. A `job.env` template describing the source
   and the plan is written for per-video tweaks.
3. **Search.** With `CRF_FINAL=auto`, CRFs from `CRFS` are tried from highest
   (smallest file, fastest) to lowest. Each attempt is scored with VMAF, and the
   first one reaching `VMAF_TARGET` is delivered, so easy content stops after one
   encode and harder content steps down only as far as needed. If nothing reaches
   the target, the best attempt is delivered with a warning.
4. **Deliver.** The chosen encode is copied to `output/<name>/`, posters are taken
   from it (so they match what plays), and the run is appended to the job's
   `report.txt`.

### Caching and re-runs

Every candidate has a `.settings` sidecar recording everything that affects its
bytes: CRF, output size, frame rate, preset, audio plan and the exact ffmpeg
build. VMAF scores are cached the same way. A re-run reuses a candidate only when
its sidecar matches, so changing a setting never serves a stale file, and
re-running with unchanged settings costs seconds.

A job counts as finished once `work/<name>/.done` exists. It is processed again
when its `job.env` is edited or when you run `--redo`. A job that failed is
retried on the next `./optimize.sh`; the watcher skips it until `job.env` changes,
so a broken file isn't retried in a loop. Only one run can use a project at a
time.

### Measuring quality correctly

VMAF compares the encode against the source run through the **same** scale and
frame-rate filters. The score therefore reflects compression loss only, and the
frames stay aligned when the frame rate changes. Comparing a 24 fps encode
directly against a 30 fps source pairs up the wrong frames and gives meaningless
scores around 65–68. For that reason the frame rate is changed with ffmpeg's `fps`
filter rather than `-r`, which selects different frames. libvmaf runs
single-threaded on purpose: its thread pool buffers decoded frames without limit
and was killed for running out of memory on a 1080p source with 8 GB for Docker.

Scoring takes roughly the video's duration per candidate.

## Settings

Settings come from four layers; later layers win:

1. Built-in defaults (`lib/config.sh`)
2. `config.env`, for every video in this project
3. `work/<name>/job.env`, for one video (uncomment lines in the generated template)
4. Environment variables, for one run: `VMAF=off ./optimize.sh`

The config files are parsed as `KEY=VALUE`, never executed.

| Setting | Default | Meaning |
|---|---|---|
| `CRF_FINAL` | `auto` | `auto` searches `CRFS` with VMAF; a number 1–51 forces that CRF |
| `CRFS` | `20 22 … 34` | CRFs the search may try (lower = better quality, bigger file) |
| `CRF_FALLBACK` | `26` | CRF used when `auto` but `VMAF=off` |
| `VMAF` | `on` | `off` skips scoring (much faster, no quality gate) |
| `VMAF_TARGET` | `90` | Minimum score; 90+ is visually transparent for most viewers |
| `MAX_DIMENSION` | `1920` | Longest side in pixels |
| `FPS` | `auto` | `auto` caps at `MAX_FPS`; `keep` never changes it; a number caps to it |
| `MAX_FPS` | `30` | Cap used by `FPS=auto` |
| `AUDIO` | `keep` | `keep` re-encodes to AAC (surround downmixed to stereo); `strip` removes it |
| `AUDIO_BITRATE` | `128k` | AAC bitrate |
| `X264_PRESET` | `slow` | Slower presets give smaller files at the same quality |
| `POSTER_TIME` | `1` | Poster frame time in seconds (clamped to half the duration) |
| `FFMPEG_RUNNER` | `auto` | `auto`, `docker` or `native` (config.env or environment only) |
| `FFMPEG_IMAGE` | `linuxserver/ffmpeg:9.0-cli-ls81` | Docker image, pinned for reproducibility |
| `WATCH_INTERVAL` | `10` | Seconds between inbox checks in `--watch` mode |
| `INBOX_SETTLE` | `10` | Seconds a file must be unchanged before it is picked up |

### Common recipes

**Muted autoplay background or hero video.** Put this in its `job.env`, or in
`config.env` if every video in the project is one:

```
AUDIO=strip
FPS=24
```

**Re-process one video with a fixed CRF:**

```bash
CRF_FINAL=24 ./optimize.sh --redo my-video
```

**Fast draft pass without scoring:**

```bash
VMAF=off X264_PRESET=medium ./optimize.sh
```

## Requirements

- bash 3.2+ with standard tools (`awk`, `sed`, `stat`, `curl` for URLs)
- **Either** Docker (Desktop on macOS/Windows; on Linux files are written as your
  user) **or** ffmpeg + ffprobe on `PATH`, built with `libx264` and `libvmaf`
  (only libx264 is needed when `VMAF=off`)

With `FFMPEG_RUNNER=auto`, a suitable native ffmpeg is used when present, and
Docker otherwise. The first Docker run pulls the image.

## Limitations

- **Output format.** H.264/MP4 only, the format every browser plays. No AV1 or
  VP9 variants yet.
- **HDR.** HDR sources (PQ/HLG) are converted to SDR without tone mapping. A
  warning is logged, and colors may look washed out.
- **Scaling.** VMAF measures compression loss at the output resolution, not what
  is lost by scaling down.
- **Aspect ratio.** Anamorphic sources with non-square pixels are not corrected.

## Project layout

```
optimize.sh        entry point and command-line options
config.env         project-wide defaults
lib/util.sh        logging and portable helpers
lib/config.sh      settings layers, parsing and validation
lib/media.sh       ffmpeg runner, probing, output plan, encode, VMAF, posters
lib/jobs.sh        inbox ingest, job lifecycle, reports, watch, list
inbox/             drop videos here
work/  output/  failed/   created at runtime (git-ignored)
```
