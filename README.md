# LabelControl

The local control site for the labelrefinery auto-labeling loop: what ran, in
what order, and what the router was choosing between. A
[flare](https://github.com/ehsanmok/flare) server in Mojo, on loopback.

```sh
pixi run flare-ffi     # once: build flare's C shims into this env
./run.sh               # everything: restate, executor, orchestrator, site
./run.sh stop
```

`./run.sh` prints <http://127.0.0.1:20000> when it is up. `LABELCONTROL_PORT`
changes it. To run only the site
against an existing database, `pixi run serve`.

Four processes. The executor and the orchestrator are separate Restate
endpoints on purpose: restate.mojo's driver is single-threaded and deadlocks if
a handler calls one served by the same process.

Environment: `LABELCONTROL_OPS` (the orchestrator's `ops.db`),
`LABELCONTROL_WORK` (where run directories go), `LABELCONTROL_SITEGEN`,
`LABELCONTROL_RESTATE` (ingress, default `http://127.0.0.1:8080`).

## Exposing it

Loopback only by default, and the `Host` header must be one it answers to --
binding 127.0.0.1 stops remote connections, but DNS rebinding can still point a
browser tab here with an attacker-controlled Host.

To serve it through a Cloudflare Tunnel, allow the public name:

```sh
LABELCONTROL_ALLOWED_HOSTS=demo.labelrefinery.org ./run.sh
cloudflared tunnel --url http://127.0.0.1:20000 run <tunnel>
```

**Nothing here authenticates.** For a public deployment, run it read-only:

```sh
LABELCONTROL_READONLY=1 LABELCONTROL_ALLOWED_HOSTS=demo.labelrefinery.org ./run.sh
```

That serves the timeline, the run detail and the review queue, and refuses the
three write endpoints. Writable-and-public means anyone with the URL can start
runs — one click is a scene generation, a 600-frame geometry pass and a
training run — and can submit reviews that edit labels. If you want the buttons
live, put Cloudflare Access in front instead; the startup banner warns when
writes are enabled and a non-loopback host is allowed.

Cross-site posting is refused independently: a request carrying a foreign
`Origin` gets a 403, so another site cannot drive the loop through a visitor's
browser.

## How it fits

The site does not share a process with the orchestrator and does not call it
except through the Restate ingress. **The database is the interface**: WAL so
the site reads while the orchestrator writes, and one writer per table — the
orchestrator owns the run tables, the site owns `review_edit` and creates the
invocation row the new-scene button starts.

Two buttons. *New random scene* picks a seed and creates a run; generation
itself is a pipeline stage, so it shows up on the timeline like everything
else. *Run next stage* asks the orchestrator to advance by one.

## Why flare comes from the millfolio checkout

`../../millfolio/flare` is pinned at flare's "Mojo 1.0.0 / MAX 26.5.0 — the
release" commit. The standalone `dev/flare` checkout is months older and does
not compile against 1.0.0. flare is consumed by **source path**, not as a
package: its own build backend wants a newer pixi than this machine has, which
is the same wall millfolio hit. Consuming by path also means flare's
`mojo ==1.0.0b1` pin does not apply, so this environment stays on stable
alongside `sqlite-mojo`.
