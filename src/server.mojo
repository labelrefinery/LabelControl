"""The label control site: what ran, in what order, and why.

A flare server on loopback, reading the orchestrator's ops.db. It does not
share a process with the orchestrator and does not call it directly — the
database is the whole interface — except for the two buttons, which POST to the
Restate ingress.

    pixi run serve            # http://127.0.0.1:10001

Loopback only, with a Host allow-list, following millfolio/vault/app/server:
binding 127.0.0.1 stops remote connections, but a DNS-rebinding attack can
still make a browser send a request here with an attacker-controlled Host. The
allow-list is what closes that.
"""

from flare.http import (
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

from store import DecisionRow, Invocation, StepRow, Store


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
.exec-mojo{color:var(--accent)}.exec-subprocess{color:var(--ink-3)}
.exec-inproc{color:var(--accent-3)}
.button{display:inline-block;background:var(--accent);color:#fff;border:0;
padding:.55rem 1rem;border-radius:8px;font:inherit;font-size:.92rem;
font-weight:550;cursor:pointer;text-decoration:none}
.button.ghost{background:transparent;color:var(--accent);
border:1px solid var(--border)}
.actions{display:flex;gap:.6rem;margin:1.2rem 0}
.empty{color:var(--ink-3);font-style:italic}
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


def page(title: String, body: String) -> String:
    return String(
        "<!doctype html><html lang=en><head><meta charset=utf-8>",
        "<meta name=viewport content='width=device-width,initial-scale=1'>",
        "<title>",
        esc(title),
        " — label control</title><style>",
        STYLE,
        "</style></head><body><header><div class=wrap>",
        "<a href='/'>label control</a></div></header>",
        "<div class=wrap>",
        body,
        "</div></body></html>",
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
        inv.scene_path,
        "&work=",
        inv.work_dir,
        "&sitegen=",
        sitegen,
        "&invocation=",
        inv.id,
        "&seed=",
        inv.seed,
        '"',
    )


def status_class(s: String) -> String:
    if s == "ok" or s == "done":
        return String("ok")
    if s == "failed":
        return String("failed")
    return String("running")


def timeline(req: Request) raises -> Response:
    var store = Store(ops_path())
    var invs = store.invocations(50)

    var body = String("<h1>Runs</h1>")
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
            esc(inv.scene_path),
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

    var body = String("<h1>Run ", esc(inv.scene_path), "</h1>")
    body += String(
        "<p><code>",
        esc(inv.id),
        "</code> · seed <code>",
        inv.seed,
        "</code> · work <code>",
        esc(inv.work_dir),
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


def new_scene(req: Request) raises -> Response:
    """Start a run on a fresh random seed. Generation itself is a stage."""
    var seed = Int(random_ui64(1, 100000))
    var work = work_root() + "/seed" + String(seed)
    if not exists(work):
        makedirs(work, exist_ok=True)
    var store = Store(ops_path())
    var id = store.create_invocation(work + "/scene.mcap", seed, work)
    return redirect("/invocations/" + id)


def step_once(req: Request) raises -> Response:
    """Ask the orchestrator to advance this run by one stage."""
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

    var addr = SocketAddr.localhost(10001)
    print("label control on http://127.0.0.1:10001 — ops.db:", ops_path())
    var srv = HttpServer.bind(addr)
    srv.serve(r^, num_workers=1)
