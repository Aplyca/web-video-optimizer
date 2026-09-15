---
name: optimize-video
description: Optimize one or more videos for the web with this repository. Inspects each video, looks at sampled frames, chooses per-video settings (audio, frame rate, size, quality target, x264 tune, bitrate cap, poster time) from the content and intended use, writes the .env sidecar, runs optimize.sh and checks the result visually. Use when asked to optimize, compress, shrink or prepare a video, or to process what is in inbox/.
---

# Optimize video

Follow [AGENTS.md](../../../AGENTS.md) at the repository root. It is the source
of truth for the procedure, the decision guide and the rules. Read it fully
before starting.

Claude Code specifics:

- **Docker only, install nothing:** run every video operation through
  `./optimize.sh`, which uses Docker. Never install ffmpeg or other tools, and
  don't run ffmpeg or ffprobe directly. If Docker is missing or not running, stop
  and ask the user to start it.
- **Confidential footage:** if the user says the footage is confidential, don't
  Read the preview frames, since that sends them to the model. Ask the user to
  describe the content instead.
- **Viewing frames:** use the Read tool on the JPEGs that `./optimize.sh --frames`
  writes, and whose paths it prints: `videos/_previews/<name>/` before processing,
  `videos/<name>/preview/` after. Look at every sampled frame before choosing
  settings. When verifying, compare each `NN-source` / `NN-output` pair.
- **Asking about intent:** when the use isn't clear from the request, the filename
  or the frames, ask with AskUserQuestion before writing the sidecar. Offer
  options such as:
  - muted background loop
  - voice or music matters
  - screen recording or UI demo
  - small embed or preview

  The audio decision matters most.
- **Long runs:** encoding plus VMAF scoring takes roughly the video's duration per
  CRF tried. Give `./optimize.sh` a generous Bash timeout, or run it in the
  background, and don't poll in a tight loop.
- **Several videos:** inspect and sample each one, and write every sidecar first.
  Then run `./optimize.sh` once, which processes them all. Afterwards, offer
  `./optimize.sh --collect <folder>` to gather the finished files in one place.
- **Comparison page:** every delivery writes `videos/<name>/compare.html`. Give
  the user its path in the report and offer to open it (`open
  videos/<name>/compare.html` on macOS). It plays local files, so never publish
  it as an Artifact or upload it. Keep verifying with the frame pairs yourself.
- **Finish** with the report described in AGENTS.md: settings and reasons,
  size before → after, CRF, VMAF, the comparison page, and any concerns.
