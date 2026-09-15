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

## Demo

You can try it without your own footage. These commands use the same Docker
image to generate two 10-second clips in `inbox/`, both exported at very high
quality the way raw exports usually are:

- **`Product Demo.mov`:** a 1080p, 60 fps test pattern with a tone. It has flat
  areas and sharp edges, like screen recordings and motion graphics.
- **`background-loop.mp4`:** a portrait 1080×1920 fractal zoom with constant fine
  detail. This is hard to compress, like foliage, water or film grain.

```bash
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/inbox":/out --entrypoint ffmpeg \
  linuxserver/ffmpeg:9.0-cli-ls81 -hide_banner -loglevel error \
  -f lavfi -i testsrc2=size=1920x1080:rate=60 -f lavfi -i sine=frequency=440 \
  -t 10 -c:v libx264 -crf 12 -c:a aac -ac 2 -shortest "/out/Product Demo.mov"
```

```bash
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/inbox":/out --entrypoint ffmpeg \
  linuxserver/ffmpeg:9.0-cli-ls81 -hide_banner -loglevel error \
  -f lavfi -i mandelbrot=size=1080x1920:rate=30 -t 10 -c:v libx264 -crf 12 /out/background-loop.mp4
```

```bash
./optimize.sh
```

Real output from that run on an 8-CPU Docker VM (4 minutes in total, most of it
VMAF scoring). The `background-loop` job's per-CRF lines are shortened:

```
== Preflight ==
  ✓ ffmpeg: docker (docker:a8097f20436f)
  • Waiting 8s for files added to inbox/ in the last 10s to settle…
  ✓ Queued Product Demo.mov as job 'product-demo'
  ✓ Queued background-loop.mp4 as job 'background-loop'

== background-loop ==
  • Source: 69.59 MB | 1080x1920 @ 30 fps | 10 s | audio: none
  • Output: 1080x1920 @ source fps | audio: none | preset slow
  ✓ CRF 34 -> 2.23 MB (-96.8%), VMAF 61.46 (below 90) [encoded]
  ✓ CRF 32 -> 3.49 MB (-95.0%), VMAF 68.37 (below 90) [encoded]
    … CRF 30, 28 and 26 also score below 90 …
  ✓ CRF 24 -> 14.54 MB (-79.1%), VMAF 88.58 (below 90) [encoded]
  ✓ CRF 22 -> 18.50 MB (-73.4%), VMAF 91.68 [encoded]
  ✓ Delivered output/background-loop/background-loop.mp4 — 18.50 MB (-73.4%), CRF 22, VMAF 91.68

== product-demo ==
  • Source: 30.46 MB | 1920x1080 @ 60 fps | 10 s | audio: aac
  • Output: 1920x1080 @ 30 fps | audio: aac-128k | preset slow
  • Encoding CRF 34…
  • Measuring VMAF for CRF 34 (roughly real-time)…
  ✓ CRF 34 -> 1.78 MB (-94.2%), VMAF 84.41 (below 90) [encoded]
  • Encoding CRF 32…
  • Measuring VMAF for CRF 32 (roughly real-time)…
  ✓ CRF 32 -> 2.21 MB (-92.8%), VMAF 87.64 (below 90) [encoded]
  • Encoding CRF 30…
  • Measuring VMAF for CRF 30 (roughly real-time)…
  ✓ CRF 30 -> 2.76 MB (-90.9%), VMAF 90.34 [encoded]
  ✓ Delivered output/product-demo/product-demo.mp4 — 2.76 MB (-90.9%), CRF 30, VMAF 90.34

== Summary ==
  JOB                                 SOURCE      OUTPUT   SAVED  CRF   VMAF  STATUS
  background-loop                   69.59 MB    18.50 MB   73.4%   22  91.68  output/background-loop/
  product-demo                      30.46 MB     2.76 MB   90.9%   30  90.34  output/product-demo/
```

What the run shows:

- **Search depth follows the content.** The test pattern reached the quality
  target at CRF 30 on the third try. The detailed fractal needed seven tries,
  down to CRF 22. One fixed CRF for both would either waste bytes on the easy
  clip or visibly damage the hard one.
- **Defaults adapt to the source.** The 60 fps clip was capped at 30 fps and its
  audio re-encoded to AAC. The portrait clip kept its orientation and full size,
  since 1920 px is within the cap.
- **Re-runs are cheap.** Running `./optimize.sh` again reports nothing to do.
  Editing `work/product-demo/job.env` (for example `FPS=24` and `AUDIO=strip`)
  re-processes only that job.

Each job also writes a `report.txt`:

```
##### Run 2026-09-14 19:03:55 #####
Source:  Product Demo.mov | 30.46 MB | 1920x1080 @ 60 fps | 10 s | yuv420p | audio: aac
Output:  1920x1080 @ 30 fps | audio: aac-128k | x264 preset slow | docker:a8097f20436f
job.env: no overrides
Quality: auto, VMAF >= 90, trying CRF 34 32 30 28 26 24 22 20
  CRF 34: 1.78 MB (-94.2%), VMAF 84.41 (below 90) [encoded]
  CRF 32: 2.21 MB (-92.8%), VMAF 87.64 (below 90) [encoded]
  CRF 30: 2.76 MB (-90.9%), VMAF 90.34 [encoded]
Chosen:  CRF 30, VMAF 90.34 | 2.76 MB (-90.9% vs source, 2210 kb/s)
Output:  output/product-demo/product-demo.mp4, product-demo-poster.jpg, product-demo-poster.webp
```

Generated clips are an extreme case: they start at very high bitrates and
contain no camera noise. Savings on real footage depend on how the source was
exported. A master-quality export typically shrinks by 90% or more, while a file
already compressed for the web shrinks much less.

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
