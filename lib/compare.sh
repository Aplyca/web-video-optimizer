# lib/compare.sh — videos/<name>/compare.html: a self-contained page that plays
# any two versions of a video (the original, the delivered encode, every
# candidate still on disk) under a draggable divider, next to the run's results.
# bash writes it and the browser does the rest: it opens straight from disk
# (file://), needs no server, and only references the video's own files.

json_str() {  # json_str <text> — a JSON string literal, also safe inside <script>
  printf '"'
  printf '%s' "$1" | tr '\t' ' ' | tr -d '\000-\010\013-\037' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's#</#<\\/#g' \
    | awk 'NR > 1 { printf "%s", "\\n" } { printf "%s", $0 }'
  printf '"'
}

json_num() {  # json_num <value> — the number, or null when it isn't one
  case "$1" in
    -*) if is_number "${1#-}"; then printf '%s' "$1"; return 0; fi ;;
    *) if is_number "$1"; then printf '%s' "$1"; return 0; fi ;;
  esac
  printf 'null'
}

# compare_settings_rows <job.env> — one KEY<US>VALUE<US>REASON line per active
# setting. The reason is the comment block right above the line, which is where
# the agent explains each choice in the inbox sidecar.
compare_settings_rows() {
  [ -f "$1" ] || return 0
  awk '
    /^[[:space:]]*$/                       { r = ""; next }
    /^#[[:space:]]*[A-Z_][A-Z0-9_]*=/      { r = ""; next }
    /^# ---/ || /^# Settings from inbox\// { r = ""; next }
    /^#/ { c = $0; sub(/^#[[:space:]]*/, "", c); r = (r == "") ? c : r " " c; next }
    /^[[:space:]]*(export[[:space:]]+)?[A-Z_][A-Z0-9_]*[[:space:]]*=/ {
      line = $0; sub(/^[[:space:]]*(export[[:space:]]+)?/, "", line)
      k = line; sub(/[[:space:]]*=.*/, "", k)
      v = line; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      printf "%s\037%s\037%s\n", k, v, r
      r = ""; next
    }
    { r = "" }
  ' "$1"
}

# write_compare_page <name> — needs the job delivered (.done), and SRC_*, the
# output plan and FFMPEG_ID for its current settings (probe_source, plan_output).
write_compare_page() {
  local name="$1" d="videos/$1" src chosen versions settings warnings json tmp f crf key vmaf kind k v r quality poster_t out_fps
  src="$(job_source "$d")" || return 1
  [ -f "$d/.done" ] || return 1
  chosen="$(kv_get "$d/.done" crf)"

  # Versions: original, delivered, then every candidate on disk from best quality down.
  # The chosen candidate is the same bytes as the delivered file, so it is listed once.
  versions="{\"id\":\"original\",\"kind\":\"original\",\"file\":$(json_str "$(basename "$src")"),\"bytes\":$SRC_BYTES,\"crf\":null,\"vmaf\":null}"
  versions="$versions,{\"id\":\"delivered\",\"kind\":\"delivered\",\"file\":$(json_str "output/$name.mp4"),\"bytes\":$(json_num "$(kv_get "$d/.done" output_bytes)"),\"crf\":$(json_num "$chosen"),\"vmaf\":$(json_num "$(kv_get "$d/.done" vmaf)")}"
  for crf in $(for f in "$d"/candidates/crf*.mp4; do
                 [ -f "$f" ] || continue
                 f="${f##*/crf}"; f="${f%.mp4}"
                 if is_int "$f"; then echo "$f"; fi
               done | sort -n); do
    f="$d/candidates/crf$crf.mp4"
    key="$(cat "$f.settings" 2>/dev/null || true)"
    if [ "$key" = "$(candidate_key "$crf")" ]; then
      kind=candidate
      [ "$crf" != "$chosen" ] || continue
    else
      kind=stale  # encoded with earlier settings; kept on disk until --clean
    fi
    vmaf=""
    if [ -n "$key" ] && [ -f "$f.vmaf" ] && [ "$(sed -n 1p "$f.vmaf")" = "$key" ]; then
      vmaf="$(sed -n 2p "$f.vmaf")"
    fi
    versions="$versions,{\"id\":\"crf$crf\",\"kind\":\"$kind\",\"file\":$(json_str "candidates/crf$crf.mp4"),\"bytes\":$(file_bytes "$f"),\"crf\":$crf,\"vmaf\":$(json_num "$vmaf"),\"settings\":$(json_str "$key")}"
  done

  settings=""
  while IFS=$'\037' read -r k v r; do
    if in_words "$k" "$CONFIG_KEYS" && ! in_words "$k" "$GLOBAL_ONLY_KEYS"; then
      settings="${settings:+$settings,}{\"key\":\"$k\",\"value\":$(json_str "$v"),\"reason\":$(json_str "$r")}"
    fi
  done < <(compare_settings_rows "$d/job.env")

  warnings=""
  if [ -f "$d/output/report.txt" ]; then
    while IFS= read -r r; do
      warnings="${warnings:+$warnings,}$(json_str "$r")"
    done < <(sed -n 's/^[[:space:]]*WARNING:[[:space:]]*//p' "$d/output/report.txt")
  fi

  if [ "$CRF_FINAL" != auto ]; then quality=fixed; elif [ "$VMAF" = on ]; then quality=auto; else quality=fallback; fi
  poster_t="$(awk -v p="$POSTER_TIME" -v d="$SRC_DURATION" 'BEGIN{ if (d > 0 && p > d / 2) p = d / 2; printf "%.3f", p }')"
  if [ "$OUT_FPS" = keep ]; then out_fps="$SRC_FPS"; else out_fps="$OUT_FPS"; fi

  json="{\"name\":$(json_str "$name"),\"original_name\":$(json_str "$(kv_get "$d/.job" original_name)"),\"finished\":$(json_str "$(kv_get "$d/.done" finished)"),\"generated\":$(json_str "$(date '+%Y-%m-%d %H:%M:%S')"),\"engine\":$(json_str "$FFMPEG_ID"),"
  json="$json\"source\":{\"file\":$(json_str "$(basename "$src")"),\"bytes\":$SRC_BYTES,\"width\":$(json_num "$DISP_W"),\"height\":$(json_num "$DISP_H"),\"rotation\":$(json_num "$SRC_ROT"),\"fps\":$(json_num "$(fmt_num "$SRC_FPS")"),\"duration\":$(json_num "$(fmt_num "$SRC_DURATION")"),\"pixfmt\":$(json_str "$SRC_PIXFMT"),\"transfer\":$(json_str "$SRC_TRANSFER"),\"audio\":$(json_str "$SRC_AUDIO"),\"audio_channels\":$(json_num "$SRC_AUDIO_CH")},"
  json="$json\"output\":{\"width\":$(json_num "$OUT_W"),\"height\":$(json_num "$OUT_H"),\"fps\":$(json_num "$(fmt_num "$out_fps")"),\"audio\":$(json_str "$AUDIO_PLAN"),\"preset\":$(json_str "$X264_PRESET"),\"tune\":$(json_str "$X264_TUNE"),\"max_bitrate\":$(json_str "$MAX_BITRATE"),\"filters\":$(json_str "$FILTERS"),\"poster_time\":$(json_num "$(fmt_num "$poster_t")"),\"poster_jpg\":$(json_str "output/$name-poster.jpg"),\"poster_webp\":$(json_str "output/$name-poster.webp")},"
  json="$json\"quality\":{\"mode\":\"$quality\",\"vmaf\":$(json_str "$VMAF"),\"target\":$( [ "$VMAF" = on ] && json_num "$VMAF_TARGET" || printf null),\"crfs\":$(json_str "$(trim "$CRFS")"),\"fallback\":$(json_num "$CRF_FALLBACK")},"
  json="$json\"versions\":[$versions],\"settings\":[$settings],\"warnings\":[$warnings]}"

  tmp="$d/.compare.html.partial"
  {
    compare_html_head
    printf '<script type="application/json" id="data">%s</script>\n' "$json"
    compare_html_script
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$d/compare.html"
}

# compare_jobs <name|all>... — (re)build compare.html for delivered videos, e.g.
# after --clean or for videos delivered before the page existed
compare_jobs() {
  local n names=() d src built=0
  for n in "$@"; do
    if [ "$n" = all ]; then
      for n in $(job_names); do names+=("$n"); done
    else
      is_job "$n" || die "No video named '$n' (see ./optimize.sh --list)"
      names+=("$n")
    fi
  done
  for n in ${names[@]+"${names[@]}"}; do
    d="videos/$n"
    if [ ! -f "$d/.done" ]; then
      warn "'$n' has no delivered output yet; run ./optimize.sh first"
      continue
    fi
    config_resolve "$d/job.env"
    src="$(job_source "$d")" || { warn "'$n' has no source file"; continue; }
    probe_source "$src" || { warn "'$n': no readable video stream in $src"; continue; }
    plan_output
    if job_pending "$n"; then
      warn "'$n': job.env changed after the last delivery; the page shows the new settings until you run ./optimize.sh"
    fi
    write_compare_page "$n" || { warn "Could not write $d/compare.html"; continue; }
    ok "Comparison page: $d/compare.html"
    built=$((built + 1))
  done
  [ "$built" -gt 0 ] || warn "No comparison pages built (see ./optimize.sh --list)"
}

compare_html_head() {
  cat <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Video comparison</title>
<style>
  :root { --bg: #0d0f14; --panel: #151922; --field: #1e2430; --line: #262c38; --text: #e8ebf1; --muted: #98a2b3;
          --left: #f472b6; --right: #4cc9f0; --good: #5dd39e; --bad: #fbbf24; --radius: 10px; color-scheme: dark; }
  * { box-sizing: border-box; }
  [hidden] { display: none !important; }
  body { margin: 0; padding: 0 16px 48px; background: var(--bg); color: var(--text); font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
  main { max-width: 1280px; margin: 0 auto; }
  h1 { margin: 0; font-size: 20px; font-weight: 650; overflow-wrap: anywhere; }
  h2 { margin: 0 0 12px; font-size: 12px; font-weight: 600; letter-spacing: .07em; text-transform: uppercase; color: var(--muted); }
  .muted { color: var(--muted); }
  .good { color: var(--good); }
  .bad { color: var(--bad); }
  .num, table, .kpi .v { font-variant-numeric: tabular-nums; }

  header.top { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: flex-end; gap: 4px 24px; padding: 20px 0 16px; }
  .sub { color: var(--muted); font-size: 13px; overflow-wrap: anywhere; }

  .kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 10px; margin-bottom: 16px; }
  .kpi { background: var(--panel); border: 1px solid var(--line); border-radius: var(--radius); padding: 12px 14px; min-width: 0; }
  .kpi .k { font-size: 12px; color: var(--muted); }
  .kpi .v { font-size: 18px; font-weight: 600; margin-top: 2px; overflow-wrap: anywhere; }
  .kpi .s { font-size: 12px; color: var(--muted); margin-top: 2px; }

  .viewer { border: 1px solid var(--line); border-radius: var(--radius); overflow: hidden; margin-bottom: 16px; background: #000; }
  #stage { position: relative; width: 100%; margin: 0 auto; overflow: hidden; background: #000; cursor: ew-resize; user-select: none; touch-action: none; }
  #stage:fullscreen { width: 100vw; height: 100vh; max-width: none; aspect-ratio: auto; }
  .layer { position: absolute; inset: 0; overflow: hidden; }
  .layer video { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: contain; transform-origin: var(--ox, 50%) var(--oy, 50%); transform: scale(var(--zoom, 1)); }
  #layerR { clip-path: inset(0 0 0 var(--split, 50%)); }
  #divider { position: absolute; top: 0; bottom: 0; left: var(--split, 50%); width: 2px; margin-left: -1px; background: #fff; box-shadow: 0 0 8px rgba(0,0,0,.6); pointer-events: none; }
  #knob { position: absolute; top: 50%; left: 50%; width: 34px; height: 34px; margin: -17px 0 0 -17px; border-radius: 50%; background: #fff; color: #111; display: grid; place-items: center; font-weight: 700; box-shadow: 0 2px 10px rgba(0,0,0,.5); }
  .tag { position: absolute; top: 10px; max-width: calc(50% - 20px); padding: 5px 9px; border-radius: 6px; background: rgba(10,12,18,.8); font-size: 12px; pointer-events: none; }
  .tag b, .tag span { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .tag span { color: #c3cad6; }
  #tagL { left: 10px; border-left: 3px solid var(--left); }
  #tagR { right: 10px; text-align: right; border-right: 3px solid var(--right); }
  .overlay { position: absolute; top: 50%; transform: translateY(-50%); max-width: calc(50% - 20px); padding: 6px 10px; border-radius: 6px; background: rgba(10,12,18,.88); font-size: 13px; pointer-events: none; }
  #statusL { left: 10px; }
  #statusR { right: 10px; }

  .controls { display: flex; flex-direction: column; gap: 10px; padding: 12px; background: var(--panel); border-top: 1px solid var(--line); }
  .row { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 10px; }
  .pickers { justify-content: center; }
  .pick { display: flex; align-items: center; gap: 6px; min-width: 0; max-width: 100%; }
  .dot { flex: none; width: 10px; height: 10px; border-radius: 50%; }
  select, button { font: inherit; color: var(--text); background: var(--field); border: 1px solid var(--line); border-radius: 6px; padding: 5px 9px; cursor: pointer; max-width: 100%; }
  button:hover:not(:disabled), select:hover { border-color: #3d4556; }
  button:disabled { opacity: .4; cursor: not-allowed; }
  #scrub { flex: 1 1 160px; min-width: 120px; accent-color: var(--right); }
  #time { min-width: 150px; }
  .hint { margin: 0; font-size: 12px; color: var(--muted); }
  kbd { font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; padding: 1px 5px; border: 1px solid var(--line); border-bottom-width: 2px; border-radius: 4px; background: var(--field); color: var(--text); }

  .panel { background: var(--panel); border: 1px solid var(--line); border-radius: var(--radius); padding: 14px 16px; margin-bottom: 16px; min-width: 0; }
  .grid2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 380px), 1fr)); gap: 16px; margin-bottom: 16px; }
  .grid2 .panel { margin-bottom: 0; }
  .table-wrap { overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; }
  th, td { padding: 7px 8px; border-bottom: 1px solid var(--line); text-align: right; white-space: nowrap; }
  th:first-child, td:first-child { text-align: left; padding-left: 14px; }
  th { font-size: 12px; font-weight: 500; color: var(--muted); }
  tr.is-L td:first-child { box-shadow: inset 3px 0 0 var(--left); }
  tr.is-R td:first-child { box-shadow: inset 3px 0 0 var(--right); }
  tr.is-L.is-R td:first-child { box-shadow: inset 3px 0 0 var(--left), inset 6px 0 0 var(--right); }
  .badge { display: inline-block; margin-left: 6px; padding: 0 7px; border: 1px solid var(--line); border-radius: 999px; font-size: 11px; color: var(--muted); }
  .badge.good { color: var(--good); border-color: currentColor; }
  .badge.bad { color: var(--bad); border-color: currentColor; }
  .vbar { position: relative; display: inline-block; width: 110px; height: 8px; margin-left: 8px; border-radius: 4px; background: #232a36; vertical-align: middle; }
  .vbar i { position: absolute; left: 0; top: 0; bottom: 0; border-radius: 4px; background: var(--muted); }
  .vbar i.good { background: var(--good); }
  .vbar i.bad { background: var(--bad); }
  .vbar u { position: absolute; top: -3px; bottom: -3px; width: 2px; margin-left: -1px; background: var(--text); }
  td.cmp button { padding: 2px 9px; font-size: 12px; margin-left: 4px; }
  td.cmp button.on-L { border-color: var(--left); color: var(--left); }
  td.cmp button.on-R { border-color: var(--right); color: var(--right); }
  .note { margin: 10px 0 0; font-size: 12px; color: var(--muted); }

  dl.kv { display: grid; grid-template-columns: max-content 1fr; gap: 6px 16px; margin: 0; }
  dl.kv dt { color: var(--muted); }
  dl.kv dd { margin: 0; overflow-wrap: anywhere; }
  .setting { padding: 8px 0; border-bottom: 1px solid var(--line); }
  .setting:first-child { padding-top: 0; }
  .setting:last-child { border-bottom: 0; padding-bottom: 0; }
  code { font: 12.5px ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--field); padding: 2px 6px; border-radius: 4px; overflow-wrap: anywhere; }
  .setting p { margin: 4px 0 0; color: var(--muted); }
  ul.warn { margin: 0; padding-left: 18px; color: var(--bad); }
  #poster { display: block; max-width: 100%; max-height: 320px; border-radius: 6px; }
  @media (max-width: 600px) { .tag { font-size: 11px; } #time { min-width: 0; } dl.kv { grid-template-columns: 1fr; gap: 0 0; } dl.kv dd { margin-bottom: 8px; } }
</style>
</head>
<body>
<main>
  <header class="top">
    <div>
      <h1 id="h-name"></h1>
      <div class="sub" id="h-sub"></div>
    </div>
    <div class="sub" id="h-gen"></div>
  </header>

  <section class="kpis" id="kpis" aria-label="Results"></section>

  <section class="viewer" aria-label="Comparison">
    <div id="stage">
      <div class="layer" id="layerL"><video id="vL" muted playsinline loop preload="auto"></video></div>
      <div class="layer" id="layerR"><video id="vR" muted playsinline loop preload="auto"></video></div>
      <div id="divider"><div id="knob">⇔</div></div>
      <div class="tag" id="tagL"></div>
      <div class="tag" id="tagR"></div>
      <div class="overlay" id="statusL" hidden></div>
      <div class="overlay" id="statusR" hidden></div>
    </div>
    <div class="controls">
      <div class="row pickers">
        <label class="pick"><span class="dot" style="background: var(--left)"></span>Left <select id="selL"></select></label>
        <button id="swap" title="Swap sides (S)">⇄ Swap</button>
        <label class="pick"><span class="dot" style="background: var(--right)"></span>Right <select id="selR"></select></label>
      </div>
      <div class="row">
        <button id="play" title="Play or pause (Space)">❚❚ Pause</button>
        <button id="prev" title="Previous frame (←)">◀ Frame</button>
        <button id="next" title="Next frame (→)">Frame ▶</button>
        <input id="scrub" type="range" min="0" max="1000" step="1" value="0" aria-label="Seek">
        <span id="time" class="num muted"></span>
        <label class="pick">Speed <select id="speed"><option value="1">1×</option><option value="0.5">½×</option><option value="0.25">¼×</option></select></label>
        <label class="pick">Zoom <select id="zoom"><option value="1">1×</option><option value="2">2×</option><option value="3">3×</option><option value="4">4×</option></select></label>
        <button id="fs" title="Fullscreen (F)">Fullscreen</button>
        <span id="sync" class="num muted" title="How far the right side is from the left side"></span>
      </div>
      <p class="hint">Drag on the video to move the divider · <kbd>Space</kbd> play/pause · <kbd>←</kbd> <kbd>→</kbd> step one frame · <kbd>Shift</kbd>+<kbd>←</kbd> <kbd>→</kbd> move the divider · <kbd>S</kbd> swap · <kbd>Z</kbd> zoom, hold <kbd>Shift</kbd> over the video to aim it · <kbd>F</kbd> fullscreen</p>
    </div>
  </section>

  <section class="panel" aria-labelledby="versions-title">
    <h2 id="versions-title">Versions</h2>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Version</th><th>CRF</th><th>Size</th><th>vs original</th><th>Bitrate</th><th>VMAF</th><th>Compare</th></tr></thead>
        <tbody id="versions"></tbody>
      </table>
    </div>
    <p class="note" id="versions-note"></p>
  </section>

  <section class="grid2">
    <div class="panel"><h2>Settings for this video</h2><div id="settings"></div></div>
    <div class="panel"><h2>Encoding details</h2><dl class="kv" id="details"></dl></div>
  </section>

  <section class="panel" id="warnings-panel" hidden><h2>Warnings from the last run</h2><ul class="warn" id="warnings"></ul></section>

  <section class="panel" id="poster-panel">
    <h2>Poster</h2>
    <picture id="poster-pic"></picture>
    <p class="note" id="poster-note"></p>
  </section>
</main>
HTML
}

compare_html_script() {
  cat <<'HTML'
<script>
(() => {
  const D = JSON.parse(document.getElementById('data').textContent);
  const $ = id => document.getElementById(id);
  const el = (tag, props = {}, ...kids) => { const n = Object.assign(document.createElement(tag), props); n.append(...kids); return n; };
  const S = D.source, O = D.output, Q = D.quality, SIDES = ['L', 'R'];

  // Formatting (sizes in decimal units, like report.txt)
  const size = b => { if (b == null) return '–'; const u = ['B', 'KB', 'MB', 'GB']; let i = 0; while (b >= 1000 && i < 3) { b /= 1000; i++; } return i ? `${b.toFixed(2)} ${u[i]}` : `${b} B`; };
  const kbps = b => (b != null && S.duration > 0) ? Math.round(b * 8 / S.duration / 1000) : null;
  const int = n => n == null ? '–' : n.toLocaleString('en-US');
  const saved = b => (b != null && S.bytes) ? 100 - b / S.bytes * 100 : null;
  const signed = p => p == null ? '–' : `${p >= 0 ? '−' : '+'}${Math.abs(p).toFixed(1)}%`;
  const target = Q.target;
  const verdict = v => (v == null || target == null) ? '' : (v >= target ? 'good' : 'bad');
  const fps = O.fps || S.fps || 30;

  const versions = D.versions;
  const byId = Object.fromEntries(versions.map(v => [v.id, v]));
  const missing = new Set();
  const label = v => v.kind === 'original' ? 'Original'
    : v.kind === 'delivered' ? `Optimized · CRF ${v.crf}`
    : v.kind === 'stale' ? `CRF ${v.crf} · earlier settings` : `CRF ${v.crf}`;

  // Header and results
  document.title = `Compare · ${D.name}`;
  $('h-name').textContent = D.name;
  $('h-sub').textContent = `Original file: ${D.original_name || S.file}${D.finished ? ` · delivered ${D.finished}` : ''}`;
  $('h-gen').textContent = `Page generated ${D.generated}`;

  const del = byId.delivered, p = saved(del.bytes);
  const audioIn = S.audio ? `${S.audio}${S.audio_channels ? ` ${S.audio_channels}ch` : ''}` : 'none';
  const quality = Q.mode === 'auto' ? 'Smallest encode meeting the target'
    : Q.mode === 'fixed' ? 'Fixed CRF (CRF_FINAL)' : 'VMAF off: CRF_FALLBACK';
  const kpis = [
    ['File size', `${size(S.bytes)} → ${size(del.bytes)}`, p == null ? '' : `${Math.abs(p).toFixed(1)}% ${p >= 0 ? 'smaller' : 'larger'}`, p != null && p < 0 ? 'bad' : ''],
    ['Quality (VMAF)', del.vmaf != null ? del.vmaf.toFixed(2) : 'not measured', target != null ? `target ≥ ${target} · ${del.vmaf != null && del.vmaf >= target ? 'met' : 'not met'}` : 'VMAF was off', verdict(del.vmaf)],
    ['CRF', del.crf ?? '–', quality, ''],
    ['Bitrate', `${int(kbps(S.bytes))} → ${int(kbps(del.bytes))}`, 'kb/s, averaged over the video', ''],
    ['Picture', `${S.width}×${S.height} → ${O.width}×${O.height}`, `${S.fps} → ${O.fps} fps · ${S.duration} s`, ''],
    ['Audio', `${audioIn} → ${O.audio}`, O.audio === 'none' ? 'audio track removed' : 'AAC', ''],
  ];
  for (const [k, v, s, cls] of kpis) {
    $('kpis').append(el('div', { className: 'kpi' },
      el('div', { className: 'k', textContent: k }),
      el('div', { className: `v ${cls}`, textContent: v }),
      el('div', { className: 's', textContent: s })));
  }

  // Settings with the reasons written above them in job.env
  const chosen = new Map();
  for (const s of D.settings) chosen.set(s.key, s);
  if (!chosen.size) {
    $('settings').append(el('p', { className: 'muted', textContent: 'No per-video overrides: the defaults from config.env were used.' }));
  }
  for (const s of chosen.values()) {
    $('settings').append(el('div', { className: 'setting' },
      el('code', { textContent: `${s.key}=${s.value}` }),
      el('p', { textContent: s.reason || 'No reason noted in job.env.' })));
  }

  const transfer = S.transfer && S.transfer !== 'unknown' ? ` · ${S.transfer}` : '';
  const details = [
    ['Source file', `${S.file} · ${size(S.bytes)}`],
    ['Source format', `${S.pixfmt}${transfer}${S.rotation ? ` · rotated ${S.rotation}°` : ''}`],
    ['Encoder', `x264, preset ${O.preset}${O.tune !== 'none' ? `, tune ${O.tune}` : ''}${O.max_bitrate !== 'none' ? `, bitrate cap ${O.max_bitrate}` : ''}`],
    ['Filters', O.filters === 'null' ? 'none (size and frame rate kept)' : O.filters],
    ['Quality rule', Q.mode === 'auto' ? `Highest CRF in "${Q.crfs}" with VMAF ≥ ${target}` : Q.mode === 'fixed' ? `CRF ${del.crf}${target != null ? `, scored against VMAF ${target}` : ''}` : `CRF ${Q.fallback} (VMAF off)`],
    ['Delivered file', `output/${D.name}.mp4`],
    ['Poster frame', `${O.poster_time} s`],
    ['ffmpeg image', D.engine],
  ];
  for (const [k, v] of details) $('details').append(el('dt', { textContent: k }), el('dd', { textContent: v }));

  if (D.warnings.length) {
    $('warnings-panel').hidden = false;
    for (const w of D.warnings) $('warnings').append(el('li', { textContent: w }));
  }

  const pic = $('poster-pic');
  pic.append(el('source', { srcset: O.poster_webp, type: 'image/webp' }));
  const img = el('img', { id: 'poster', src: O.poster_jpg, alt: `Poster frame of ${D.name}` });
  img.onerror = () => { $('poster-panel').hidden = true; };
  pic.append(img);
  $('poster-note').textContent = `${O.poster_jpg} and .webp, taken from the delivered encode at ${O.poster_time} s. Use it as <video poster="…">.`;

  // Versions table
  const bar = v => Math.max(0, Math.min(100, (v - 50) * 2));  // bars span VMAF 50–100
  $('versions-note').textContent = `Sizes and bitrates are for the whole file. VMAF bars span 50–100${target != null ? `; the white tick is the target (${target})` : ''}. `
    + 'Candidates are the other encodes the CRF search tried, kept in candidates/ until ./optimize.sh --clean.';

  // Comparison player: the left video is the clock, the right one follows it
  const stage = $('stage'), vids = { L: $('vL'), R: $('vR') }, sels = { L: $('selL'), R: $('selR') };
  const current = { L: null, R: null }, tokens = { L: 0, R: 0 }, blobs = new Map();
  const viaHttp = /^https?:$/.test(location.protocol);
  const root = document.documentElement;
  let wantPlay = true, split = 50, dragging = false, scrubbing = false, rate = 1;

  stage.style.aspectRatio = `${O.width} / ${O.height}`;
  stage.style.maxWidth = `calc(72vh * ${O.width / O.height})`;

  function renderTable() {
    const body = $('versions');
    body.replaceChildren();
    for (const v of versions) {
      const tr = el('tr');
      for (const side of SIDES) if (current[side] === v.id) tr.classList.add(`is-${side}`);
      const name = el('td', {}, label(v));
      if (v.kind === 'delivered') name.append(el('span', { className: 'badge good', textContent: 'delivered' }));
      if (v.kind === 'stale') name.append(el('span', { className: 'badge', textContent: 'not the current settings', title: v.settings }));
      if (missing.has(v.id)) name.append(el('span', { className: 'badge bad', textContent: 'file missing', title: `${v.file} could not be loaded` }));

      const score = el('td');
      if (v.kind === 'original') score.append(el('span', { className: 'muted', textContent: 'reference' }));
      else if (v.vmaf == null) score.append(el('span', { className: 'muted', textContent: 'not measured' }));
      else {
        const track = el('span', { className: 'vbar', title: `VMAF ${v.vmaf}${target != null ? ` (target ${target})` : ''}` });
        const fill = el('i', { className: verdict(v.vmaf) });
        fill.style.width = `${bar(v.vmaf)}%`;
        track.append(fill);
        if (target != null) { const tick = el('u'); tick.style.left = `${bar(target)}%`; track.append(tick); }
        score.append(el('span', { className: verdict(v.vmaf), textContent: v.vmaf.toFixed(2) }), track);
      }

      const cmp = el('td', { className: 'cmp' });
      for (const side of SIDES) {
        const b = el('button', { textContent: side === 'L' ? 'Left' : 'Right', disabled: missing.has(v.id), className: current[side] === v.id ? `on-${side}` : '' });
        b.onclick = () => setSide(side, v.id);
        cmp.append(b);
      }
      tr.append(name, el('td', {}, String(v.crf ?? '–')), el('td', {}, size(v.bytes)),
        el('td', {}, v.kind === 'original' ? '–' : signed(saved(v.bytes))), el('td', {}, `${int(kbps(v.bytes))} kb/s`), score, cmp);
      body.append(tr);
    }
  }

  function optionText(v) {
    return `${label(v)} — ${size(v.bytes)}${v.vmaf != null ? ` · VMAF ${v.vmaf.toFixed(2)}` : ''}${missing.has(v.id) ? ' (file missing)' : ''}`;
  }
  for (const side of SIDES) {
    for (const v of versions) sels[side].add(new Option(optionText(v), v.id));
    sels[side].onchange = () => setSide(side, sels[side].value);
  }

  function renderSides() {
    for (const side of SIDES) {
      const v = byId[current[side]], tag = $(`tag${side}`);
      tag.replaceChildren();
      if (current[side]) sels[side].value = current[side];
      if (!v) continue;
      const bits = [size(v.bytes)];
      if (v.kind !== 'original') bits.push(signed(saved(v.bytes)));
      if (v.vmaf != null) bits.push(`VMAF ${v.vmaf.toFixed(2)}`);
      tag.append(el('b', { textContent: label(v) }), el('span', { textContent: bits.join(' · ') }));
    }
    renderTable();
  }

  function markMissing(v) {
    missing.add(v.id);
    for (const side of SIDES) {
      const opt = [...sels[side].options].find(o => o.value === v.id);
      if (opt) { opt.textContent = optionText(v); opt.disabled = true; }
    }
  }

  function status(side, text) { const s = $(`status${side}`); s.textContent = text || ''; s.hidden = !text; }

  // Over http(s), load whole files into blobs so seeking works on servers without
  // range requests; from disk (file://) the browser reads the files directly.
  async function fileUrl(v) {
    if (!viaHttp) return v.file;
    if (!blobs.has(v.file)) {
      const r = await fetch(v.file);
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      blobs.set(v.file, URL.createObjectURL(await r.blob()));
    }
    return blobs.get(v.file);
  }

  function loaded(video) {
    return new Promise((resolve, reject) => {
      const off = () => { video.removeEventListener('loadeddata', ok); video.removeEventListener('error', bad); };
      const ok = () => { off(); resolve(); };
      const bad = () => { off(); reject(video.error || new Error('load failed')); };
      video.addEventListener('loadeddata', ok);
      video.addEventListener('error', bad);
    });
  }

  const clock = () => (vids.L.readyState ? vids.L.currentTime : vids.R.currentTime) || 0;

  async function setSide(side, id) {
    const v = byId[id];
    if (!v) return;
    const video = vids[side], token = ++tokens[side], t = clock();
    current[side] = id;
    renderSides();
    status(side, 'Loading…');
    if (side === 'L') vids.R.pause();
    try {
      const url = await fileUrl(v);
      if (token !== tokens[side]) return;
      const ready = loaded(video);
      video.src = url;
      await ready;
      if (token !== tokens[side]) return;
      video.currentTime = t;
      if (side === 'L') {
        video.defaultPlaybackRate = video.playbackRate = rate;
        if (wantPlay) video.play().catch(() => {});
        else if (vids.R.readyState) vids.R.currentTime = t;
      } else if (!vids.L.paused) {
        video.play().catch(() => {});
      }
      status(side, '');
    } catch (err) {
      if (token !== tokens[side]) return;
      markMissing(v);
      const fallback = side === 'L' ? 'original' : 'delivered';
      if (id !== fallback && !missing.has(fallback)) { setSide(side, fallback); return; }
      renderSides();
      status(side, `Can't load ${v.file}`);
    }
  }

  function renderPlay() { $('play').textContent = vids.L.paused ? '▶ Play' : '❚❚ Pause'; }
  vids.L.addEventListener('play', () => { if (vids.R.readyState) vids.R.play().catch(() => {}); renderPlay(); });
  vids.L.addEventListener('pause', () => { vids.R.pause(); if (vids.R.readyState) vids.R.currentTime = vids.L.currentTime; renderPlay(); });

  function togglePlay() {
    if (vids.L.paused) { wantPlay = true; vids.L.play().catch(() => {}); }
    else { wantPlay = false; vids.L.pause(); }
  }
  function seek(t) {
    const d = vids.L.duration;
    if (!d) return;
    t = ((t % d) + d) % d;
    vids.L.currentTime = t;
    if (vids.R.readyState) vids.R.currentTime = t;
  }
  function step(dir) {  // lands mid-frame so every browser shows the same frame on both sides
    wantPlay = false;
    vids.L.pause();
    seek((Math.floor(vids.L.currentTime * fps + 1e-3) + dir + 0.5) / fps);
  }
  function setSplit(pct) { split = Math.min(100, Math.max(0, pct)); root.style.setProperty('--split', `${split}%`); }
  function swap() { const l = current.L, r = current.R; setSide('L', r); setSide('R', l); }
  function cycleZoom() { const z = $('zoom'); z.selectedIndex = (z.selectedIndex + 1) % z.options.length; z.onchange(); }
  function fullscreen() {
    if (document.fullscreenElement) document.exitFullscreen();
    else (stage.requestFullscreen || stage.webkitRequestFullscreen || (() => {})).call(stage);
  }

  function tick() {
    const L = vids.L, R = vids.R, d = L.duration || 0, t = L.currentTime;
    $('time').textContent = `${t.toFixed(2)} / ${d.toFixed(2)} s · frame ${Math.floor(t * fps + 1e-3) + 1}`;
    if (d && !scrubbing) $('scrub').value = Math.round(t / d * 1000);
    if (L.readyState >= 2 && R.readyState >= 2 && !L.seeking && !R.seeking) {
      const drift = R.currentTime - t;
      $('sync').textContent = `sync ${Math.round(drift * 1000)} ms`;
      if (Math.abs(drift) > 0.08) R.currentTime = t;  // also catches the loop wrapping on one side first
      else if (!L.paused) R.playbackRate = L.playbackRate * (1 - Math.max(-0.1, Math.min(0.1, drift * 2)));
      else if (Math.abs(drift) > 0.01) R.currentTime = t;
    }
    requestAnimationFrame(tick);
  }

  stage.addEventListener('pointerdown', e => { dragging = true; stage.setPointerCapture(e.pointerId); setSplit(e.offsetX / stage.clientWidth * 100); });
  stage.addEventListener('pointermove', e => {
    const box = stage.getBoundingClientRect();
    if (dragging) setSplit((e.clientX - box.left) / box.width * 100);
    if (e.shiftKey) {
      root.style.setProperty('--ox', `${(e.clientX - box.left) / box.width * 100}%`);
      root.style.setProperty('--oy', `${(e.clientY - box.top) / box.height * 100}%`);
    }
  });
  stage.addEventListener('pointerup', () => { dragging = false; });
  stage.addEventListener('pointercancel', () => { dragging = false; });

  $('play').onclick = togglePlay;
  $('prev').onclick = () => step(-1);
  $('next').onclick = () => step(1);
  $('swap').onclick = swap;
  $('fs').onclick = fullscreen;
  $('scrub').addEventListener('pointerdown', () => { scrubbing = true; });
  $('scrub').addEventListener('pointerup', () => { scrubbing = false; });
  $('scrub').oninput = e => seek(e.target.value / 1000 * (vids.L.duration || 0));
  $('speed').onchange = e => { rate = +e.target.value; vids.L.defaultPlaybackRate = vids.L.playbackRate = rate; };
  $('zoom').onchange = () => root.style.setProperty('--zoom', $('zoom').value);
  document.addEventListener('click', e => { const b = e.target.closest('button'); if (b) b.blur(); });  // keep Space for play/pause

  document.addEventListener('keydown', e => {
    if (e.metaKey || e.ctrlKey || e.altKey || e.target.matches('select, input')) return;
    const key = e.key.length === 1 ? e.key.toLowerCase() : e.key;
    if (key === ' ') togglePlay();
    else if (key === 'ArrowLeft' || key === 'ArrowRight') {
      const dir = key === 'ArrowRight' ? 1 : -1;
      if (e.shiftKey) setSplit(split + dir * 5); else step(dir);
    } else if (key === 's') swap();
    else if (key === 'z') cycleZoom();
    else if (key === 'f') fullscreen();
    else return;
    e.preventDefault();
  });

  setSide('L', 'original');
  setSide('R', 'delivered');
  requestAnimationFrame(tick);
})();
</script>
</body>
</html>
HTML
}
