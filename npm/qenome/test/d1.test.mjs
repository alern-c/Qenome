import assert from "node:assert/strict";
import { wrapD1 } from "../lib/d1.mjs";

const prefix = "QENOME_D1_RECORD ";
const noticePrefix = "QENOME_D1_NOTICE ";
const realLog = console.log;
const lines = [];
console.log = (line) => {
  lines.push(String(line));
};

class FakeStatement {
  constructor(db, sql, values = []) {
    this.db = db;
    this.sql = sql;
    this.values = values;
    this.self = this;
    this.fail = false;
  }

  assertSelf() {
    assert.equal(this, this.self);
  }

  bind(...values) {
    this.assertSelf();
    return new FakeStatement(this.db, this.sql, values);
  }

  async all() {
    this.assertSelf();
    if (this.fail) throw new Error("boom");
    return { results: [{ sql: this.sql, values: this.values }], success: true };
  }

  async run() {
    this.assertSelf();
    return { success: true, meta: { changes: 1 } };
  }

  async first(column) {
    this.assertSelf();
    return { column: column ?? null, sql: this.sql };
  }

  async raw(options) {
    this.assertSelf();
    return [this.sql, this.values, options ?? null];
  }
}

class FakeDb {
  constructor() {
    this.self = this;
    this.prepareCount = 0;
  }

  prepare(sql) {
    assert.equal(this, this.self);
    this.prepareCount += 1;
    return new FakeStatement(this, sql);
  }

  async batch(statements) {
    assert.equal(this, this.self);
    assert(statements.every((statement) => statement instanceof FakeStatement));
    return statements.map((statement) => ({ values: statement.values }));
  }

  async exec(sql) {
    assert.equal(this, this.self);
    return { count: 1, sql };
  }

  withSession(constraint) {
    assert.equal(this, this.self);
    return { constraint };
  }

  dump() {
    assert.equal(this, this.self);
    return new ArrayBuffer(0);
  }
}

function parseRecords(list) {
  return list
    .filter((line) => line.startsWith(prefix))
    .map((line) => JSON.parse(line.slice(prefix.length)));
}

function records() {
  return parseRecords(lines);
}

function take() {
  const taken = lines.slice();
  lines.length = 0;
  return taken;
}

const db = wrapD1(new FakeDb());

assert.deepEqual(await db.prepare("SELECT a FROM t WHERE id = ?").bind(7).all(), {
  results: [{ sql: "SELECT a FROM t WHERE id = ?", values: [7] }],
  success: true,
});
assert.deepEqual(await db.prepare("SELECT ?").bind(1).bind(2).all(), {
  results: [{ sql: "SELECT ?", values: [2] }],
  success: true,
});
assert.deepEqual(await db.prepare("SELECT ?").bind(3).run(), { success: true, meta: { changes: 1 } });
assert.deepEqual(await db.prepare("SELECT ?").bind(4).first("a"), { column: "a", sql: "SELECT ?" });
assert.deepEqual(await db.prepare("SELECT ?").bind(5).raw({ columnNames: true }), [
  "SELECT ?",
  [5],
  { columnNames: true },
]);
assert.deepEqual(await db.batch([db.prepare("SELECT ?").bind("x"), db.prepare("SELECT ?").bind("y")]), [
  { values: ["x"] },
  { values: ["y"] },
]);
assert.deepEqual(await db.exec("CREATE TABLE t(a)"), { count: 1, sql: "CREATE TABLE t(a)" });
assert.equal(db.withSession("first-primary").constraint, "first-primary");
assert.ok(db.dump() instanceof ArrayBuffer);
assert.equal(db.prepareCount, 7);

const taken = take();
assert.equal(taken[0].startsWith(noticePrefix), true);
assert.equal(taken.filter((line) => line.startsWith(noticePrefix)).length, 1);
assert.deepEqual(parseRecords(taken), [
  { v: 1, op: "all", sql: "SELECT a FROM t WHERE id = ?", types: ["int"], binds: [7] },
  { v: 1, op: "all", sql: "SELECT ?", types: ["int"], binds: [2] },
  { v: 1, op: "run", sql: "SELECT ?", types: ["int"], binds: [3] },
  { v: 1, op: "first", sql: "SELECT ?", types: ["int"], binds: [4] },
  { v: 1, op: "raw", sql: "SELECT ?", types: ["int"], binds: [5] },
  { v: 1, op: "batch", sql: "SELECT ?", types: ["text"], binds: ["x"] },
  { v: 1, op: "batch", sql: "SELECT ?", types: ["text"], binds: ["y"] },
  { v: 1, op: "exec", sql: "CREATE TABLE t(a)", types: [], binds: [] },
]);

await db.prepare("SELECT ?").bind(new Uint8Array([1, 2])).all();
await db.prepare("SELECT ?").bind(true).all();
await db.prepare("SELECT ?").bind("a:b").all();
const special = records();
assert.deepEqual(special[0].types, ["blob"]);
assert.deepEqual(special[0].binds, [null]);
assert.deepEqual(special[1].types, ["other"]);
assert.deepEqual(special[2].types, ["text"]);
assert.deepEqual(special[2].binds, ["a:b"]);

class FailingDb extends FakeDb {
  prepare(sql) {
    const statement = super.prepare(sql);
    statement.fail = true;
    return statement;
  }
}

take();
const failing = wrapD1(new FailingDb());
await assert.rejects(() => failing.prepare("SELECT 1").all(), /boom/);
assert.deepEqual(records(), []);

take();
console.log = () => {
  throw new Error("no output");
};
assert.deepEqual(await db.prepare("SELECT ?").bind(6).all(), {
  results: [{ sql: "SELECT ?", values: [6] }],
  success: true,
});
console.log = (line) => {
  lines.push(String(line));
};

take();
class ThrowingStatement extends FakeStatement {
  async all() {
    this.assertSelf();
    throw new Error("native failure");
  }
}

class ThrowingDb extends FakeDb {
  prepare(sql) {
    return new ThrowingStatement(this, sql);
  }
}

await assert.rejects(() => wrapD1(new ThrowingDb()).prepare("SELECT 1").all(), /native failure/);
assert.deepEqual(records(), []);

console.log = realLog;
console.log("record wrapper: ok");
