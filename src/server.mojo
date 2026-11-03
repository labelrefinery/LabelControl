"""The label control site: what ran, in what order, and why.

A flare server on loopback, reading the orchestrator's ops.db. It does not
share a process with the orchestrator and does not call it directly — the
database is the whole interface — except for the two buttons, which POST to the
Restate ingress.

    pixi run serve            # http://127.0.0.1:20000

Loopback only by default, with a Host allow-list, following
millfolio/vault/app/server: binding 127.0.0.1 stops remote connections, but a
DNS-rebinding attack can still make a browser send a request here with an
attacker-controlled Host. The allow-list is what closes that.

In a container, `LABELCONTROL_ADDR` (`host:port`, say `0.0.0.0:20000`) binds
another address than loopback; the Host allow-list still applies, so a proxy
in front must send a name it lists.

To serve this through a Cloudflare Tunnel, add the public hostname to
`LABELCONTROL_ALLOWED_HOSTS` (comma-separated) -- the tunnel forwards the
original Host, so without it every request is refused. **Put an access policy
in front of it.** Nothing here authenticates: the buttons start jobs and
resolve reviews, so anyone who can reach it can spend your CPU and edit your
labels.
"""

from flare.http import (
    Handler,
    Method,
    Request,
    Response,
    Router,
    Status,
    ok,
    not_found,
)
from flare.http import HttpClient, HttpServer
from flare.net import SocketAddr
from std.os import getenv, makedirs
from std.os.path import exists
from std.random import random_ui64, seed as seed_rng

from embedded import VIEWER_HTML, VIEWER_SCRIPT
from paths import short_path as _short
from store import DecisionRow, Invocation, ReviewTask, StepRow, Store


comptime OPS_DEFAULT = "/private/tmp/labelrefinery/ops.db"
comptime STYLE = """
:root{color-scheme:light;--surface:#fcfcfb;--surface-2:#f4f3f0;--border:#e0dfda;
--ink:#16150f;--ink-2:#52514e;--ink-3:#8a8984;--accent:#2a78d6;--accent-2:#eb6834;
--accent-3:#1baf7a;--mono:ui-monospace,SFMono-Regular,Menlo,monospace;
--sans:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,system-ui,sans-serif}
@media (prefers-color-scheme:dark){:root{--surface:#16161a;--surface-2:#1e1e23;
--border:#2e2e35;--ink:#f4f4f2;--ink-2:#c3c2b7;--ink-3:#8a8984;--accent:#3987e5;
--accent-2:#d95926;--accent-3:#199e70}}
*{box-sizing:border-box}body{background:var(--surface);color:var(--ink);
font:16px/1.65 var(--sans);margin:0}
.wrap{max-width:70rem;margin:0 auto;padding:0 1.5rem}
header{border-bottom:1px solid var(--border);padding-block:1rem;margin-bottom:2rem}
header a{color:var(--ink);font-weight:650;text-decoration:none}
h1{font-size:1.6rem;letter-spacing:-.02em;margin:0 0 .5rem}
h2{font-size:1.15rem;margin:2rem 0 .6rem}
p,li{color:var(--ink-2)}
a{color:var(--accent)}
code{font-family:var(--mono);background:var(--surface-2);border-radius:4px;
padding:.12em .36em;font-size:.86em}
table{border-collapse:collapse;width:100%;font-size:.9rem;margin:1rem 0}
th,td{text-align:left;border-bottom:1px solid var(--border);padding:.5rem .7rem;
vertical-align:top}
th{color:var(--ink);font-weight:600;white-space:nowrap}
td{color:var(--ink-2)}
td.mono{font-family:var(--mono);font-variant-numeric:tabular-nums;font-size:.85rem}
.pill{display:inline-block;padding:.1rem .5rem;border-radius:999px;font-size:.78rem;
font-weight:600;border:1px solid var(--border)}
.ok{color:var(--accent-3)}.failed{color:var(--accent-2)}.running{color:var(--accent)}
.waiting{color:var(--accent-2);border-color:var(--accent-2)}
.exec-mojo{color:var(--accent)}.exec-subprocess{color:var(--ink-3)}
.exec-inproc{color:var(--accent-3)}
.button{display:inline-block;background:var(--accent);color:#fff;border:0;
padding:.55rem 1rem;border-radius:8px;font:inherit;font-size:.92rem;
font-weight:550;cursor:pointer;text-decoration:none}
.button.ghost{background:transparent;color:var(--accent);
border:1px solid var(--border)}
.actions{display:flex;gap:.6rem;margin:1.2rem 0}
.empty{color:var(--ink-3);font-style:italic}
.viewer{border:1px solid var(--border);border-radius:10px;background:var(--surface-2);
margin:1.5rem 0;overflow:hidden}
.viewer-bar{display:flex;align-items:center;gap:.75rem;flex-wrap:wrap;
padding:.7rem .9rem;border-bottom:1px solid var(--border)}
.viewer-bar label{color:var(--ink-3);font-size:.86rem}
.viewer-bar select{font:inherit;font-family:var(--mono);font-size:.86rem;
padding:.25rem .4rem;border:1px solid var(--border);border-radius:6px;
background:var(--surface);color:var(--ink)}
.viewer-status{color:var(--ink-2);font-size:.86rem;font-variant-numeric:tabular-nums}
.viewer-pager{margin-left:auto;display:flex;gap:.4rem}
.viewer-pager button{font:inherit;font-size:.86rem;padding:.25rem .7rem;
border:1px solid var(--border);border-radius:6px;background:var(--surface);
color:var(--ink);cursor:pointer}
.viewer-pager button:disabled{opacity:.45;cursor:default}
.viewer .scroll{margin:0;max-height:26rem;overflow:auto}
.viewer table{font-size:.82rem;font-family:var(--mono)}
.viewer thead th{position:sticky;top:0;background:var(--surface-2);
font-family:var(--sans);font-size:.8rem;white-space:nowrap}
.viewer td{font-variant-numeric:tabular-nums;white-space:nowrap}
.viewer .null{color:var(--ink-3);font-style:italic}
.viewer-foot{margin:0;padding:.6rem .9rem;border-top:1px solid var(--border);
color:var(--ink-3);font-size:.82rem}
.scroll{overflow-x:auto}
"""


def esc(s: String) -> String:
    var out = String("")
    for i in range(s.byte_length()):
        var c = s[byte=i]
        if c == "&":
            out += "&amp;"
        elif c == "<":
            out += "&lt;"
        elif c == ">":
            out += "&gt;"
        elif c == '"':
            out += "&quot;"
        else:
            out += String(c)
    return out^


def page(title: String, body: String, tail: String = "") -> String:
    return String(
        "<!doctype html><html lang=en><head><meta charset=utf-8>",
        "<meta name=viewport content='width=device-width,initial-scale=1'>",
        "<title>",
        esc(title),
        " — label control</title><style>",
        STYLE,
        "</style></head><body><header><div class=wrap>",
        "<a href='/'>label control</a> · <a href='/data'>the scene</a>"
        " · <a href='/datasets'>datasets</a> · <a href='/gold'>gold</a>"
        " · <a href='/review'>review queue</a>"
        "</div></header>",
        "<div class=wrap>",
        body,
        "</div>",
        tail,
        "</body></html>",
    )


def html(body: String) raises -> Response:
    var r = ok(body)
    r.headers.set("content-type", "text/html; charset=utf-8")
    return r^


def redirect(location: String) raises -> Response:
    # 303 so the browser turns the POST into a GET and a refresh does not
    # re-run the stage.
    var r = Response(303)
    r.headers.set("location", location)
    return r^


def port() -> UInt16:
    """Listen port. 20000 by default; `LABELCONTROL_PORT` overrides."""
    var raw = getenv("LABELCONTROL_PORT", "")
    if raw.byte_length() == 0:
        return 20000
    try:
        return UInt16(Int(Float64(raw)))
    except:
        return 20000


def listen_addr() raises -> SocketAddr:
    """Loopback on `port()`, unless `LABELCONTROL_ADDR` (`host:port`) says
    otherwise, as it must in a container."""
    var v = getenv("LABELCONTROL_ADDR", "")
    if v != "":
        return SocketAddr.parse(v)
    return SocketAddr.localhost(port())


def ops_path() -> String:
    var v = getenv("LABELCONTROL_OPS", "")
    return v if v != "" else String(OPS_DEFAULT)


def work_root() -> String:
    var v = getenv("LABELCONTROL_WORK", "")
    return v if v != "" else String("/private/tmp/labelrefinery/runs")


def sitegen_dir() -> String:
    var v = getenv("LABELCONTROL_SITEGEN", "")
    return v if v != "" else String("/Volumes/ExtNVMe/dev/labelrefinery/sitegen")


def ingress() -> String:
    var v = getenv("LABELCONTROL_RESTATE", "")
    return v if v != "" else String("http://127.0.0.1:8080")


def pct(s: String) -> String:
    """Percent-encode the characters that delimit the orchestrator's payload.

    The payload is `key=value&key=value`. A value carrying `&` or `=` would
    inject parameters -- `ops=` pointing at another database, say. Paths are
    generated here today so nothing is attacker-controlled, but that is a
    property of today's code rather than of this function.
    """
    var out = String("")
    for i in range(s.byte_length()):
        var c = String(s[byte=i])
        if c == "&":
            out += "%26"
        elif c == "=":
            out += "%3D"
        elif c == "%":
            out += "%25"
        else:
            out += c
    return out^


def loop_payload(inv: Invocation, sitegen: String) -> String:
    """The `key=value&...` body the orchestrator's `step` handler expects.

    `ops=` is not optional. Without it the orchestrator defaults to
    `<work>/ops.db` and writes into a different database than the one this
    invocation was created in -- every foreign key then fails, on every retry.
    """
    return String(
        '"ops=',
        ops_path(),
        "&scene=",
        pct(inv.scene_path),
        "&work=",
        pct(inv.work_dir),
        "&sitegen=",
        pct(sitegen),
        "&invocation=",
        pct(inv.id),
        "&seed=",
        inv.seed,
        '"',
    )


def to_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def allowed_hosts() -> List[String]:
    """Loopback names, plus whatever `LABELCONTROL_ALLOWED_HOSTS` adds."""
    var out = List[String]()
    out.append(String("127.0.0.1"))
    out.append(String("localhost"))
    out.append(String("[::1]"))
    var extra = getenv("LABELCONTROL_ALLOWED_HOSTS", "")
    for part in extra.split(","):
        var one = String(String(part).strip())
        if one.byte_length() > 0:
            out.append(one^)
    return out^


def host_allowed(req: Request) raises -> Bool:
    """True when the request's Host is one we answer to.

    The port is stripped before comparing, so `127.0.0.1:20000` matches
    `127.0.0.1`. A request with no Host at all is refused rather than allowed:
    every real client sends one.
    """
    var raw = String(req.headers.get("host"))
    if raw.byte_length() == 0:
        return False
    var name = raw
    # Strip the port, but not from a bracketed IPv6 literal's colons.
    if not raw.startswith("["):
        var parts = raw.split(":")
        name = String(parts[0])
    var allowed = allowed_hosts()
    for h in allowed:
        if name == h:
            return True
    return False


def short_path(path: String) -> String:
    return _short(path, work_root())


def read_only() -> Bool:
    """Writes disabled. Set `LABELCONTROL_READONLY=1` for a public deployment.

    Nothing here authenticates, and the write endpoints are not cheap: one
    `New random scene` costs a scene generation, a 600-frame geometry pass and
    a training run, and a review submission edits labels. Public and writable
    means anyone with the URL spends your machine and edits your data.
    """
    var v = getenv("LABELCONTROL_READONLY", "")
    return v == "1" or v == "true" or v == "yes"


def origin_ok(req: Request) raises -> Bool:
    """A state-changing request must come from a page we serve, or no page.

    The Host check defeats DNS rebinding; this defeats cross-site posting. They
    are different attacks: without this, any website a visitor opens can POST
    here in their browser and drive the loop. Absent Origin (curl, a form from
    our own page in some browsers) is allowed; a *foreign* Origin is not.
    """
    var origin = String(req.headers.get("origin"))
    if origin.byte_length() == 0:
        return True
    var allowed = allowed_hosts()
    for h in allowed:
        if origin.endswith("://" + h) or origin.startswith("http://" + h + ":") \
            or origin.startswith("https://" + h + ":"):
            return True
    return False


def refuse(reason: String) raises -> Response:
    var r = Response(403, "Forbidden", to_bytes(reason + "\n"))
    r.headers.set("content-type", "text/plain; charset=utf-8")
    return r^


def status_class(s: String) -> String:
    if s == "ok" or s == "done":
        return String("ok")
    if s == "failed":
        return String("failed")
    if s == "waiting":
        # A run blocked on a person is not in trouble and not making progress.
        # Giving it its own colour is the difference between "go look at the
        # review queue" and "something broke".
        return String("waiting")
    return String("running")


def timeline(req: Request) raises -> Response:
    var store = Store(ops_path())
    var invs = store.invocations(50)

    var waiting = len(store.open_reviews())
    var body = String("<h1>Runs</h1>")
    if waiting > 0:
        body += String(
            "<p><a href='/review'><strong>",
            waiting,
            " run",
            "" if waiting == 1 else "s",
            " waiting on you</strong></a> — the loop is stopped until you"
            " answer.</p>",
        )
    body += (
        "<form method=post action='/scenes/new' class=actions>"
        "<button class=button type=submit>New random scene</button></form>"
    )

    if len(invs) == 0:
        body += "<p class=empty>No runs yet. Start one above.</p>"
        return html(page("Runs", body))

    body += (
        "<table><thead><tr><th>started</th><th>scene</th><th>seed</th>"
        "<th>status</th><th>steps</th><th></th></tr></thead><tbody>"
    )
    for inv in invs:
        body += String(
            "<tr><td class=mono>",
            esc(inv.created_at),
            "</td><td class=mono>",
            esc(short_path(inv.scene_path)),
            "</td><td class=mono>",
            inv.seed,
            "</td><td><span class='pill ",
            status_class(inv.status),
            "'>",
            esc(inv.status),
            "</span></td><td class=mono>",
            inv.steps,
            "</td><td><a href='/invocations/",
            esc(inv.id),
            "'>timeline →</a></td></tr>",
        )
    body += "</tbody></table>"
    return html(page("Runs", body))


def detail(req: Request) raises -> Response:
    var id = String(req.param("id"))
    var store = Store(ops_path())
    var found = store.invocation(id)
    if not found:
        return not_found("no such run")
    ref inv = found.value()

    var steps = store.steps(id)
    var decisions = store.decisions(id)

    var body = String("<h1>Run ", esc(short_path(inv.scene_path)), "</h1>")
    body += String(
        "<p><code>",
        esc(inv.id),
        "</code> · seed <code>",
        inv.seed,
        "</code> · work <code>",
        esc(short_path(inv.work_dir)),
        "</code> · <span class='pill ",
        status_class(inv.status),
        "'>",
        esc(inv.status),
        "</span></p>",
    )
    body += String(
        "<form method=post action='/invocations/",
        esc(inv.id),
        "/step' class=actions>",
        "<button class=button type=submit>Run next stage</button>",
        "<a class='button ghost' href='/'>all runs</a></form>",
    )

    body += "<h2>What ran, in order</h2>"
    if len(steps) == 0:
        body += "<p class=empty>Nothing yet.</p>"
    else:
        body += (
            "<table><thead><tr><th>#</th><th>stage</th><th>executor</th>"
            "<th>status</th><th>metrics</th><th>finished</th></tr></thead><tbody>"
        )
        for s in steps:
            body += String(
                "<tr><td class=mono>",
                s.seq,
                "</td><td><code>",
                esc(s.name),
                "</code></td><td><span class='exec-",
                esc(s.executor),
                "'>",
                esc(s.executor),
                "</span></td><td><span class='pill ",
                status_class(s.status),
                "'>",
                esc(s.status),
                "</span></td><td class=mono>",
                esc(s.metrics if s.error == "" else s.error),
                "</td><td class=mono>",
                esc(s.finished_at),
                "</td></tr>",
            )
        body += "</tbody></table>"

    body += "<h2>What the router was choosing between</h2>"
    if len(decisions) == 0:
        body += "<p class=empty>No decisions recorded.</p>"
    else:
        body += (
            "<table><thead><tr><th>#</th><th>chose</th><th>candidates</th>"
            "<th>model</th><th>why</th></tr></thead><tbody>"
        )
        for d in decisions:
            body += String(
                "<tr><td class=mono>",
                d.seq,
                "</td><td><code>",
                esc(d.chosen),
                "</code></td><td class=mono>",
                esc(d.candidates),
                "</td><td class=mono>",
                esc(d.model),
                "</td><td>",
                esc(d.reason),
                "</td></tr>",
            )
        body += "</tbody></table>"

    return html(page(String("Run ") + inv.scene_path, body))


def _hexval(c: String) -> Int:
    if c >= "0" and c <= "9":
        return Int(ord(c)) - 48
    if c >= "a" and c <= "f":
        return Int(ord(c)) - 87
    if c >= "A" and c <= "F":
        return Int(ord(c)) - 55
    return -1


def url_decode(s: String) -> String:
    """`%XX` and `+` decoding for an application/x-www-form-urlencoded value."""
    var out = String("")
    var i = 0
    var n = s.byte_length()
    while i < n:
        var c = String(s[byte=i])
        if c == "+":
            out += " "
            i += 1
        elif c == "%" and i + 2 < n:
            var hi = _hexval(String(s[byte=i + 1]))
            var lo = _hexval(String(s[byte=i + 2]))
            if hi < 0 or lo < 0:
                out += c
                i += 1
            else:
                out += String(chr(hi * 16 + lo))
                i += 3
        else:
            out += c
            i += 1
    return out^


def parse_form(body: String) -> Dict[String, String]:
    var out = Dict[String, String]()
    for pair in body.split("&"):
        var text = String(pair)
        if text.byte_length() == 0:
            continue
        var parts = text.split("=")
        if len(parts) < 2:
            continue
        var key = url_decode(String(parts[0]))
        var value = String("")
        for i in range(1, len(parts)):
            if i > 1:
                value += "="
            value += String(parts[i])
        if key.byte_length() > 0:
            out[key] = url_decode(value)
    return out^


def form_get(form: Dict[String, String], key: String) -> String:
    try:
        return form[key]
    except:
        return String("")


def read_tracks(labels_path: String) raises -> List[List[String]]:
    """Distinct `[track_id, cls, rows]` from a tracker CSV, in first-seen order.

    A reviewer judges objects, not rows -- a track is one thing that was there
    for a while, and its class is a property of the thing.
    """
    var handle = open(labels_path, "r")
    var text = handle.read()
    handle.close()

    var ids = List[String]()
    var classes = List[String]()
    var counts = List[Int]()
    var first = True
    for raw in text.split("\n"):
        var line = String(String(raw).strip())
        if line.byte_length() == 0:
            continue
        if first:
            first = False
            continue
        var cells = line.split(",")
        if len(cells) < 2:
            continue
        var tid = String(cells[0])
        var found = -1
        for k in range(len(ids)):
            if ids[k] == tid:
                found = k
        if found < 0:
            ids.append(tid)
            classes.append(String(cells[1]))
            counts.append(1)
        else:
            counts[found] += 1

    var out = List[List[String]]()
    for k in range(len(ids)):
        var one = List[String]()
        one.append(ids[k])
        one.append(classes[k])
        one.append(String(counts[k]))
        out.append(one^)
    return out^


def review_queue(req: Request) raises -> Response:
    var store = Store(ops_path())
    var tasks = store.open_reviews()
    var body = String("<h1>Review queue</h1>")
    if len(tasks) == 0:
        body += "<p class=empty>Nothing waiting. The loop is not blocked on you.</p>"
        return html(page("Review queue", body))
    body += (
        "<table><thead><tr><th>opened</th><th>labels</th><th></th>"
        "</tr></thead><tbody>"
    )
    for t in tasks:
        body += String(
            "<tr><td class=mono>",
            esc(t.created_at),
            "</td><td class=mono>",
            esc(short_path(t.labels_path)),
            "</td><td><a href='/review/",
            esc(t.id),
            "'>review →</a></td></tr>",
        )
    body += "</tbody></table>"
    return html(page("Review queue", body))


def review_one(req: Request) raises -> Response:
    var id = String(req.param("id"))
    var store = Store(ops_path())
    var found = store.review(id)
    if not found:
        return not_found("no such review")
    ref task = found.value()

    var tracks = read_tracks(task.labels_path)
    var body = String("<h1>Review labels</h1>")
    body += String(
        "<p><code>",
        esc(short_path(task.labels_path)),
        "</code> · ",
        len(tracks),
        " tracks · the loop is suspended until you submit.</p>",
    )
    body += String("<form method=post action='/review/", esc(task.id), "'>")
    body += (
        "<table><thead><tr><th>track</th><th>rows</th><th>current</th>"
        "<th>class</th></tr></thead><tbody>"
    )
    for t in tracks:
        body += String(
            "<tr><td class=mono>",
            esc(t[0]),
            "</td><td class=mono>",
            esc(t[2]),
            "</td><td class=mono>",
            esc(t[1]),
            "</td><td><input name='cls_",
            esc(t[0]),
            "' value='",
            esc(t[1]),
            "' style='font:inherit;padding:.2rem .4rem;border:1px solid var(--border);border-radius:5px;background:var(--surface);color:var(--ink)'></td></tr>",
        )
    body += "</tbody></table>"
    body += (
        "<div class=actions><button class=button type=submit>"
        "Submit and resume the loop</button></div></form>"
    )
    return html(page("Review", body))


def submit_review(req: Request) raises -> Response:
    """Record what changed, then release the loop.

    Only fields the reviewer actually altered become edits: submitting an
    unchanged form should be a no-op, not a rewrite of every row.
    """
    if read_only():
        return refuse("read-only: this deployment cannot submit a review")
    if not origin_ok(req):
        return refuse("cross-site request refused")
    var id = String(req.param("id"))
    var store = Store(ops_path())
    var found = store.review(id)
    if not found:
        return not_found("no such review")
    ref task = found.value()

    var tracks = read_tracks(task.labels_path)
    var form = parse_form(req.text())
    var changes = 0
    for t in tracks:
        var field = String("cls_") + t[0]
        var submitted = form_get(form, field)
        if submitted.byte_length() == 0 or submitted == t[1]:
            continue
        store.add_edit(task.id, t[0], String("cls"), t[1], submitted)
        changes += 1

    var client = HttpClient()
    _ = client.post(
        ingress() + "/restate/awakeables/" + task.awakeable_id + "/resolve",
        String('"reviewed:') + String(changes) + '"',
    )
    return redirect("/review")


comptime SCENE_MCAP = "https://samples.magmalake.org/sitegen/v0.3.0/site_seed1_60s.mcap"
comptime LABELS_MCAP = "https://samples.magmalake.org/sitegen/v0.3.0/labels_rounds.mcap"


def foxglove_url(with_labels: Bool) -> String:
    """A Foxglove web link that streams the published MCAPs over range requests.

    Foxglove fetches these itself, from the visitor's browser -- so the data has
    to stay publicly hosted wherever the link happens to live.
    """
    var base = String(
        "https://app.foxglove.dev/~/view?ds=remote-file&ds.url="
    )
    var scene = String(
        "https%3A%2F%2Fsamples.magmalake.org%2Fsitegen%2Fv0.3.0%2F"
        "site_seed1_60s.mcap"
    )
    var labels = String(
        "&ds.url=https%3A%2F%2Fsamples.magmalake.org%2Fsitegen%2Fv0.3.0%2F"
        "labels_rounds.mcap"
    )
    return base + scene + (labels if with_labels else String(""))


def data_page(req: Request) raises -> Response:
    var body = String("<h1>Look at the scene</h1>")
    body += (
        "<p>The recording and every round of labels open in Foxglove with"
        " nothing to install. The 100 MB scene is read over HTTP range"
        " requests, so playback starts without pulling the whole file.</p>"
    )
    body += String(
        "<div class=actions><a class=button href='",
        foxglove_url(True),
        "'>Scene and every round of labels →</a>",
        "<a class='button ghost' href='",
        foxglove_url(False),
        "'>Scene only →</a></div>",
    )
    body += (
        "<h2>What to turn on</h2><p>Add a <strong>3D</strong> panel and set"
        " <em>display frame</em> to <code>map</code>. Then"
        " <code>/lidar/points</code> coloured by intensity,"
        " <code>/ground_truth/actors</code> for the held-out oracle, and"
        " <code>/pred/*</code> for one topic per pipeline round.</p>"
        "<p>Scrub to <strong>t ≈ 25 s</strong>: round 0 has objects standing on"
        " the stockpile and round 2 does not.</p>"
    )
    body += (
        "<div class=note><p><code>/ground_truth/*</code> is the oracle. It is"
        " in the file so you can see what a labeler was up against — a labeler"
        " must never read it.</p></div>"
    )
    return html(page("The scene", body))


def datasets_page(req: Request) raises -> Response:
    var body = String("<h1>The datasets</h1>")
    body += (
        "<p>Labels and ground truth as Apache Iceberg tables. Nothing is"
        " downloaded up front and there is no server in the path: the browser"
        " reads the Iceberg metadata, walks the manifests and pulls only the"
        " byte ranges of Parquet it needs.</p>"
    )
    body += VIEWER_HTML
    body += (
        "<p>The viewer is <a href='https://github.com/hyparam/icebird'>icebird</a>,"
        " about 43 KB of pure JavaScript — no WebAssembly. It resolves the"
        " table's current snapshot from <code>version-hint.text</code>, so the"
        " rows you are looking at are pinned to a snapshot id rather than to"
        " whatever happens to be latest. That id is printed under the table.</p>"
    )
    return html(page("Datasets", body, VIEWER_SCRIPT))


def gold_queue(req: Request) raises -> Response:
    var store = Store(ops_path())
    var tasks = store.open_reviews(String("gold"))
    var body = String("<h1>Gold labelling</h1>")
    body += (
        "<p>A gold set is what you score against, so it is authored rather"
        " than corrected: nothing becomes truth unless someone vouches for"
        " it. Tracks you do not keep are dropped.</p>"
    )
    if len(tasks) == 0:
        body += "<p class=empty>No scenes waiting to be labelled.</p>"
        return html(page("Gold labelling", body))
    body += (
        "<table><thead><tr><th>opened</th><th>candidates</th><th></th>"
        "</tr></thead><tbody>"
    )
    for t in tasks:
        body += String(
            "<tr><td class=mono>",
            esc(t.created_at),
            "</td><td class=mono>",
            esc(short_path(t.labels_path)),
            "</td><td><a href='/gold/",
            esc(t.id),
            "'>label →</a></td></tr>",
        )
    body += "</tbody></table>"
    return html(page("Gold labelling", body))


def gold_one(req: Request) raises -> Response:
    var id = String(req.param("id"))
    var store = Store(ops_path())
    var found = store.review(id)
    if not found:
        return not_found("no such task")
    ref task = found.value()

    var tracks = read_tracks(task.labels_path)
    var body = String("<h1>Author a gold set</h1>")
    body += String(
        "<p><code>",
        esc(short_path(task.labels_path)),
        "</code> · ",
        len(tracks),
        " candidate tracks · keep the ones you would stand behind.</p>",
    )
    body += String("<form method=post action='/gold/", esc(task.id), "'>")
    body += (
        "<table><thead><tr><th>keep</th><th>track</th><th>rows</th>"
        "<th>proposed</th><th>class</th></tr></thead><tbody>"
    )
    for t in tracks:
        body += String(
            "<tr><td><input type=checkbox name='keep_",
            esc(t[0]),
            "' value='1'></td><td class=mono>",
            esc(t[0]),
            "</td><td class=mono>",
            esc(t[2]),
            "</td><td class=mono>",
            esc(t[1]),
            "</td><td><input name='cls_",
            esc(t[0]),
            "' value='",
            esc(t[1]),
            "' style='font:inherit;padding:.2rem .4rem;border:1px solid"
            " var(--border);border-radius:5px;background:var(--surface);"
            "color:var(--ink)'></td></tr>",
        )
    body += "</tbody></table>"
    body += (
        "<div class=actions><button class=button type=submit>"
        "Publish as gold and resume</button></div></form>"
    )
    return html(page("Gold labelling", body))


def submit_gold(req: Request) raises -> Response:
    if read_only():
        return refuse("read-only: this deployment cannot publish a gold set")
    if not origin_ok(req):
        return refuse("cross-site request refused")

    var id = String(req.param("id"))
    var store = Store(ops_path())
    var found = store.review(id)
    if not found:
        return not_found("no such task")
    ref task = found.value()

    var tracks = read_tracks(task.labels_path)
    var form = parse_form(req.text())
    for t in tracks:
        # Unchecked means excluded. An unanswered track must not become truth
        # by default, so only an explicit keep is recorded.
        if form_get(form, String("keep_") + t[0]) != "1":
            continue
        store.add_edit(task.id, t[0], String("keep"), String(""), String("1"))
        var name = form_get(form, String("cls_") + t[0])
        if name.byte_length() > 0 and name != t[1]:
            store.add_edit(task.id, t[0], String("cls"), t[1], name)

    var client = HttpClient()
    _ = client.post(
        ingress() + "/restate/awakeables/" + task.awakeable_id + "/resolve",
        String('"gold"'),
    )
    return redirect("/gold")


def new_scene(req: Request) raises -> Response:
    """Start a run on a fresh random seed. Generation itself is a stage."""
    if read_only():
        return refuse("read-only: this deployment cannot start a run")
    if not origin_ok(req):
        return refuse("cross-site request refused")
    var seed = Int(random_ui64(1, 100000))
    var work = work_root() + "/seed" + String(seed)
    if not exists(work):
        makedirs(work, exist_ok=True)
    var store = Store(ops_path())
    var id = store.create_invocation(work + "/scene.mcap", seed, work)
    return redirect("/invocations/" + id)


def step_once(req: Request) raises -> Response:
    """Ask the orchestrator to advance this run by one stage."""
    if read_only():
        return refuse("read-only: this deployment cannot advance a run")
    if not origin_ok(req):
        return refuse("cross-site request refused")
    var id = String(req.param("id"))
    var store = Store(ops_path())
    var found = store.invocation(id)
    if not found:
        return not_found("no such run")
    ref inv = found.value()

    var client = HttpClient()
    var url = ingress() + "/RefineryLoop/seed" + String(inv.seed) + "/step"
    _ = client.post(url, loop_payload(inv, sitegen_dir()))
    return redirect("/invocations/" + id)


@fieldwise_init
struct Guarded(Copyable, Handler, Movable):
    """The Host gate, in front of every route rather than inside each one.

    A check repeated in each handler is a check that a new route forgets. This
    one cannot be forgotten: nothing reaches the router without passing it.
    """

    var inner: Router

    def serve(self, req: Request) raises -> Response:
        if not host_allowed(req):
            # Say which Host was refused and what is allowed. A bare 403 sends
            # you looking at Cloudflare, the tunnel, and DNS before the one
            # place that actually rejected it -- which is exactly the wrong
            # order, and the common cause is simply a public hostname missing
            # from LABELCONTROL_ALLOWED_HOSTS.
            var seen = String(req.headers.get("host"))
            var names = String("")
            var allowed = allowed_hosts()
            for i in range(len(allowed)):
                if i > 0:
                    names += ", "
                names += allowed[i]
            print(
                "refused Host:",
                seen if seen.byte_length() > 0 else String("(none)"),
                "— allowed:",
                names,
            )
            var body = String(
                "Refused: this server does not answer to Host '",
                seen,
                "'.\nAllowed: ",
                names,
                "\nAdd it with LABELCONTROL_ALLOWED_HOSTS.\n",
            )
            var denied = Response(403, "Forbidden", to_bytes(body))
            denied.headers.set("content-type", "text/plain; charset=utf-8")
            return denied^
        return self.inner.serve(req)


def main() raises:
    # Without this the generator is deterministic across process starts, so
    # every restart hands out the same "random" seed and the second run
    # collides with the first one's work directory.
    seed_rng()

    var r = Router()
    r.get("/", timeline)
    r.get("/invocations/:id", detail)
    r.post("/scenes/new", new_scene)
    r.post("/invocations/:id/step", step_once)
    r.get("/data", data_page)
    r.get("/datasets", datasets_page)
    r.get("/gold", gold_queue)
    r.get("/gold/:id", gold_one)
    r.post("/gold/:id", submit_gold)
    r.get("/review", review_queue)
    r.get("/review/:id", review_one)
    r.post("/review/:id", submit_review)

    var addr = listen_addr()
    print(
        String("label control on http://") + String(addr),
        "— ops.db:",
        ops_path(),
    )
    var hosts = allowed_hosts()
    var names = String("")
    for i in range(len(hosts)):
        if i > 0:
            names += ", "
        names += hosts[i]
    print("answering to Host:", names)
    if read_only():
        print("read-only: the write endpoints are disabled")
    else:
        var public = False
        for h in hosts:
            if h != "127.0.0.1" and h != "localhost" and h != "[::1]":
                public = True
        if public:
            print(
                "WARNING: writes are ENABLED and a non-loopback host is"
                " allowed. Anyone who can reach this can start runs and edit"
                " labels. Set LABELCONTROL_READONLY=1 or put an access policy"
                " in front."
            )

    var srv = HttpServer.bind(addr)
    srv.serve(Guarded(r^), num_workers=1)
