//// Tables, columns and rows of whatever database the application opened,
//// on PostgreSQL and SQLite. Every value crosses as text: the admin shows
//// and edits any column without knowing its type, and the database casts
//// what it is given. Driver errors are shown, not hidden: this runs in
//// development, for the developer.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import gloo/error
import gloo/repo.{type Repo}
import gloo/sql
import gloo/value.{type GlooValue}
import howdy/database.{type Backend, Postgres, Sqlite}
import howdy/service

pub type Column {
  Column(name: String, kind: String, nullable: Bool, key: Bool)
}

/// How a row is identified: by its primary key, or, without one, by the
/// database's own row address.
pub type Key {
  Columns(List(Column))
  RowId
  Ctid
}

pub type Table {
  Table(name: String, backend: Backend, columns: List(Column), key: Key)
}

/// `key` has one value per key column, or one row address.
pub type Row {
  Row(key: List(String), cells: List(Option(String)))
}

@external(erlang, "howdy_admin_ffi", "cells")
fn cells(row: Dynamic) -> List(Option(String))

/// Every table in the application's schema, by name.
pub fn tables(repo: Repo) -> service.Result(List(String)) {
  use conn <- database.connect(repo)
  use backend <- result.try(database.backend(conn))
  let statement = case backend {
    Postgres ->
      "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p') AND n.nspname = current_schema() ORDER BY c.relname"
    Sqlite ->
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
  }
  all(conn, statement, [], decode.field(0, decode.string, decode.success))
}

/// The table, or `NotFound` when the schema has no table of that name.
/// `name` may come from a request: it is matched against the schema, never
/// interpolated.
pub fn table(repo: Repo, name: String) -> service.Result(Table) {
  use names <- result.try(tables(repo))
  use _ <- result.try(case list.contains(names, name) {
    True -> Ok(Nil)
    False -> Error(service.NotFound("table"))
  })
  use conn <- database.connect(repo)
  use backend <- result.try(database.backend(conn))
  use columns <- result.try(case backend {
    Postgres ->
      all(
        conn,
        "SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull, EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = a.attrelid AND i.indisprimary AND a.attnum = ANY (i.indkey)) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = current_schema() AND c.relname = $1 AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum",
        [sql.string(name)],
        {
          use name <- decode.field(0, decode.string)
          use kind <- decode.field(1, decode.string)
          use required <- decode.field(2, decode.bool)
          use key <- decode.field(3, decode.bool)
          decode.success(Column(name:, kind:, nullable: !required, key:))
        },
      )
    Sqlite ->
      all(
        conn,
        "SELECT name, type, \"notnull\", pk FROM pragma_table_info($1) ORDER BY cid",
        [sql.string(name)],
        {
          use name <- decode.field(0, decode.string)
          use kind <- decode.field(1, decode.string)
          use required <- decode.field(2, decode.int)
          use key <- decode.field(3, decode.int)
          decode.success(Column(
            name:,
            kind:,
            nullable: required == 0,
            key: key > 0,
          ))
        },
      )
  })
  let key = case list.filter(columns, fn(column) { column.key }), backend {
    [], Sqlite -> RowId
    [], Postgres -> Ctid
    keys, _ -> Columns(keys)
  }
  Ok(Table(name:, backend:, columns:, key:))
}

/// The names of what identifies a row, for headings.
pub fn key_names(table: Table) -> List(String) {
  case table.key {
    Columns(columns) -> list.map(columns, fn(column) { column.name })
    RowId -> ["rowid"]
    Ctid -> ["ctid"]
  }
}

pub fn count(repo: Repo, table: Table) -> service.Result(Int) {
  use conn <- database.connect(repo)
  use counts <- result.try(all(
    conn,
    "SELECT COUNT(*) FROM " <> quote(table.name),
    [],
    decode.field(0, decode.int, decode.success),
  ))
  case counts {
    [count, ..] -> Ok(count)
    [] -> Ok(0)
  }
}

/// A page of rows in key order.
pub fn rows(
  repo: Repo,
  table: Table,
  limit limit: Int,
  offset offset: Int,
) -> service.Result(List(Row)) {
  use conn <- database.connect(repo)
  all(
    conn,
    select(table)
      <> " ORDER BY "
      <> string.join(order(table), ", ")
      <> " LIMIT $1 OFFSET $2",
    [sql.int(limit), sql.int(offset)],
    row_decoder(table),
  )
}

/// One row by key, or `NotFound`.
pub fn row(repo: Repo, table: Table, key: List(String)) -> service.Result(Row) {
  use conn <- database.connect(repo)
  use #(condition, parameters) <- result.try(condition(table, key, from: 1))
  use rows <- result.try(all(
    conn,
    select(table) <> " WHERE " <> condition,
    parameters,
    row_decoder(table),
  ))
  case rows {
    [row, ..] -> Ok(row)
    [] -> Error(service.NotFound("row"))
  }
}

/// Insert a row. Columns given `None` are set to NULL; columns not given
/// take their defaults.
pub fn insert(
  repo: Repo,
  table: Table,
  values: List(#(Column, Option(String))),
) -> service.Result(Nil) {
  use conn <- database.connect(repo)
  case values {
    [] ->
      execute(
        conn,
        "INSERT INTO " <> quote(table.name) <> " DEFAULT VALUES",
        [],
      )
    _ -> {
      let names =
        list.map(values, fn(value) { quote({ value.0 }.name) })
        |> string.join(", ")
      let placeholders =
        list.index_map(values, fn(value, index) {
          bind(table, value.0, index + 1)
        })
        |> string.join(", ")
      execute(
        conn,
        "INSERT INTO "
          <> quote(table.name)
          <> " ("
          <> names
          <> ") VALUES ("
          <> placeholders
          <> ")",
        list.map(values, fn(value) { parameter(value.1) }),
      )
    }
  }
}

/// Write the given columns of the row at `key`.
pub fn update(
  repo: Repo,
  table: Table,
  key: List(String),
  values: List(#(Column, Option(String))),
) -> service.Result(Nil) {
  use conn <- database.connect(repo)
  use _ <- result.try(case values {
    [] -> Error(service.Invalid("nothing to update"))
    _ -> Ok(Nil)
  })
  let assignments =
    list.index_map(values, fn(value, index) {
      quote({ value.0 }.name) <> " = " <> bind(table, value.0, index + 1)
    })
    |> string.join(", ")
  use #(condition, parameters) <- result.try(condition(
    table,
    key,
    from: list.length(values) + 1,
  ))
  execute(
    conn,
    "UPDATE "
      <> quote(table.name)
      <> " SET "
      <> assignments
      <> " WHERE "
      <> condition,
    list.append(list.map(values, fn(value) { parameter(value.1) }), parameters),
  )
}

pub fn delete(
  repo: Repo,
  table: Table,
  key: List(String),
) -> service.Result(Nil) {
  use conn <- database.connect(repo)
  use #(condition, parameters) <- result.try(condition(table, key, from: 1))
  execute(
    conn,
    "DELETE FROM " <> quote(table.name) <> " WHERE " <> condition,
    parameters,
  )
}

// -- SQL ---------------------------------------------------------------------

/// A double-quoted identifier. Names come from the schema itself.
pub fn quote(name: String) -> String {
  "\"" <> string.replace(name, "\"", "\"\"") <> "\""
}

/// The key expressions, then every column.
fn select(table: Table) -> String {
  let key = case table.key {
    Columns(columns) -> list.map(columns, fn(column) { quote(column.name) })
    RowId -> ["rowid"]
    Ctid -> ["ctid::text"]
  }
  let columns = list.map(table.columns, fn(column) { quote(column.name) })
  "SELECT "
  <> string.join(list.append(key, columns), ", ")
  <> " FROM "
  <> quote(table.name)
}

fn order(table: Table) -> List(String) {
  case table.key {
    Columns(columns) -> list.map(columns, fn(column) { quote(column.name) })
    RowId -> ["rowid"]
    Ctid -> ["ctid"]
  }
}

fn row_decoder(table: Table) -> decode.Decoder(Row) {
  let width = case table.key {
    Columns(columns) -> list.length(columns)
    RowId | Ctid -> 1
  }
  use row <- decode.then(decode.dynamic)
  let #(key, cells) = list.split(cells(row), width)
  decode.success(Row(
    key: list.map(key, fn(value) { option.unwrap(value, "") }),
    cells:,
  ))
}

/// A placeholder that the database casts to the column's type. Every value
/// is sent as text. On PostgreSQL the parameter is declared text first, so
/// the driver does not infer the column's type and refuse the string, and
/// is then cast; SQLite converts by column affinity on its own.
fn bind(table: Table, column: Column, index: Int) -> String {
  let placeholder = "$" <> int.to_string(index)
  case table.backend {
    Postgres ->
      "CAST(CAST(" <> placeholder <> " AS text) AS " <> column.kind <> ")"
    Sqlite -> placeholder
  }
}

fn parameter(value: Option(String)) -> GlooValue {
  value.nullable(sql.string, value)
}

/// `WHERE` text and parameters that match `key`, numbering placeholders
/// from `from`.
fn condition(
  table: Table,
  key: List(String),
  from from: Int,
) -> service.Result(#(String, List(GlooValue))) {
  case table.key, key {
    RowId, [id] ->
      case int.parse(id) {
        Ok(id) -> Ok(#("rowid = $" <> int.to_string(from), [sql.int(id)]))
        Error(_) -> Error(service.Invalid("the row id must be a number"))
      }
    Ctid, [address] ->
      Ok(
        #("ctid = CAST(CAST($" <> int.to_string(from) <> " AS text) AS tid)", [
          sql.string(address),
        ]),
      )
    Columns(columns), values ->
      case list.strict_zip(columns, values) {
        Error(_) -> Error(service.Invalid("the key does not match the table"))
        Ok(pairs) -> {
          let conditions =
            list.index_map(pairs, fn(pair, index) {
              quote({ pair.0 }.name)
              <> " = "
              <> bind(table, pair.0, from + index)
            })
          Ok(#(string.join(conditions, " AND "), list.map(values, sql.string)))
        }
      }
    _, _ -> Error(service.Invalid("the key does not match the table"))
  }
}

fn all(
  conn: Repo,
  statement: String,
  parameters: List(GlooValue),
  decoder: decode.Decoder(a),
) -> service.Result(List(a)) {
  repo.all(conn, statement, parameters, decoder)
  |> result.map_error(failed)
}

fn execute(
  conn: Repo,
  statement: String,
  parameters: List(GlooValue),
) -> service.Result(Nil) {
  repo.execute(conn, statement, parameters)
  |> result.map(fn(_) { Nil })
  |> result.map_error(failed)
}

/// The driver's message, for the developer to read. Never do this in an
/// application: it can carry data from the row.
fn failed(reason: error.GlooError) -> service.Error {
  service.Invalid(error.to_string(reason))
}
