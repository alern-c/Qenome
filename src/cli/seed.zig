const std = @import("std");
const Io = std.Io;
const sqlite = @import("../sqlite.zig");
const cli_control = @import("control.zig");

pub const max_spec_bytes: usize = 1024 * 1024;
pub const max_tables: usize = 100;
pub const max_columns: usize = 2000;
pub const max_rows_per_table: u64 = 10_000_000;
pub const max_total_rows: u64 = 20_000_000;

pub const Value = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    real: f64,
    text: []const u8,
};

pub const Ratio = struct {
    value: Value,
    otherwise: Value = .null,
    ratio: f64,
};

pub const Sequence = struct {
    from: i64 = 1,
    step: i64 = 1,
};

pub const Distribution = union(enum) {
    fixed: Value,
    uniform: []const Value,
    ratio: Ratio,
    sequence: Sequence,
};

pub const Column = struct {
    name: []const u8,
    distribution: Distribution,
};

pub const Table = struct {
    name: []const u8,
    rows: u64,
    columns: []const Column,
};

pub const Spec = struct {
    path: []const u8,
    seed: u64,
    tables: []const Table,
};

const ColumnInfo = struct {
    name: []const u8,
    default: ?[]const u8,
};

const SpecFileError = error{
    SpecTooLarge,
    SpecContainsNul,
};

const result_keys = [_][]const u8{ "seed", "tables" };
const table_keys = [_][]const u8{ "rows", "columns" };
const fixed_keys = [_][]const u8{ "kind", "value" };
const uniform_keys = [_][]const u8{ "kind", "values" };
const ratio_keys = [_][]const u8{ "kind", "value", "ratio", "otherwise" };
const sequence_keys = [_][]const u8{ "kind", "from", "step" };

pub fn load(io: Io, arena: std.mem.Allocator, path: []const u8, stderr: *Io.Writer) ?Spec {
    const data = readSpecFile(io, arena, path) catch |err| {
        stderr.print("error: cannot read the seed data spec '{s}': {s}\n", .{ path, readReason(err) }) catch {};
        return null;
    };
    const root_value = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch {
        invalid(stderr, path, "it is not valid JSON", .{});
        return null;
    };
    const root = switch (root_value) {
        .object => |object| object,
        else => {
            invalid(stderr, path, "it must be a JSON object", .{});
            return null;
        },
    };
    if (unknownKey(root, &result_keys)) |key| {
        invalid(stderr, path, "it has an unknown key '{s}'", .{key});
        return null;
    }

    var seed: u64 = 0;
    if (root.get("seed")) |seed_value| {
        const number = switch (seed_value) {
            .integer => |value| value,
            else => {
                invalid(stderr, path, "seed must be a non-negative integer", .{});
                return null;
            },
        };
        if (number < 0) {
            invalid(stderr, path, "seed must be a non-negative integer", .{});
            return null;
        }
        seed = @intCast(number);
    }

    const tables_value = root.get("tables") orelse {
        invalid(stderr, path, "it must have the key tables", .{});
        return null;
    };
    const tables_object = switch (tables_value) {
        .object => |object| object,
        else => {
            invalid(stderr, path, "tables must be an object keyed by table name", .{});
            return null;
        },
    };
    if (tables_object.count() < 1 or tables_object.count() > max_tables) {
        invalid(stderr, path, "tables must hold 1 to {d} entries", .{max_tables});
        return null;
    }

    var tables: std.ArrayList(Table) = .empty;
    var total_rows: u64 = 0;
    var iterator = tables_object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (name.len == 0) {
            invalid(stderr, path, "a table name cannot be empty", .{});
            return null;
        }
        if (std.mem.indexOfScalar(u8, name, 0) != null) {
            invalid(stderr, path, "a table name cannot contain a NUL byte", .{});
            return null;
        }
        if (std.ascii.startsWithIgnoreCase(name, "sqlite_")) {
            invalid(stderr, path, "the table '{s}' is internal to SQLite", .{name});
            return null;
        }
        const table_object = switch (entry.value_ptr.*) {
            .object => |object| object,
            else => {
                invalid(stderr, path, "table '{s}' must be an object with rows and optional columns", .{name});
                return null;
            },
        };
        if (unknownKey(table_object, &table_keys)) |key| {
            invalid(stderr, path, "table '{s}' has an unknown key '{s}'", .{ name, key });
            return null;
        }
        const rows_value = table_object.get("rows") orelse {
            invalid(stderr, path, "table '{s}' must have rows", .{name});
            return null;
        };
        const rows_number = switch (rows_value) {
            .integer => |value| value,
            else => {
                invalid(stderr, path, "table '{s}' rows must be a non-negative integer", .{name});
                return null;
            },
        };
        if (rows_number < 0) {
            invalid(stderr, path, "table '{s}' rows must be a non-negative integer", .{name});
            return null;
        }
        const rows: u64 = @intCast(rows_number);
        if (rows > max_rows_per_table) {
            invalid(stderr, path, "table '{s}' rows must be at most {d}", .{ name, max_rows_per_table });
            return null;
        }
        if (rows > max_total_rows - total_rows) {
            invalid(stderr, path, "the total rows must be at most {d}", .{max_total_rows});
            return null;
        }
        total_rows += rows;

        var columns: std.ArrayList(Column) = .empty;
        if (table_object.get("columns")) |columns_value| {
            const columns_object = switch (columns_value) {
                .object => |object| object,
                else => {
                    invalid(stderr, path, "table '{s}' columns must be an object keyed by column name", .{name});
                    return null;
                },
            };
            if (columns_object.count() > max_columns) {
                invalid(stderr, path, "table '{s}' columns must hold at most {d} entries", .{ name, max_columns });
                return null;
            }
            var column_iterator = columns_object.iterator();
            while (column_iterator.next()) |column_entry| {
                const column_name = column_entry.key_ptr.*;
                if (column_name.len == 0) {
                    invalid(stderr, path, "table '{s}' has a column with an empty name", .{name});
                    return null;
                }
                if (std.mem.indexOfScalar(u8, column_name, 0) != null) {
                    invalid(stderr, path, "table '{s}' has a column name with a NUL byte", .{name});
                    return null;
                }
                const column = parseColumn(arena, column_entry.value_ptr.*, name, column_name, path, stderr) orelse return null;
                columns.append(arena, column) catch return outOfMemory(Spec, stderr);
            }
        }
        tables.append(arena, .{ .name = name, .rows = rows, .columns = columns.items }) catch return outOfMemory(Spec, stderr);
    }

    for (tables.items, 0..) |table, index| {
        for (tables.items[index + 1 ..]) |other| {
            if (std.ascii.eqlIgnoreCase(table.name, other.name)) {
                invalid(stderr, path, "the tables '{s}' and '{s}' differ only by case; SQLite treats them as the same table", .{ table.name, other.name });
                return null;
            }
        }
        for (table.columns, 0..) |column, column_index| {
            for (table.columns[column_index + 1 ..]) |other| {
                if (std.ascii.eqlIgnoreCase(column.name, other.name)) {
                    invalid(stderr, path, "table '{s}' has columns '{s}' and '{s}' that differ only by case; SQLite treats them as the same column", .{ table.name, column.name, other.name });
                    return null;
                }
            }
        }
    }

    return .{
        .path = path,
        .seed = seed,
        .tables = tables.items,
    };
}

fn parseColumn(
    arena: std.mem.Allocator,
    value: std.json.Value,
    table_name: []const u8,
    column_name: []const u8,
    path: []const u8,
    stderr: *Io.Writer,
) ?Column {
    const object = switch (value) {
        .object => |object| object,
        else => {
            invalid(stderr, path, "table '{s}' column '{s}' must be an object", .{ table_name, column_name });
            return null;
        },
    };
    const kind_value = object.get("kind") orelse {
        invalid(stderr, path, "table '{s}' column '{s}' must have kind", .{ table_name, column_name });
        return null;
    };
    const kind = switch (kind_value) {
        .string => |text| text,
        else => {
            invalid(stderr, path, "table '{s}' column '{s}' kind must be a string", .{ table_name, column_name });
            return null;
        },
    };

    if (std.mem.eql(u8, kind, "fixed")) {
        if (unknownKey(object, &fixed_keys)) |key| {
            invalid(stderr, path, "table '{s}' column '{s}' has an unknown key '{s}'", .{ table_name, column_name, key });
            return null;
        }
        const raw = object.get("value") orelse {
            invalid(stderr, path, "table '{s}' column '{s}' needs value for kind fixed", .{ table_name, column_name });
            return null;
        };
        const fixed = parseValue(raw) orelse {
            invalid(stderr, path, "table '{s}' column '{s}' value must be a string, number, boolean, or null", .{ table_name, column_name });
            return null;
        };
        return .{ .name = column_name, .distribution = .{ .fixed = fixed } };
    }

    if (std.mem.eql(u8, kind, "uniform")) {
        if (unknownKey(object, &uniform_keys)) |key| {
            invalid(stderr, path, "table '{s}' column '{s}' has an unknown key '{s}'", .{ table_name, column_name, key });
            return null;
        }
        const raw = object.get("values") orelse {
            invalid(stderr, path, "table '{s}' column '{s}' needs values for kind uniform", .{ table_name, column_name });
            return null;
        };
        const array = switch (raw) {
            .array => |items| items,
            else => {
                invalid(stderr, path, "table '{s}' column '{s}' values must be an array", .{ table_name, column_name });
                return null;
            },
        };
        if (array.items.len == 0) {
            invalid(stderr, path, "table '{s}' column '{s}' values must hold at least one value", .{ table_name, column_name });
            return null;
        }
        const values = arena.alloc(Value, array.items.len) catch return outOfMemory(Column, stderr);
        for (array.items, 0..) |item, index| {
            values[index] = parseValue(item) orelse {
                invalid(stderr, path, "table '{s}' column '{s}' values[{d}] must be a string, number, boolean, or null", .{ table_name, column_name, index });
                return null;
            };
        }
        return .{ .name = column_name, .distribution = .{ .uniform = values } };
    }

    if (std.mem.eql(u8, kind, "ratio")) {
        if (unknownKey(object, &ratio_keys)) |key| {
            invalid(stderr, path, "table '{s}' column '{s}' has an unknown key '{s}'", .{ table_name, column_name, key });
            return null;
        }
        const raw_value = object.get("value") orelse {
            invalid(stderr, path, "table '{s}' column '{s}' needs value for kind ratio", .{ table_name, column_name });
            return null;
        };
        const ratio_value = parseValue(raw_value) orelse {
            invalid(stderr, path, "table '{s}' column '{s}' value must be a string, number, boolean, or null", .{ table_name, column_name });
            return null;
        };
        const raw_ratio = object.get("ratio") orelse {
            invalid(stderr, path, "table '{s}' column '{s}' needs ratio for kind ratio", .{ table_name, column_name });
            return null;
        };
        const ratio = switch (raw_ratio) {
            .integer => |number| @as(f64, @floatFromInt(number)),
            .float => |number| number,
            else => {
                invalid(stderr, path, "table '{s}' column '{s}' ratio must be a number from 0 to 1", .{ table_name, column_name });
                return null;
            },
        };
        if (!(ratio >= 0 and ratio <= 1)) {
            invalid(stderr, path, "table '{s}' column '{s}' ratio must be a number from 0 to 1", .{ table_name, column_name });
            return null;
        }
        var otherwise: Value = .null;
        if (object.get("otherwise")) |raw_otherwise| {
            otherwise = parseValue(raw_otherwise) orelse {
                invalid(stderr, path, "table '{s}' column '{s}' otherwise must be a string, number, boolean, or null", .{ table_name, column_name });
                return null;
            };
        }
        return .{ .name = column_name, .distribution = .{ .ratio = .{ .value = ratio_value, .otherwise = otherwise, .ratio = ratio } } };
    }

    if (std.mem.eql(u8, kind, "sequence")) {
        if (unknownKey(object, &sequence_keys)) |key| {
            invalid(stderr, path, "table '{s}' column '{s}' has an unknown key '{s}'", .{ table_name, column_name, key });
            return null;
        }
        var sequence: Sequence = .{};
        if (object.get("from")) |raw| {
            sequence.from = switch (raw) {
                .integer => |number| number,
                else => {
                    invalid(stderr, path, "table '{s}' column '{s}' from must be an integer", .{ table_name, column_name });
                    return null;
                },
            };
        }
        if (object.get("step")) |raw| {
            sequence.step = switch (raw) {
                .integer => |number| number,
                else => {
                    invalid(stderr, path, "table '{s}' column '{s}' step must be an integer", .{ table_name, column_name });
                    return null;
                },
            };
        }
        return .{ .name = column_name, .distribution = .{ .sequence = sequence } };
    }

    invalid(stderr, path, "table '{s}' column '{s}' kind must be fixed, uniform, ratio, or sequence", .{ table_name, column_name });
    return null;
}

fn parseValue(value: std.json.Value) ?Value {
    return switch (value) {
        .null => .null,
        .bool => |flag| .{ .boolean = flag },
        .integer => |number| .{ .integer = number },
        .float => |number| .{ .real = number },
        .string => |text| .{ .text = text },
        else => null,
    };
}

fn unknownKey(object: std.json.ObjectMap, allowed: []const []const u8) ?[]const u8 {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                known = true;
                break;
            }
        }
        if (!known) return entry.key_ptr.*;
    }
    return null;
}

fn invalid(stderr: *Io.Writer, path: []const u8, comptime format: []const u8, args: anytype) void {
    stderr.print("error: the seed data spec '{s}' is not valid: ", .{path}) catch {};
    stderr.print(format, args) catch {};
    stderr.writeByte('\n') catch {};
}

fn outOfMemory(comptime T: type, stderr: *Io.Writer) ?T {
    stderr.writeAll("error: out of memory\n") catch {};
    return null;
}

fn readSpecFile(io: Io, allocator: std.mem.Allocator, path: []const u8) (SpecFileError || Io.Dir.ReadFileAllocError)![:0]u8 {
    const data = Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(max_spec_bytes + 1),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.StreamTooLong => return error.SpecTooLarge,
        else => |e| return e,
    };
    errdefer allocator.free(data);
    if (std.mem.indexOfScalar(u8, data, 0) != null) return error.SpecContainsNul;
    return data;
}

fn readReason(err: anyerror) []const u8 {
    return switch (err) {
        error.SpecTooLarge => "the file is larger than 1 MiB",
        error.SpecContainsNul => "the file contains a NUL byte",
        error.FileNotFound => "no such file",
        error.IsDir => "is a directory",
        error.AccessDenied => "permission denied",
        else => @errorName(err),
    };
}

pub fn apply(arena: std.mem.Allocator, path: [:0]const u8, spec: Spec, stderr: *Io.Writer) ?cli_control.ExitCode {
    var handle: ?*sqlite.sqlite3 = null;
    const open_rc = sqlite.sqlite3_open_v2(path, &handle, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_NOFOLLOW, null);
    const conn = handle orelse {
        stderr.print("error: the seed data could not open the sandbox copy '{s}'\n", .{path}) catch {};
        return .rejected;
    };
    var closed = false;
    defer if (!closed) {
        _ = sqlite.sqlite3_close(conn);
    };
    if (open_rc != sqlite.SQLITE_OK) {
        reportEngine(stderr, "open the sandbox copy", null, conn);
        return .rejected;
    }

    if (checkSchema(arena, spec, conn, stderr)) |code| return code;

    if (sqlite.sqlite3_exec(conn, "PRAGMA synchronous=OFF", null, null, null) != sqlite.SQLITE_OK) {
        reportEngine(stderr, "set synchronous=OFF", null, conn);
        return .rejected;
    }
    if (sqlite.sqlite3_exec(conn, "PRAGMA journal_mode=MEMORY", null, null, null) != sqlite.SQLITE_OK) {
        reportEngine(stderr, "set journal_mode=MEMORY", null, conn);
        return .rejected;
    }
    if (sqlite.sqlite3_exec(conn, "BEGIN", null, null, null) != sqlite.SQLITE_OK) {
        reportEngine(stderr, "start a transaction", null, conn);
        return .rejected;
    }
    var committed = false;
    defer if (!committed) {
        _ = sqlite.sqlite3_exec(conn, "ROLLBACK", null, null, null);
    };

    var random_source = std.Random.DefaultPrng.init(spec.seed);
    const random = random_source.random();
    for (spec.tables) |table| {
        if (cli_control.signalPending()) return cli_control.reportInterrupted(stderr);
        if (seedTable(arena, spec, table, random, conn, stderr)) |code| return code;
    }
    for (spec.tables) |table| {
        const quoted = quoteName(arena, table.name) catch {
            stderr.writeAll("error: out of memory\n") catch {};
            return .rejected;
        };
        const analyze_sql = std.fmt.allocPrintSentinel(arena, "ANALYZE {s}", .{quoted}, 0) catch {
            stderr.writeAll("error: out of memory\n") catch {};
            return .rejected;
        };
        if (sqlite.sqlite3_exec(conn, analyze_sql.ptr, null, null, null) != sqlite.SQLITE_OK) {
            reportEngine(stderr, "analyze table", table.name, conn);
            return .rejected;
        }
    }

    if (sqlite.sqlite3_exec(conn, "COMMIT", null, null, null) != sqlite.SQLITE_OK) {
        reportEngine(stderr, "commit the transaction", null, conn);
        return .rejected;
    }
    committed = true;

    closed = true;
    if (sqlite.sqlite3_close(conn) != sqlite.SQLITE_OK) {
        stderr.writeAll("error: the seed data could not close the sandbox copy\n") catch {};
        return .rejected;
    }
    return null;
}

fn checkSchema(arena: std.mem.Allocator, spec: Spec, conn: *sqlite.sqlite3, stderr: *Io.Writer) ?cli_control.ExitCode {
    for (spec.tables) |table| {
        if (cli_control.signalPending()) return cli_control.reportInterrupted(stderr);
        const columns = tableColumns(arena, table.name, conn, stderr) orelse return .rejected;
        if (columns.len == 0) {
            invalid(stderr, spec.path, "the database has no table '{s}'", .{table.name});
            return .rejected;
        }
        const triggered = tableHasTrigger(table.name, conn, stderr) orelse return .rejected;
        if (triggered) {
            invalid(stderr, spec.path, "table '{s}' has a trigger, so Qenome cannot replace it reproducibly; drop the trigger in the local database or use a table without triggers", .{table.name});
            return .rejected;
        }
        for (table.columns) |column| {
            if (!hasColumn(columns, column.name)) {
                invalid(stderr, spec.path, "table '{s}' has no column '{s}'", .{ table.name, column.name });
                return .rejected;
            }
        }
        for (columns) |info| {
            if (specNames(table.columns, info.name)) continue;
            if (info.default) |text| {
                if (!deterministicDefault(text)) {
                    invalid(stderr, spec.path, "table '{s}' column '{s}' has a default expression that Qenome cannot reproduce; list the column in the spec", .{ table.name, info.name });
                    return .rejected;
                }
            }
        }
    }
    return null;
}

fn hasColumn(columns: []const ColumnInfo, name: []const u8) bool {
    for (columns) |info| {
        if (std.ascii.eqlIgnoreCase(info.name, name)) return true;
    }
    return false;
}

fn specNames(columns: []const Column, name: []const u8) bool {
    for (columns) |column| {
        if (std.ascii.eqlIgnoreCase(column.name, name)) return true;
    }
    return false;
}

fn deterministicDefault(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "null") or std.ascii.eqlIgnoreCase(trimmed, "true") or std.ascii.eqlIgnoreCase(trimmed, "false")) return true;
    if (isStringLiteral(trimmed)) return true;
    if (isBlobLiteral(trimmed)) return true;
    if (std.fmt.parseInt(i64, trimmed, 0)) |_| return true else |_| {}
    if (std.fmt.parseFloat(f64, trimmed)) |_| return true else |_| {}
    return false;
}

fn isStringLiteral(text: []const u8) bool {
    if (text.len < 2 or text[0] != '\'' or text[text.len - 1] != '\'') return false;
    var index: usize = 1;
    while (index + 1 < text.len) : (index += 1) {
        if (text[index] != '\'') continue;
        if (text[index + 1] != '\'') return false;
        index += 1;
    }
    return true;
}

fn isBlobLiteral(text: []const u8) bool {
    if (text.len < 3) return false;
    if (text[0] != 'x' and text[0] != 'X') return false;
    if (text[1] != '\'' or text[text.len - 1] != '\'') return false;
    var index: usize = 2;
    while (index + 1 < text.len) : (index += 1) {
        if (!std.ascii.isHex(text[index])) return false;
    }
    return true;
}

fn tableColumns(arena: std.mem.Allocator, table: []const u8, conn: *sqlite.sqlite3, stderr: *Io.Writer) ?[]const ColumnInfo {
    var statement: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(conn, "SELECT name, dflt_value FROM pragma_table_info(?1)", -1, &statement, null) != sqlite.SQLITE_OK) {
        reportEngine(stderr, "read the schema", null, conn);
        return null;
    }
    const prepared = statement orelse {
        reportEngine(stderr, "read the schema", null, conn);
        return null;
    };
    defer _ = sqlite.sqlite3_finalize(prepared);

    if (sqlite.sqlite3_bind_text(prepared, 1, table.ptr, @intCast(table.len), sqlite.SQLITE_STATIC) != sqlite.SQLITE_OK) {
        reportEngine(stderr, "read the schema", null, conn);
        return null;
    }

    var infos: std.ArrayList(ColumnInfo) = .empty;
    while (true) {
        const rc = sqlite.sqlite3_step(prepared);
        if (rc == sqlite.SQLITE_DONE) break;
        if (rc != sqlite.SQLITE_ROW) {
            reportEngine(stderr, "read the schema", null, conn);
            return null;
        }
        const text = sqlite.sqlite3_column_text(prepared, 0) orelse "";
        const length: usize = @intCast(sqlite.sqlite3_column_bytes(prepared, 0));
        const name = arena.dupe(u8, text[0..length]) catch {
            stderr.writeAll("error: out of memory\n") catch {};
            return null;
        };
        var default: ?[]const u8 = null;
        if (sqlite.sqlite3_column_type(prepared, 1) != sqlite.SQLITE_NULL) {
            const default_text = sqlite.sqlite3_column_text(prepared, 1) orelse "";
            const default_length: usize = @intCast(sqlite.sqlite3_column_bytes(prepared, 1));
            default = arena.dupe(u8, default_text[0..default_length]) catch {
                stderr.writeAll("error: out of memory\n") catch {};
                return null;
            };
        }
        infos.append(arena, .{ .name = name, .default = default }) catch {
            stderr.writeAll("error: out of memory\n") catch {};
            return null;
        };
    }
    return infos.items;
}

fn tableHasTrigger(table: []const u8, conn: *sqlite.sqlite3, stderr: *Io.Writer) ?bool {
    var statement: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(conn, "SELECT count(*) FROM main.sqlite_master WHERE type = 'trigger' AND tbl_name = ?1 COLLATE NOCASE", -1, &statement, null) != sqlite.SQLITE_OK) {
        reportEngine(stderr, "read the schema", null, conn);
        return null;
    }
    const prepared = statement orelse {
        reportEngine(stderr, "read the schema", null, conn);
        return null;
    };
    defer _ = sqlite.sqlite3_finalize(prepared);
    if (sqlite.sqlite3_bind_text(prepared, 1, table.ptr, @intCast(table.len), sqlite.SQLITE_STATIC) != sqlite.SQLITE_OK) {
        reportEngine(stderr, "read the schema", null, conn);
        return null;
    }
    return switch (sqlite.sqlite3_step(prepared)) {
        sqlite.SQLITE_ROW => sqlite.sqlite3_column_int64(prepared, 0) != 0,
        else => {
            reportEngine(stderr, "read the schema", null, conn);
            return null;
        },
    };
}

fn seedTable(
    arena: std.mem.Allocator,
    spec: Spec,
    table: Table,
    random: std.Random,
    conn: *sqlite.sqlite3,
    stderr: *Io.Writer,
) ?cli_control.ExitCode {
    const delete_sql = buildDelete(arena, table.name) catch {
        stderr.writeAll("error: out of memory\n") catch {};
        return .rejected;
    };
    if (sqlite.sqlite3_exec(conn, delete_sql.ptr, null, null, null) != sqlite.SQLITE_OK) {
        reportEngine(stderr, "clear table", table.name, conn);
        return .rejected;
    }
    if (table.rows == 0) return verifyCount(arena, table, conn, stderr);

    const insert_sql = buildInsert(arena, table) catch {
        stderr.writeAll("error: out of memory\n") catch {};
        return .rejected;
    };
    var statement: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(conn, insert_sql.ptr, -1, &statement, null) != sqlite.SQLITE_OK) {
        reportEngine(stderr, "insert into table", table.name, conn);
        return .rejected;
    }
    const prepared = statement orelse {
        reportEngine(stderr, "insert into table", table.name, conn);
        return .rejected;
    };
    defer _ = sqlite.sqlite3_finalize(prepared);

    var row: u64 = 0;
    while (row < table.rows) : (row += 1) {
        if ((row & 0xfff) == 0 and cli_control.signalPending()) return cli_control.reportInterrupted(stderr);
        for (table.columns, 0..) |column, index| {
            const value = draw(random, column.distribution, row) catch {
                invalid(stderr, spec.path, "table '{s}' column '{s}' sequence value overflows a 64-bit integer", .{ table.name, column.name });
                return .rejected;
            };
            if (!bind(prepared, @intCast(index + 1), value)) {
                reportEngine(stderr, "bind a value for table", table.name, conn);
                return .rejected;
            }
        }
        const rc = sqlite.sqlite3_step(prepared);
        if (rc != sqlite.SQLITE_DONE) {
            reportEngine(stderr, "insert into table", table.name, conn);
            return .rejected;
        }
        const reset_rc = sqlite.sqlite3_reset(prepared);
        if (reset_rc != sqlite.SQLITE_OK and reset_rc != sqlite.SQLITE_DONE) {
            reportEngine(stderr, "insert into table", table.name, conn);
            return .rejected;
        }
    }
    return verifyCount(arena, table, conn, stderr);
}

fn verifyCount(arena: std.mem.Allocator, table: Table, conn: *sqlite.sqlite3, stderr: *Io.Writer) ?cli_control.ExitCode {
    const quoted = quoteName(arena, table.name) catch {
        stderr.writeAll("error: out of memory\n") catch {};
        return .rejected;
    };
    const sql = std.fmt.allocPrintSentinel(arena, "SELECT count(*) FROM {s}", .{quoted}, 0) catch {
        stderr.writeAll("error: out of memory\n") catch {};
        return .rejected;
    };
    var statement: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(conn, sql.ptr, -1, &statement, null) != sqlite.SQLITE_OK) {
        reportEngine(stderr, "count table", table.name, conn);
        return .rejected;
    }
    const prepared = statement orelse {
        reportEngine(stderr, "count table", table.name, conn);
        return .rejected;
    };
    defer _ = sqlite.sqlite3_finalize(prepared);
    if (sqlite.sqlite3_step(prepared) != sqlite.SQLITE_ROW) {
        reportEngine(stderr, "count table", table.name, conn);
        return .rejected;
    }
    const actual = sqlite.sqlite3_column_int64(prepared, 0);
    if (actual != @as(i64, @intCast(table.rows))) {
        stderr.print("error: the seed data could not insert exactly {d} rows into table '{s}': the table holds {d} rows after the insert\n", .{ table.rows, table.name, actual }) catch {};
        return .rejected;
    }
    return null;
}

fn buildDelete(allocator: std.mem.Allocator, table: []const u8) ![:0]const u8 {
    const quoted = try quoteName(allocator, table);
    return std.fmt.allocPrintSentinel(allocator, "DELETE FROM {s}", .{quoted}, 0);
}

fn buildInsert(allocator: std.mem.Allocator, table: Table) ![:0]const u8 {
    var sql: std.ArrayList(u8) = .empty;
    try sql.appendSlice(allocator, "INSERT OR ABORT INTO ");
    try sql.appendSlice(allocator, try quoteName(allocator, table.name));
    if (table.columns.len == 0) {
        try sql.appendSlice(allocator, " DEFAULT VALUES");
        return sql.toOwnedSliceSentinel(allocator, 0);
    }
    try sql.appendSlice(allocator, " (");
    for (table.columns, 0..) |column, index| {
        if (index != 0) try sql.appendSlice(allocator, ", ");
        try sql.appendSlice(allocator, try quoteName(allocator, column.name));
    }
    try sql.appendSlice(allocator, ") VALUES (");
    for (table.columns, 0..) |_, index| {
        if (index != 0) try sql.appendSlice(allocator, ", ");
        var buffer: [16]u8 = undefined;
        const number = std.fmt.bufPrint(&buffer, "?{d}", .{index + 1}) catch unreachable;
        try sql.appendSlice(allocator, number);
    }
    try sql.appendSlice(allocator, ")");
    return sql.toOwnedSliceSentinel(allocator, 0);
}

fn quoteName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var quoted: std.ArrayList(u8) = .empty;
    try quoted.append(allocator, '"');
    for (name) |byte| {
        if (byte == '"') try quoted.append(allocator, '"');
        try quoted.append(allocator, byte);
    }
    try quoted.append(allocator, '"');
    return quoted.items;
}

fn draw(random: std.Random, distribution: Distribution, row: u64) error{SequenceOverflow}!Value {
    return switch (distribution) {
        .fixed => |value| value,
        .uniform => |values| values[random.uintLessThan(usize, values.len)],
        .ratio => |ratio| if (random.float(f64) < ratio.ratio) ratio.value else ratio.otherwise,
        .sequence => |sequence| blk: {
            const index: i128 = @intCast(row);
            const step: i128 = sequence.step;
            const from: i128 = sequence.from;
            const value = from + step * index;
            if (value < std.math.minInt(i64) or value > std.math.maxInt(i64)) return error.SequenceOverflow;
            break :blk .{ .integer = @intCast(value) };
        },
    };
}

fn bind(statement: *sqlite.sqlite3_stmt, index: c_int, value: Value) bool {
    const rc = switch (value) {
        .null => sqlite.sqlite3_bind_null(statement, index),
        .boolean => |flag| sqlite.sqlite3_bind_int64(statement, index, @as(i64, @intFromBool(flag))),
        .integer => |number| sqlite.sqlite3_bind_int64(statement, index, number),
        .real => |number| sqlite.sqlite3_bind_double(statement, index, number),
        .text => |text| sqlite.sqlite3_bind_text(statement, index, text.ptr, @intCast(text.len), sqlite.SQLITE_STATIC),
    };
    return rc == sqlite.SQLITE_OK;
}

fn reportEngine(stderr: *Io.Writer, action: []const u8, table: ?[]const u8, conn: *sqlite.sqlite3) void {
    const message = std.mem.span(sqlite.sqlite3_errmsg(conn));
    if (table) |name| {
        stderr.print("error: the seed data could not {s} '{s}': {s}\n", .{ action, name, message }) catch {};
    } else {
        stderr.print("error: the seed data could not {s}: {s}\n", .{ action, message }) catch {};
    }
}

const testing = std.testing;

fn loadText(arena: std.mem.Allocator, text: []const u8, stderr: *Io.Writer) ?Spec {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(testing.io, .{ .sub_path = "seed.json", .data = text }) catch return null;
    const path = tmp.dir.realPathFileAlloc(testing.io, "seed.json", arena) catch return null;
    return load(testing.io, arena, path, stderr);
}

test "a spec with every distribution loads" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stderr_buffer: [512]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);

    const spec = loadText(arena,
        \\{
        \\  "seed": 7,
        \\  "tables": {
        \\    "events": {
        \\      "rows": 3,
        \\      "columns": {
        \\        "id": {"kind": "sequence"},
        \\        "status": {"kind": "uniform", "values": ["ok", "warn"]},
        \\        "flag": {"kind": "ratio", "value": true, "ratio": 0.25, "otherwise": false},
        \\        "note": {"kind": "fixed", "value": null}
        \\      }
        \\    }
        \\  }
        \\}
    , &stderr) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("", stderr.buffered());
    try testing.expectEqual(@as(u64, 7), spec.seed);
    try testing.expectEqual(@as(usize, 1), spec.tables.len);
    try testing.expectEqualStrings("events", spec.tables[0].name);
    try testing.expectEqual(@as(u64, 3), spec.tables[0].rows);
    try testing.expectEqual(@as(usize, 4), spec.tables[0].columns.len);

    switch (spec.tables[0].columns[0].distribution) {
        .sequence => |sequence| {
            try testing.expectEqual(@as(i64, 1), sequence.from);
            try testing.expectEqual(@as(i64, 1), sequence.step);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (spec.tables[0].columns[1].distribution) {
        .uniform => |values| {
            try testing.expectEqual(@as(usize, 2), values.len);
            try testing.expectEqualStrings("ok", values[0].text);
            try testing.expectEqualStrings("warn", values[1].text);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (spec.tables[0].columns[2].distribution) {
        .ratio => |ratio| {
            try testing.expect(ratio.value.boolean);
            try testing.expect(!ratio.otherwise.boolean);
            try testing.expectEqual(@as(f64, 0.25), ratio.ratio);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (spec.tables[0].columns[3].distribution) {
        .fixed => |value| try testing.expect(value == .null),
        else => return error.TestUnexpectedResult,
    }
}

test "the seed defaults to 0 and columns may be omitted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stderr_buffer: [512]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);

    const spec = loadText(arena, "{\"tables\": {\"t\": {\"rows\": 0}}}", &stderr) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("", stderr.buffered());
    try testing.expectEqual(@as(u64, 0), spec.seed);
    try testing.expectEqual(@as(usize, 1), spec.tables.len);
    try testing.expectEqual(@as(u64, 0), spec.tables[0].rows);
    try testing.expectEqual(@as(usize, 0), spec.tables[0].columns.len);
}

test "a spec names the first problem it finds" {
    const cases = [_]struct { text: []const u8, message: []const u8 }{
        .{ .text = "[]", .message = "it must be a JSON object" },
        .{ .text = "{", .message = "it is not valid JSON" },
        .{ .text = "{}", .message = "it must have the key tables" },
        .{ .text = "{\"seed\": -1, \"tables\": {\"t\": {\"rows\": 1}}}", .message = "seed must be a non-negative integer" },
        .{ .text = "{\"seed\": \"7\", \"tables\": {\"t\": {\"rows\": 1}}}", .message = "seed must be a non-negative integer" },
        .{ .text = "{\"tables\": {}}", .message = "tables must hold 1 to 100 entries" },
        .{ .text = "{\"tables\": {\"t\": {\"rows\": -1}}}", .message = "rows must be a non-negative integer" },
        .{ .text = "{\"tables\": {\"t\": {\"rows\": 10000001}}}", .message = "rows must be at most 10000000" },
        .{ .text = "{\"tables\": {\"t\": {\"rows\": 1, \"columns\": {\"c\": {\"kind\": \"nope\"}}}}}", .message = "kind must be fixed, uniform, ratio, or sequence" },
        .{ .text = "{\"tables\": {\"t\": {\"rows\": 1, \"columns\": {\"c\": {\"kind\": \"uniform\", \"values\": []}}}}}", .message = "values must hold at least one value" },
        .{ .text = "{\"tables\": {\"t\": {\"rows\": 1, \"columns\": {\"c\": {\"kind\": \"ratio\", \"value\": 1, \"ratio\": 1.5}}}}}", .message = "ratio must be a number from 0 to 1" },
        .{ .text = "{\"tables\": {\"t\": {\"rows\": 1, \"columns\": {\"c\": {\"kind\": \"fixed\", \"value\": [1]}}}}}", .message = "value must be a string, number, boolean, or null" },
        .{ .text = "{\"tables\": {\"t\": {\"rows\": 1, \"columns\": {\"c\": {\"kind\": \"fixed\", \"value\": 1, \"extra\": 2}}}}}", .message = "has an unknown key 'extra'" },
        .{ .text = "{\"tables\": {\"sqlite_sequence\": {\"rows\": 1}}}", .message = "is internal to SQLite" },
        .{ .text = "{\"tables\": {\"t\": {\"rows\": 1, \"unknown\": 2}}}", .message = "has an unknown key 'unknown'" },
        .{ .text = "{\"tables\": {\"a\": {\"rows\": 10000000}, \"b\": {\"rows\": 10000000}, \"c\": {\"rows\": 10000000}}}", .message = "the total rows must be at most 20000000" },
        .{ .text = "{\"tables\": {\"t\": {\"rows\": 1}, \"T\": {\"rows\": 2}}}", .message = "differ only by case" },
        .{ .text = "{\"tables\": {\"t\": {\"rows\": 1, \"columns\": {\"a\": {\"kind\": \"fixed\", \"value\": 1}, \"A\": {\"kind\": \"fixed\", \"value\": 2}}}}}", .message = "differ only by case" },
    };
    for (cases) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var stderr_buffer: [1024]u8 = undefined;
        var stderr = Io.Writer.fixed(&stderr_buffer);
        try testing.expect(loadText(arena, case.text, &stderr) == null);
        try testing.expect(std.mem.indexOf(u8, stderr.buffered(), case.message) != null);
        try testing.expect(std.mem.startsWith(u8, stderr.buffered(), "error: the seed data spec "));
    }
}

test "an unreadable or unsafe spec file is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stderr_buffer: [1024]u8 = undefined;

    var stderr = Io.Writer.fixed(&stderr_buffer);
    try testing.expect(load(testing.io, arena, "no-such-seed.json", &stderr) == null);
    try testing.expect(std.mem.startsWith(u8, stderr.buffered(), "error: cannot read the seed data spec 'no-such-seed.json': no such file"));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "nul.json", .data = "{\"tables\": {}}\x00" });
    const nul_path = try tmp.dir.realPathFileAlloc(testing.io, "nul.json", arena);
    stderr = Io.Writer.fixed(&stderr_buffer);
    try testing.expect(load(testing.io, arena, nul_path, &stderr) == null);
    try testing.expect(std.mem.indexOf(u8, stderr.buffered(), "the file contains a NUL byte") != null);

    var large: [max_spec_bytes + 2]u8 = undefined;
    @memset(&large, ' ');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "large.json", .data = &large });
    const large_path = try tmp.dir.realPathFileAlloc(testing.io, "large.json", arena);
    stderr = Io.Writer.fixed(&stderr_buffer);
    try testing.expect(load(testing.io, arena, large_path, &stderr) == null);
    try testing.expect(std.mem.indexOf(u8, stderr.buffered(), "the file is larger than 1 MiB") != null);

    const directory_path = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    stderr = Io.Writer.fixed(&stderr_buffer);
    try testing.expect(load(testing.io, arena, directory_path, &stderr) == null);
    try testing.expect(std.mem.indexOf(u8, stderr.buffered(), "is a directory") != null);
}
