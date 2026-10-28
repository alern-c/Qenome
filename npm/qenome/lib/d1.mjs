const prefix = "QENOME_D1_RECORD ";
const noticePrefix = "QENOME_D1_NOTICE ";
const version = 1;
const nativeStatements = new WeakMap();
const statementSql = new WeakMap();
const statementValues = new WeakMap();
let noticed = false;

function typeOf(value) {
  if (value === null) return "null";
  if (typeof value === "number") return Number.isInteger(value) ? "int" : "real";
  if (typeof value === "string") return "text";
  if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) return "blob";
  return "other";
}

function emit(sql, values, op) {
  if (!noticed) {
    noticed = true;
    try {
      console.log(
        noticePrefix +
          "qenome/d1 writes the SQL and bind values to this output. Use it only for local development and tests, keep the log private, and do not ship it to production."
      );
    } catch (error) {
      void error;
    }
  }
  let line;
  try {
    const types = values.map(typeOf);
    const binds = values.map((value, index) => (types[index] === "blob" ? null : value));
    line = prefix + JSON.stringify({ v: version, op, sql, types, binds });
  } catch (error) {
    void error;
    return;
  }
  try {
    console.log(line);
  } catch (error) {
    void error;
  }
}

function wrapStatement(native, sql, values) {
  const bound = new Map();
  const wrapped = new Proxy(native, {
    get(target, key) {
      if (key === "bind") {
        return (...next) => wrapStatement(target.bind(...next), sql, next);
      }
      if (key === "all") {
        return async () => {
          const result = await target.all();
          emit(sql, values, "all");
          return result;
        };
      }
      if (key === "run") {
        return async () => {
          const result = await target.run();
          emit(sql, values, "run");
          return result;
        };
      }
      if (key === "first") {
        return async (column) => {
          const result = column === undefined ? await target.first() : await target.first(column);
          emit(sql, values, "first");
          return result;
        };
      }
      if (key === "raw") {
        return async (options) => {
          const result = await target.raw(options);
          emit(sql, values, "raw");
          return result;
        };
      }
      const value = Reflect.get(target, key, target);
      if (typeof value !== "function") return value;
      let call = bound.get(key);
      if (call === undefined) {
        call = value.bind(target);
        bound.set(key, call);
      }
      return call;
    },
  });
  nativeStatements.set(wrapped, native);
  statementSql.set(wrapped, sql);
  statementValues.set(wrapped, values);
  return wrapped;
}

export function wrapD1(db) {
  const bound = new Map();
  return new Proxy(db, {
    get(target, key) {
      if (key === "prepare") {
        return (sql) => wrapStatement(target.prepare(sql), sql, []);
      }
      if (key === "batch") {
        return async (statements) => {
          const natives = statements.map((statement) => nativeStatements.get(statement) ?? statement);
          const result = await target.batch(natives);
          for (const statement of statements) {
            const native = nativeStatements.get(statement);
            if (native === undefined) continue;
            emit(statementSql.get(statement), statementValues.get(statement), "batch");
          }
          return result;
        };
      }
      if (key === "exec") {
        return async (sql) => {
          const result = await target.exec(sql);
          emit(sql, [], "exec");
          return result;
        };
      }
      const value = Reflect.get(target, key, target);
      if (typeof value !== "function") return value;
      let call = bound.get(key);
      if (call === undefined) {
        call = value.bind(target);
        bound.set(key, call);
      }
      return call;
    },
  });
}
