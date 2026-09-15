# CLAUDE.md

Web Video Optimizer: bash scripts that turn videos into web-ready MP4s, choosing
the CRF with VMAF. All video work runs in Docker.

## Optimizing videos

@AGENTS.md

AGENTS.md is the single guide for optimizing videos, shared with other agents.
Change the procedure or rules there, not here. The Claude Code specifics are in
`.claude/skills/optimize-video/SKILL.md`.

## Changing the tool

### Layout

- `optimize.sh`: entry point. `usage()`, option parsing in `main()`, then it
  sources `lib/`.
- `lib/util.sh`: logging (`info`, `ok`, `warn`, `die`) and portable helpers.
- `lib/config.sh`: settings layers, parsing and validation.
- `lib/media.sh`: the `ff` Docker wrapper, probing, output planning, encoding,
  VMAF and posters.
- `lib/jobs.sh`: the inbox → `videos/<name>/` workflow, reports, `--watch`,
  `--list`, `--frames`, `--collect` and `--clean`.
- `lib/compare.sh`: builds `compare.html` (heredoc HTML with embedded JSON) and
  `--compare`.

### Constraints

- **The host needs only bash and Docker.** Use built-in tools (`awk`, `sed`,
  `stat`, `date`) on the host. Never add Python, Node, jq or a host ffmpeg. Every
  ffmpeg, ffprobe and curl call goes through `ff` in `lib/media.sh`.
- **Portable bash.** Scripts must run on bash 3.2 (the macOS default) and on
  Linux:
  - no associative arrays, `mapfile` or `${var,,}`
  - use `lower`
  - expand arrays that may be empty as `${arr[@]+"${arr[@]}"}`
  - use GNU/BSD fallbacks like `file_bytes`
- **Config files are parsed, never executed.** Keep it that way.
- **Jobs fail alone.** `process_job` runs in a `set -e` subshell. An error must
  fail only that video. Optional steps, like the comparison page, warn instead
  of failing.
- **Keep caches valid.** Anything that changes an encode's bytes belongs in
  `candidate_key`. Add new keys only when the setting is set, so existing caches
  stay valid.
- **Runtime folders are gitignored.** Never commit anything from `inbox/`,
  `videos/` or `failed/`.

### Adding a setting

Update every place that lists settings:
- `CONFIG_KEYS` (and `GLOBAL_ONLY_KEYS` if it can't vary per video)
- `config_defaults` and `config.env`, which must stay in sync
- `config_validate`
- the `write_job_env` template
- the README settings table
- the per-video keys in AGENTS.md, plus its decision guide when agents should
  choose it

### Adding a command

Update:
- `usage()`
- the option `case` in `main()`
- the list of modes that take arguments
- the dispatch in `main()`: before `runner_init` if it doesn't need Docker
- the README commands table

### Checks

There is no test suite. Before committing, run the same checks as CI:

```bash
for f in optimize.sh lib/*.sh; do bash -n "$f"; done
```

```bash
docker run --rm -v "$PWD":/mnt -w /mnt koalaman/shellcheck:stable -x -s bash -S warning optimize.sh
```

Lint through `optimize.sh`, not individual `lib/` files, so shared variables
resolve.

To check a change end to end:
- `./optimize.sh --redo <name>` re-runs a delivered video from cached encodes in
  seconds.
- The README's "Demo with generated clips" creates fresh inputs.

### Docs

Behavior changes usually touch README.md, AGENTS.md and the skill together. Keep
their commands, folder layout and the Mermaid flowchart consistent with the
code.

Commit messages use an imperative subject line, then a short paragraph and
bullets for the details.
