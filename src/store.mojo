"""Read-only queries against the orchestrator's ops.db.

The site never writes run state — the orchestrator owns those tables. That is
what makes SQLite safe as the seam between two processes: WAL for concurrent
readers, and exactly one writer per table.

The one exception is creating an invocation, which the new-scene button does.
It writes only `pipeline_invocation`, and only rows the orchestrator has not
seen yet.
"""

from sqlite import Database


# Same DDL as Refinery/src/refinery/opsdb.mojo, which is the source of truth.
# Repeated here only so the site can be started first -- the new-scene button
# writes a row before the orchestrator has ever opened the database. Every
# statement is IF NOT EXISTS, so whoever gets there first wins and the other
# is a no-op.
comptime SCHEMA = """
CREATE TABLE IF NOT EXISTS pipeline_invocation (
  id          TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  scene_path  TEXT NOT NULL,
  seed        INTEGER NOT NULL,
  work_dir    TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'pending',
  restate_id  TEXT,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at  TEXT
);

CREATE TABLE IF NOT EXISTS step_run (
  id            TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  invocation_id TEXT NOT NULL REFERENCES pipeline_invocation(id),
  seq           INTEGER NOT NULL,
  step_name     TEXT NOT NULL,
  executor      TEXT NOT NULL,
  status        TEXT NOT NULL,
  params_json   TEXT,
  inputs_json   TEXT,
  outputs_json  TEXT,
  metrics_json  TEXT,
  log_path      TEXT,
  error         TEXT,
  started_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  finished_at   TEXT
);
CREATE INDEX IF NOT EXISTS step_run_by_invocation
  ON step_run (invocation_id, seq);

CREATE TABLE IF NOT EXISTS router_decision (
  id              TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  invocation_id   TEXT NOT NULL REFERENCES pipeline_invocation(id),
  seq             INTEGER NOT NULL,
  candidates_json TEXT NOT NULL,
  chosen          TEXT NOT NULL,
  reason          TEXT,
  model           TEXT NOT NULL,
  created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS router_decision_by_invocation
  ON router_decision (invocation_id, seq);

CREATE TABLE IF NOT EXISTS review_task (
  id            TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  invocation_id TEXT NOT NULL REFERENCES pipeline_invocation(id),
  step_run_id   TEXT,
  labels_path   TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'open',
  awakeable_id  TEXT,
  created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  resolved_at   TEXT
);

CREATE TABLE IF NOT EXISTS review_edit (
  id             TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  review_task_id TEXT NOT NULL REFERENCES review_task(id),
  track_id       TEXT NOT NULL,
  t              REAL,
  field          TEXT NOT NULL,
  old_value      TEXT,
  new_value      TEXT,
  created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- The idempotency ledger: what `RunContext.step()` kept in manifest.json.
-- In the database rather than a JSON file because the manifest was rewritten
-- whole after every step and was last-writer-wins between concurrent runs.
CREATE TABLE IF NOT EXISTS step_ledger (
  work_dir     TEXT NOT NULL,
  step_name    TEXT NOT NULL,
  key          TEXT NOT NULL,
  outputs_json TEXT NOT NULL,
  metrics_json TEXT,
  finished_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY (work_dir, step_name)
);
"""


@fieldwise_init
struct Invocation(Copyable, Movable):
    var id: String
    var scene_path: String
    var seed: Int
    var work_dir: String
    var status: String
    var created_at: String
    var steps: Int


@fieldwise_init
struct StepRow(Copyable, Movable):
    var seq: Int
    var name: String
    var executor: String
    var status: String
    var metrics: String
    var started_at: String
    var finished_at: String
    var error: String


@fieldwise_init
struct DecisionRow(Copyable, Movable):
    var seq: Int
    var chosen: String
    var candidates: String
    var model: String
    var reason: String


struct Store(Movable):
    var db: Database

    def __init__(out self, path: String) raises:
        self.db = Database(path)
        self.db.execute("PRAGMA journal_mode=WAL")
        for part in SCHEMA.split(";"):
            var sql = String(String(part).strip())
            if sql.byte_length() > 0:
                self.db.execute(sql)

    def invocations(mut self, limit: Int = 50) raises -> List[Invocation]:
        var out = List[Invocation]()
        var q = self.db.prepare(
            "SELECT i.id, i.scene_path, i.seed, i.work_dir, i.status,"
            " i.created_at, (SELECT COUNT(*) FROM step_run s"
            "   WHERE s.invocation_id = i.id)"
            " FROM pipeline_invocation i"
            " ORDER BY i.created_at DESC LIMIT ?"
        )
        q.bind_int(1, limit)
        while True:
            var row = q.step()
            if not row:
                break
            ref r = row.value()
            out.append(
                Invocation(
                    r.text_val(0),
                    r.text_val(1),
                    r.int_val(2),
                    r.text_val(3),
                    r.text_val(4),
                    r.text_val(5),
                    r.int_val(6),
                )
            )
        return out^

    def invocation(mut self, id: String) raises -> Optional[Invocation]:
        var all = self.invocations(200)
        for inv in all:
            if inv.id == id:
                return Optional(inv.copy())
        return None

    def steps(mut self, invocation_id: String) raises -> List[StepRow]:
        var out = List[StepRow]()
        var q = self.db.prepare(
            "SELECT seq, step_name, executor, status,"
            " COALESCE(metrics_json,''), started_at,"
            " COALESCE(finished_at,''), COALESCE(error,'')"
            " FROM step_run WHERE invocation_id = ? ORDER BY seq"
        )
        q.bind_text(1, invocation_id)
        while True:
            var row = q.step()
            if not row:
                break
            ref r = row.value()
            out.append(
                StepRow(
                    r.int_val(0),
                    r.text_val(1),
                    r.text_val(2),
                    r.text_val(3),
                    r.text_val(4),
                    r.text_val(5),
                    r.text_val(6),
                    r.text_val(7),
                )
            )
        return out^

    def decisions(mut self, invocation_id: String) raises -> List[DecisionRow]:
        var out = List[DecisionRow]()
        var q = self.db.prepare(
            "SELECT seq, chosen, candidates_json, model, COALESCE(reason,'')"
            " FROM router_decision WHERE invocation_id = ? ORDER BY seq"
        )
        q.bind_text(1, invocation_id)
        while True:
            var row = q.step()
            if not row:
                break
            ref r = row.value()
            out.append(
                DecisionRow(
                    r.int_val(0),
                    r.text_val(1),
                    r.text_val(2),
                    r.text_val(3),
                    r.text_val(4),
                )
            )
        return out^

    def create_invocation(
        mut self, scene_path: String, seed: Int, work_dir: String
    ) raises -> String:
        var q = self.db.prepare(
            "INSERT INTO pipeline_invocation (scene_path, seed, work_dir)"
            " VALUES (?, ?, ?) RETURNING id"
        )
        q.bind_text(1, scene_path)
        q.bind_int(2, seed)
        q.bind_text(3, work_dir)
        var row = q.step()
        if not row:
            raise Error("could not create invocation")
        ref r = row.value()
        return r.text_val(0)
