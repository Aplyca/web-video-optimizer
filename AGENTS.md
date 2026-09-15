# Agent guide: choosing settings per video

This guide is for AI coding agents (Claude Code, Codex, Cursor, …) asked to
optimize videos with this repository. Read it before touching a video.

## Who decides what

`optimize.sh` already makes every decision that can be **measured**: output size
and frame rate from ffprobe data, and the CRF by searching until the VMAF quality
score reaches the target. It cannot know **intent** or judge **content**:

- Whether audio matters: a muted autoplay background, or a voice-over
- What the picture is: live action, motion graphics, UI with small text, film grain
- Where it plays: full-screen hero, small embed, mobile page with a size budget
- Which frame makes a good poster

Your job is to supply exactly that: look at the video, understand its use, write a
small settings file, then let the script do the encoding and quality gating.
VMAF still checks every encode, so a poor setting costs file size or time, not
visible quality, **unless** you lower `VMAF_TARGET` or cap `MAX_BITRATE`.

## Procedure

Run everything from the repository root. `<video>` is a path such as
`inbox/clip.mov`; `<name>` is the job name the script derives (`clip`).

All video work goes through `./optimize.sh`, which runs ffmpeg, ffprobe, VMAF
and downloads inside Docker. Docker is the only requirement. If `./optimize.sh`
reports that Docker is missing or not running, stop and ask the person to install
or start it. Don't work around it.

1. **Inspect** the source:

   ```bash
   ./optimize.sh --inspect inbox/clip.mov
   ```

   Note the resolution, orientation, frame rate, duration, bitrate, audio and any
   HDR warning. A very high bitrate (tens of Mb/s) means a master export with lots
   of room to shrink. A low one means it is already compressed.

2. **Look** at the picture:

   ```bash
   ./optimize.sh --frames inbox/clip.mov
   ```

   This writes 6 evenly spaced JPEGs to `videos/_previews/clip/` (pass a count
   after the file for more). Open and look at them. Identify the content type, text and
   UI elements, dark scenes and gradients, grain or noise, and fades or black
   frames.

3. **Establish the intended use.** Use what the person told you, the filename
   and the frames. **If it is still unclear whether the audio matters, or where
   the video will play, ask.** Don't guess: wrongly stripping a voice-over is the
   most damaging mistake available.

4. **Write the sidecar** `inbox/<video>.env` (for `inbox/clip.mov`, that's
   `inbox/clip.mov.env`). Include only the settings you are changing from the
   defaults, each with a comment line above it explaining why. See the decision
   guide and the example below.

5. **Confirm** the plan picked the sidecar up:

   ```bash
   ./optimize.sh --inspect inbox/clip.mov
   ```

6. **Run** the optimizer. Scoring takes roughly the video's duration per CRF tried,
   and typically 3–5 are tried, so allow a long timeout:

   ```bash
   ./optimize.sh
   ```

7. **Verify** the result. Everything for a video lives in `videos/<name>/`. Read
   `videos/<name>/report.txt`, then compare source and output frames at the same
   timestamps. They're written to `videos/<name>/preview/`:

   ```bash
   ./optimize.sh --frames clip
   ```

   Look at the `NN-source-*.jpg` and `NN-output-*.jpg` pairs for:
   - small text that got soft or smeared
   - banding (stair-stepped rings) in dark areas or gradients
   - blocking right after cuts or in fast motion
   - lost texture

   The run also writes `videos/<name>/compare.html`. It plays the original and
   any encode under a draggable divider, with the results, settings and reasons.
   It's for the person to check motion and detail themselves; it doesn't replace
   your frame check.

8. **Adjust if needed** by editing `videos/<name>/job.env`, the sidecar merged into
   the job, then run `./optimize.sh` again. The edited job is re-processed and
   matching encodes are reused. Usually the fix is a higher `VMAF_TARGET` or a
   lower `CRFS` range. Stop after two adjustment rounds and report what you saw.

9. **Report** to the person:
   - the settings you chose and why
   - source size → output size
   - the chosen CRF and VMAF score
   - any warnings or doubts
   - where the files are: `videos/<name>/output/`
   - the comparison page, `videos/<name>/compare.html`, to open in a browser
     (`open videos/<name>/compare.html` on macOS). It's rebuilt on every run;
     `./optimize.sh --compare <name>` rebuilds it without re-processing.

   For a batch, offer `./optimize.sh --collect <folder>`, which copies every
   finished MP4 and its posters into one folder. Once the person is happy with
   the results, offer `./optimize.sh --clean all`, which frees the space used by
   candidate encodes and previews and keeps the outputs.

## Decision guide

Defaults (from `config.env`) are tuned for general web video. Change a setting
only for a reason you can state.

### Intended use

| Use | Settings | Why |
|---|---|---|
| Muted autoplay background or hero loop | `AUDIO=strip`, `FPS=24` | Audio is never heard; 24 fps is indistinguishable for ambient motion and saves ~20% of frames |
| Voice-over, interview, tutorial | `AUDIO_CHANNELS=mono`, `AUDIO_BITRATE=96k` | Speech doesn't need stereo; halves the audio cost |
| Music or sound design matters | `AUDIO_BITRATE=160k` | AAC at 128k can smear cymbals and ambience |
| Small in-page embed (under ~800 px wide on desktop) | `MAX_DIMENSION=1280` | Pixels nobody sees still cost bytes |
| Thumbnail or hover preview | `MAX_DIMENSION=640`, `AUDIO=strip` | |
| Strict size or bandwidth budget | `MAX_BITRATE=<kbps>k` | See "Size budgets" below |
| Sports, gameplay, fast UI demos where smoothness is the point | `MAX_FPS=60` | The default caps at 30 fps |

### Content

| Content | Settings | Why |
|---|---|---|
| Live action, camera footage | `X264_TUNE=film` | Tunes the encoder's psychovisual and deblocking settings for natural images |
| Motion graphics, animation, flat colors, UI or screen recordings with motion | `X264_TUNE=animation` | Better for flat areas and hard edges |
| Slides, mostly static screens | `X264_TUNE=stillimage` | |
| Visible film grain or sensor noise worth keeping | `X264_TUNE=grain`, and start `CRFS` lower, e.g. `"16 18 20 22 24 26"` | Grain is expensive; without the tune it turns into smudges |
| Small or fine text that must stay legible | `VMAF_TARGET=94` | VMAF under-weights text sharpness |
| Dark scenes, smooth gradients, skies, vignettes | `VMAF_TARGET=93` | VMAF under-weights banding |
| Mixed or unsure | leave `X264_TUNE=none` | A wrong tune is worse than none |

VMAF targets: 90 (default) is visually transparent for most content. Stay within
88–96 unless the person explicitly accepts visible quality loss.

### Poster

Pick a representative, sharp frame from the `--frames` samples: not black, not
mid-fade, subject visible. Set `POSTER_TIME` to its timestamp in seconds (it is
in the filename, e.g. `03-source-12.50s.jpg`).

### Size budgets

`MAX_BITRATE` caps the video bitrate over a short buffer window (twice the
cap), so the average can land somewhat above it. Leave about 15% headroom:

```
video kbps ≈ (budget MB × 8000 ÷ duration s − audio kbps) × 0.85
```

For example, a 5 MB budget for 40 s with 96k audio gives
`(5 × 8000 ÷ 40 − 96) × 0.85 ≈ 768`, so `MAX_BITRATE=750k`. Check the delivered
size in the report, and lower the cap if it's still over budget.

The cap can stop any CRF from reaching the VMAF target. The script then delivers
the best candidate with a warning. Tell the person about that trade-off instead
of silently lowering `VMAF_TARGET`.

## Rules

- **Write only settings files:** `inbox/<video>.env` before processing, or
  `videos/<name>/job.env` after. Don't edit `config.env`, `lib/` or
  `optimize.sh` to optimize one video, unless asked to.
- **Install nothing.** Don't install ffmpeg, codecs, Python packages, Homebrew
  formulas or anything else, and don't run ffmpeg or ffprobe directly on the
  host. Use `./optimize.sh --inspect` and `--frames` for everything you need to
  see.
- **Use only per-video keys:** `CRF_FINAL`, `CRFS`, `CRF_FALLBACK`, `VMAF`,
  `VMAF_TARGET`, `MAX_DIMENSION`, `FPS`, `MAX_FPS`, `AUDIO`, `AUDIO_BITRATE`,
  `AUDIO_CHANNELS`, `X264_PRESET`, `X264_TUNE`, `MAX_BITRATE`, `POSTER_TIME`.
  Toolchain keys are ignored in per-video files.
- **Write the sidecar before the video can be picked up.** If `videos/.lock`
  exists, a watcher (`--watch`) may be running. In that case, write the sidecar
  into `inbox/` first and copy the video in afterwards. Or keep the video outside
  `inbox/`, write `<video>.env` next to it, and run `./optimize.sh <path>`, which
  copies both.
- **Prefer the quality gate over forcing a CRF.** Set `CRF_FINAL` only when the
  person asks for a specific CRF.
- **Keep footage local.** Videos and preview frames can be private or client
  material. Never upload them or send them to external services. Viewing
  preview frames sends those images to your model provider as part of the
  conversation. If the person says the footage is confidential, don't view
  frames: ask them to describe the content instead, and skip the visual check.
  `compare.html` plays the local files next to it: don't upload or publish it,
  or the videos, anywhere.
- **Don't hide trade-offs.** Anything that lowers quality (`VMAF_TARGET` below
  90, `MAX_BITRATE`, a smaller `MAX_DIMENSION` than the person implied) must
  be mentioned in your report.
- **Previews and candidates are scratch.** `videos/_previews/`, and
  `videos/<name>/preview/` and `candidates/`, are safe to remove with
  `./optimize.sh --clean`. Never delete `source.*` or `output/` unless the person
  asks. After a clean, the comparison page can only compare the original and the
  delivered file.

## Example sidecar

`inbox/ocean-loop.mov.env` for a muted, full-width landing-page background made
from aerial ocean footage at sunset:

```
# Autoplay background behind the landing-page headline: muted, never heard
AUDIO=strip
# Slow drifting camera; 24 fps looks the same and saves ~20% of frames
FPS=24
# Live-action drone footage
X264_TUNE=film
# Wide sunset sky gradient in most shots; VMAF under-weights banding
VMAF_TARGET=92
# Frame 03 (12.5 s): horizon level, waves in sharp focus
POSTER_TIME=12.5
```
