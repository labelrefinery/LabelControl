"""Markup lifted verbatim from the marketing site, so the demo runs the same
viewer rather than a re-typed copy that drifts.

The viewer is icebird — about 43 KB of pure JavaScript, no WebAssembly. It
resolves the table's current snapshot from `version-hint.text` and pulls only
the Parquet byte ranges it needs, so the browser does the reading and there is
no server in the path.
"""


comptime VIEWER_HTML = """<div class="viewer" id="viewer">
    <div class="viewer-bar">
      <label for="tablepick">Table</label>
      <select id="tablepick">
        <option value="ground_truth_tracks">ground_truth_tracks</option>
        <option value="labels">labels</option>
      </select>
      <span class="viewer-status" id="status">loading…</span>
      <span class="viewer-pager">
        <button id="prev" type="button" disabled>‹ prev</button>
        <button id="next" type="button" disabled>next ›</button>
      </span>
    </div>
    <div class="scroll">
      <table id="grid">
        <thead><tr id="head"></tr></thead>
        <tbody id="body"></tbody>
      </table>
    </div>
    <p class="viewer-foot" id="foot"></p>
  </div>"""


comptime VIEWER_SCRIPT = """<script type="module">
  const BASE = "https://samples.magmalake.org/datasets/v0.2.0";
  const PAGE = 50;

  const el = (id) => document.getElementById(id);
  const state = { table: "ground_truth_tracks", start: 0, meta: null, total: 0 };

  const fmt = (v) => {
    if (v === null || v === undefined) return '<span class="null">null</span>';
    if (typeof v === "number" && !Number.isInteger(v)) return v.toFixed(3);
    return String(v);
  };

  let icebird;

  async function load() {
    el("status").textContent = "loading…";
    el("prev").disabled = el("next").disabled = true;
    try {
      icebird ??= await import("https://cdn.jsdelivr.net/npm/icebird@0.8/+esm");
      const tableUrl = `${BASE}/${state.table}`;
      if (!state.meta || state.meta.__table !== state.table) {
        const meta = await icebird.icebergMetadata({ tableUrl });
        meta.__table = state.table;
        state.meta = meta;
        const snap = meta.snapshots?.find(
          (s) => String(s["snapshot-id"]) === String(meta["current-snapshot-id"]),
        );
        state.total = Number(snap?.summary?.["total-records"] ?? 0);
        state.snapshotId = String(meta["current-snapshot-id"]);
      }
      const meta = state.meta;
      const fields = meta.schemas.find(
        (s) => s["schema-id"] === meta["current-schema-id"],
      ).fields;

      const end = Math.min(state.start + PAGE, state.total || state.start + PAGE);
      const rows = await icebird.icebergRead({
        tableUrl,
        metadata: meta,
        rowStart: state.start,
        rowEnd: end,
      });

      el("head").innerHTML = fields
        .map((f) => `<th>${f.name}</th>`)
        .join("");
      el("body").innerHTML = rows
        .map(
          (r) =>
            "<tr>" +
            fields.map((f) => `<td>${fmt(r[f.name])}</td>`).join("") +
            "</tr>",
        )
        .join("");

      const nulls = fields
        .map((f) => [f.name, rows.filter((r) => r[f.name] === null).length])
        .filter(([, n]) => n > 0)
        .map(([name, n]) => `${name} ${n}/${rows.length}`);

      el("status").textContent =
        `rows ${state.start + 1}–${state.start + rows.length} of ${state.total.toLocaleString()}`;
      el("foot").innerHTML =
        `snapshot <code>${state.snapshotId}</code>` +
        (nulls.length ? ` · null on this page: ${nulls.join(", ")}` : "");
      el("prev").disabled = state.start === 0;
      el("next").disabled = state.start + rows.length >= state.total;
    } catch (err) {
      el("status").textContent = "could not load";
      el("foot").textContent = String(err && err.message ? err.message : err);
    }
  }

  el("tablepick").addEventListener("change", (e) => {
    state.table = e.target.value;
    state.start = 0;
    state.meta = null;
    load();
  });
  el("prev").addEventListener("click", () => {
    state.start = Math.max(0, state.start - PAGE);
    load();
  });
  el("next").addEventListener("click", () => {
    state.start += PAGE;
    load();
  });

  load();
</script>"""
