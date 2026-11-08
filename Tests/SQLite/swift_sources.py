"""Reads the app's real SQLite schema and SQL statements straight from the Swift sources.

* `build_schema()` translates the GRDB schema DSL used by the registered migrations
  (`db.create(table:)`, `db.alter(table:)`, `db.create(index:)`, `db.execute(sql:)`) into
  SQLite DDL, in `AppDatabase.migrator` order. Only the DSL subset the app uses is supported;
  anything unrecognised raises, so schema drift breaks the tests instead of passing silently.
* `swift_sql(file, func_name, index)` returns the n-th `sql: \"\"\"...\"\"\"` literal inside a Swift
  function, so tests execute the exact statements the app ships.

Standard library only. Run from any directory.
"""
from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SRC = REPO / "BTechnica"

# Migration order from AppDatabase.migrator (identifier -> schema function, file).
MIGRATIONS = [
    ("v1_foundation", "createV1Schema", "Persistence/AppDatabase+Schema.swift"),
    ("v2_drawing_page_mappings", "createDrawingPageMappingsTable", "Persistence/AppDatabase+Schema.swift"),
    ("v3_project_contacts", "createProjectContactsSchema", "Persistence/AppDatabase+ContactsSchema.swift"),
    ("v4_equipment_checkouts", "createEquipmentCheckoutsSchema", "Persistence/AppDatabase+FieldOperationsSchema.swift"),
    ("v5_project_photos", "createProjectPhotosSchema", "Persistence/AppDatabase+FieldOperationsSchema.swift"),
    ("v4_construction_schedule", "createConstructionScheduleSchema", "Persistence/AppDatabase+ScheduleSchema.swift"),
    ("v_project_knowledge_v1", "createProjectKnowledgeSchema", "Persistence/AppDatabase+KnowledgeSchema.swift"),
]

TYPES = {"text": "TEXT", "integer": "INTEGER", "double": "DOUBLE", "boolean": "BOOLEAN", "date": "DATE",
         "datetime": "DATETIME", "blob": "BLOB", "numeric": "NUMERIC"}
ACTIONS = {"cascade": "CASCADE", "setNull": "SET NULL", "restrict": "RESTRICT", "setDefault": "SET DEFAULT"}


def read(rel: str) -> str:
    return (SRC / rel).read_text(encoding="utf-8").replace("\r\n", "\n")


def function_body(source: str, func_name: str) -> str:
    m = re.search(r"\bfunc\s+" + re.escape(func_name) + r"\s*\(", source)
    if not m:
        raise LookupError(f"func {func_name} not found")
    start = source.index("{", m.end())
    return _balanced(source, start, "{", "}")[1:-1]


def _balanced(text: str, start: int, open_ch: str, close_ch: str) -> str:
    """Returns text[start:end] for the bracket at `start`, skipping string literals."""
    depth, i = 0, start
    while i < len(text):
        if text.startswith('"""', i):
            i = text.index('"""', i + 3) + 3
            continue
        ch = text[i]
        if ch == '"':
            i += 1
            while text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
        i += 1
    raise ValueError("unbalanced brackets")


def _swift_string_list(text: str) -> list[str]:
    return re.findall(r'"([^"]*)"', text)


def _default_literal(value: str) -> str:
    value = value.strip()
    if value in ("true", "false"):
        return "1" if value == "true" else "0"
    if value.startswith('"'):
        return "'" + value.strip('"').replace("'", "''") + "'"
    return value


def _column_def(name: str, swift_type: str, chain: str) -> str:
    parts = [name, TYPES[swift_type]]
    for call, args in re.findall(r"\.(\w+)\(([^()]*(?:\([^()]*\))?[^()]*)\)", chain):
        if call == "primaryKey":
            parts.append("PRIMARY KEY")
        elif call == "notNull":
            parts.append("NOT NULL")
        elif call == "defaults":
            parts.append("DEFAULT " + _default_literal(args.split(":", 1)[1]))
        elif call == "references":
            target = _swift_string_list(args)[0]
            ref = f"REFERENCES {target}"
            act = re.search(r"onDelete:\s*\.(\w+)", args)
            if act:
                ref += " ON DELETE " + ACTIONS[act.group(1)]
            parts.append(ref)
        elif call == "unique":
            parts.append("UNIQUE")
        else:
            raise NotImplementedError(f"column modifier .{call}()")
    return " ".join(parts)


def _statements(block: str) -> list[str]:
    """Splits a Swift block into statements: a line plus its `.chained` / open-paren continuation."""
    stmts: list[str] = []
    buf = ""
    for raw in block.split("\n"):
        line = raw.strip()
        if not line or line.startswith("//"):
            continue
        if buf and (line.startswith(".") or buf.count("(") > buf.count(")") or buf.count("[") > buf.count("]")):
            buf += " " + line
        else:
            if buf:
                stmts.append(buf)
            buf = line
    if buf:
        stmts.append(buf)
    return stmts


def _table_ddl(name: str, block: str) -> str:
    cols, constraints = [], []
    for st in _statements(block):
        m = re.match(r't\.column\("(\w+)",\s*\.(\w+)\)(.*)$', st)
        if m:
            cols.append(_column_def(m.group(1), m.group(2), m.group(3)))
            continue
        m = re.match(r"t\.uniqueKey\(\[(.*)\]\)$", st)
        if m:
            constraints.append("UNIQUE (" + ", ".join(_swift_string_list(m.group(1))) + ")")
            continue
        m = re.match(r't\.check\(sql:\s*"(.*)"\)$', st)
        if m:
            constraints.append("CHECK (" + m.group(1).replace('\\"', '"') + ")")
            continue
        m = re.match(r"t\.foreignKey\(\s*\[(.*?)\],\s*references:\s*\"(\w+)\",\s*columns:\s*\[(.*?)\],\s*onDelete:\s*\.(\w+)\s*\)$", st)
        if m:
            constraints.append(
                f"FOREIGN KEY ({', '.join(_swift_string_list(m.group(1)))}) REFERENCES {m.group(2)} "
                f"({', '.join(_swift_string_list(m.group(3)))}) ON DELETE {ACTIONS[m.group(4)]}")
            continue
        raise NotImplementedError(f"table {name}: {st}")
    return f"CREATE TABLE {name} (\n  " + ",\n  ".join(cols + constraints) + "\n);"


def _alter_ddl(name: str, block: str) -> list[str]:
    out = []
    for st in _statements(block):
        m = re.match(r't\.add\(column:\s*"(\w+)",\s*\.(\w+)\)(.*)$', st)
        if not m:
            raise NotImplementedError(f"alter {name}: {st}")
        out.append(f"ALTER TABLE {name} ADD COLUMN {_column_def(m.group(1), m.group(2), m.group(3))};")
    return out


def _index_ddl(args: str) -> str:
    name = re.search(r'index:\s*"(\w+)"', args).group(1)
    table = re.search(r'on:\s*"(\w+)"', args).group(1)
    columns = _swift_string_list(re.search(r"columns:\s*\[(.*?)\]", args).group(1))
    unique = "UNIQUE " if re.search(r"options:\s*\.unique", args) else ""
    where = ""
    cond = re.search(r'condition:\s*Column\("(\w+)"\)\s*(==|!=)\s*nil', args)
    if cond:
        where = f" WHERE {cond.group(1)} IS {'NOT ' if cond.group(2) == '!=' else ''}NULL"
    elif "condition:" in args:
        raise NotImplementedError(f"index condition: {args}")
    return f"CREATE {unique}INDEX {name} ON {table} ({', '.join(columns)}){where};"


def schema_for(func_name: str, rel: str) -> list[str]:
    body = function_body(read(rel), func_name)
    ddl: list[str] = []
    i = 0
    pattern = re.compile(r'try\s+(?:db|Self)?\.?(create\(\s*table:|alter\(\s*table:|create\(\s*index:|execute\(\s*sql:|normalizeEquipmentState\()')
    expected = len(re.findall(r'\bdb\.(?:create|alter|execute)\(', body))
    consumed = 0
    while True:
        m = pattern.search(body, i)
        if not m:
            break
        kind = re.sub(r"\s+", "", m.group(1))
        if not kind.startswith("normalizeEquipmentState"):
            consumed += 1
        if kind.startswith("normalizeEquipmentState"):
            i = m.end()  # data normalisation, no DDL
            continue
        paren = body.index("(", m.start() + len("try db."))
        args = _balanced(body, paren, "(", ")")
        end = paren + len(args)
        if kind in ("create(table:", "alter(table:"):
            table = re.match(r'\(\s*table:\s*"(\w+)"\s*\)', args).group(1)
            brace = body.index("{", end)
            block = _balanced(body, brace, "{", "}")
            inner = block[1:-1].split("in", 1)[1]  # drop "t in"
            ddl.extend([_table_ddl(table, inner)] if kind.startswith("create") else _alter_ddl(table, inner))
            end = brace + len(block)
        elif kind == "create(index:":
            ddl.append(_index_ddl(args))
        else:
            sql = re.search(r'"""\n(.*?)"""', args, re.S)
            if sql:
                ddl.append(sql.group(1))
            else:
                ddl.append(re.search(r'sql:\s*"(.*)"', args).group(1))
        i = end
    if not ddl:
        raise LookupError(f"no DDL found in {func_name}")
    if consumed != expected:
        raise NotImplementedError(f"{func_name}: parsed {consumed} of {expected} db.create/alter/execute calls")
    return ddl


def build_schema(conn, through: str | None = None) -> list[str]:
    """Applies every registered migration (optionally up to and including `through`)."""
    applied = []
    for identifier, func_name, rel in MIGRATIONS:
        for statement in schema_for(func_name, rel):
            conn.executescript(statement)
        applied.append(identifier)
        if identifier == through:
            break
    return applied


def registered_migrations() -> list[str]:
    return re.findall(r'registerMigration\("([^"]+)"\)', read("Persistence/AppDatabase.swift"))


def swift_sql(rel: str, func_name: str, index: int = 0) -> str:
    """The `index`-th triple-quoted `sql:` literal inside `func_name` (Swift indentation removed)."""
    body = function_body(read(rel), func_name)
    blocks = re.findall(r'sql:\s*"""\n(.*?)\n\s*"""', body, re.S)
    if index >= len(blocks):
        raise LookupError(f"{func_name}: only {len(blocks)} sql blocks")
    lines = blocks[index].split("\n")
    indent = min(len(l) - len(l.lstrip()) for l in lines if l.strip())
    return "\n".join(l[indent:] for l in lines)


def swift_inline_sql(rel: str, func_name: str, contains: str) -> str:
    """A single-line `sql: "..."` literal inside `func_name` that contains `contains`."""
    body = function_body(read(rel), func_name)
    for literal in re.findall(r'sql:\s*"((?:[^"\\]|\\.)*)"', body):
        if contains in literal:
            return literal
    raise LookupError(f"{func_name}: no inline sql containing {contains!r}")
