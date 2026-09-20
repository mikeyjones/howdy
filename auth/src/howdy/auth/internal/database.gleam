//// Gloo is the storage seam. The application owns the Repo lifecycle.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import gloo/error
import gloo/repo.{type Repo}
import gloo/value.{type GlooValue}
import howdy/auth/internal/cache
import howdy/service

/// Gloo's SQLite Repo has one connection. Serialize Howdy operations so a
/// concurrent auth request cannot join another request's transaction. Waiters
/// are served in arrival order. Give auth a dedicated SQLite Repo if other
/// application code also uses Gloo.
@external(erlang, "howdy_auth_ffi", "with_repo_lock")
fn with_repo_lock(repo: Repo, run: fn() -> a) -> a

pub type Backend {
  Postgres
  Sqlite
}

/// The one place an adapter name is interpreted. Anything else is refused
/// rather than treated as one of the supported databases.
pub fn backend(repo: Repo) -> service.Result(Backend) {
  case repo.adapter_name(repo) {
    "postgres" -> Ok(Postgres)
    "sqlite" -> Ok(Sqlite)
    _ -> Error(service.Internal("unsupported Gloo database adapter"))
  }
}

pub fn connect(
  repo: Repo,
  run: fn(Repo) -> service.Result(a),
) -> service.Result(a) {
  use backend <- result.try(backend(repo))
  case backend {
    Sqlite -> with_repo_lock(repo, fn() { run(repo) })
    Postgres -> run(repo)
  }
}

pub fn transaction(
  repo: Repo,
  run: fn(Repo) -> service.Result(a),
) -> service.Result(a) {
  use <- cache.transaction
  use repo <- connect(repo)
  // Gloo 1.x stringifies callback errors during rollback. Keep the original
  // typed domain error in this call's private mailbox rather than parsing it.
  let failures = process.new_subject()
  let answer =
    repo.transaction(repo, fn(tx) {
      case run(tx) {
        Ok(value) -> Ok(value)
        Error(failure) -> {
          process.send(failures, failure)
          Error(error.RollbackError)
        }
      }
    })
  case answer {
    Ok(value) -> Ok(value)
    Error(_) ->
      case process.receive(failures, 0) {
        Ok(failure) -> Error(failure)
        Error(Nil) ->
          Error(service.Internal("auth database transaction failed"))
      }
  }
}

/// A transaction that reads before it writes. SQLite's deferred BEGIN takes
/// the write lock only at the first write, and independent connections must
/// not race that read-to-write upgrade, so take it up front.
pub fn write_transaction(
  repo: Repo,
  touching table: String,
  run run: fn(Repo) -> service.Result(a),
) -> service.Result(a) {
  use conn <- transaction(repo)
  use _ <- result.try(promote(conn, table))
  run(conn)
}

/// Acquire SQLite's write lock inside an open transaction using a statement
/// that changes nothing. `table` is trusted, module-owned text.
pub fn promote(conn: Repo, table: String) -> service.Result(Nil) {
  use backend <- result.try(backend(conn))
  case backend {
    Postgres -> Ok(Nil)
    Sqlite -> execute(conn, "DELETE FROM " <> table <> " WHERE 1 = 0", [])
  }
}

/// DDL batches follow Gloo runner's statement convention: semicolon-separated
/// statements, with no embedded semicolons in literals or procedural bodies.
pub fn exec(repo: Repo, statements: String) -> service.Result(Nil) {
  statements
  |> string.split(";")
  |> list.map(string.trim)
  |> list.filter(fn(sql) { sql != "" })
  |> list.try_fold(Nil, fn(_, sql) { execute(repo, sql, []) })
}

pub fn query(
  repo: Repo,
  sql: String,
  args: List(GlooValue),
  decoder: decode.Decoder(a),
) -> service.Result(List(a)) {
  repo.all(repo, sql, args, decoder) |> result.map_error(error)
}

pub fn execute(
  repo: Repo,
  sql: String,
  args: List(GlooValue),
) -> service.Result(Nil) {
  repo.execute(repo, sql, args)
  |> result.map(fn(_) { Nil })
  |> result.map_error(error)
}

pub fn error(_error: error.GlooError) -> service.Error {
  // Driver errors may contain personal data. Do not log or return them.
  service.Internal("auth database operation failed")
}

/// Row-lock suffix for a SELECT inside a transaction. SQLite transactions
/// already hold the database write lock. `alias` is trusted query text.
pub fn for_update(repo: Repo, alias: String) -> String {
  case backend(repo) {
    Ok(Postgres) -> " FOR UPDATE OF " <> alias
    _ -> ""
  }
}

/// SQL reading an instant column as unix seconds. PostgreSQL keeps instants
/// as TIMESTAMPTZ; SQLite has no such type and keeps the seconds themselves.
/// `column` is trusted query text.
pub fn read_time(repo: Repo, column: String) -> String {
  case backend(repo) {
    Ok(Postgres) -> "EXTRACT(EPOCH FROM " <> column <> ")::bigint"
    _ -> column
  }
}

/// SQL writing the unix seconds bound to `placeholder`, such as `$2`, to an
/// instant column.
pub fn write_time(repo: Repo, placeholder: String) -> String {
  case backend(repo) {
    Ok(Postgres) -> "to_timestamp(" <> placeholder <> "::bigint)"
    _ -> placeholder
  }
}

/// Serialize migration processes before they inspect or change the ledger.
pub fn lock_migrations(repo: Repo) -> service.Result(Nil) {
  use backend <- result.try(backend(repo))
  case backend {
    Postgres ->
      execute(
        repo,
        "SELECT pg_advisory_xact_lock(1752131449, 1835624306)::text",
        [],
      )
    Sqlite -> Ok(Nil)
  }
}
