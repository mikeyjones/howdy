//// Hearing about changes on PostgreSQL through `NOTIFY`, instead of asking.
////
//// Each table the admin shows gets a statement-level trigger,
//// `howdy_admin_notify`, that sends the table's name on the `howdy_admin`
//// channel after any insert, update, delete or truncate. A grid listens on
//// a connection of its own, opened from the same pool settings as the
//// app's, and reloads when its table is named. `howdy/migration` ignores
//// triggers with this prefix when it checks a package's schema.
////
//// SQLite has no such mechanism, and neither does `sqlight` expose its
//// update hook, so there the grid keeps polling.

import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/option.{type Option, None, Some}
import gleam/result
import gloo/repo.{type Repo}
import gloo/sql
import gloo/value.{type GlooValue}
import howdy/admin/internal/schema
import howdy/database.{Postgres, Sqlite}
import howdy/service
import logging
import pog

/// The channel every notification arrives on. The payload is the table.
pub const channel = "howdy_admin"

/// The trigger and function name.
pub const trigger = "howdy_admin_notify"

@external(erlang, "howdy_admin_ffi", "postgres_pool")
fn postgres_pool(repo: Repo) -> Result(Atom, Nil)

@external(erlang, "howdy_admin_ffi", "listen")
fn listen(
  pool: Atom,
  channel: String,
  owner: Pid,
  notify: fn(String) -> Nil,
) -> Result(Nil, Nil)

@external(erlang, "howdy_admin_ffi", "listen_via")
fn listen_via(
  host: String,
  port: Int,
  database: String,
  user: String,
  password: Option(String),
  ssl: pog.Ssl,
  parameters: List(#(String, String)),
  ip_version: pog.IpVersion,
  channel: String,
  owner: Pid,
  notify: fn(String) -> Nil,
) -> Result(Nil, Nil)

/// Whether this Repo is on PostgreSQL and the admin has a way to listen:
/// settings the app gave, or a pgo pool it can look inside.
pub fn available(repo: Repo, settings: Option(pog.Config)) -> Bool {
  case database.backend(repo) {
    Ok(Postgres) ->
      option.is_some(settings) || result.is_ok(postgres_pool(repo))
    _ -> False
  }
}

/// Make sure the trigger is on `table`. Creating the function again is
/// harmless; the trigger is only created when missing, so a second grid on
/// the same table changes nothing.
pub fn install(repo: Repo, table: schema.Table) -> service.Result(Nil) {
  use conn <- database.connect(repo)
  use backend <- result.try(database.backend(conn))
  case backend {
    Sqlite -> Error(service.Invalid("SQLite has no NOTIFY"))
    Postgres -> {
      use _ <- result.try(
        execute(
          conn,
          "CREATE OR REPLACE FUNCTION "
            <> trigger
            <> "() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_notify('"
            <> channel
            <> "', TG_TABLE_NAME); RETURN NULL; END $$",
          [],
        ),
      )
      use present <- result.try(
        repo.all(
          conn,
          "SELECT 1 FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE t.tgname = $1 AND c.relname = $2 AND n.nspname = current_schema()",
          [sql.string(trigger), sql.string(table.name)],
          decode.field(0, decode.int, decode.success),
        )
        |> result.map_error(failed),
      )
      case present {
        [_, ..] -> Ok(Nil)
        [] ->
          execute(
            conn,
            "CREATE TRIGGER "
              <> trigger
              <> " AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON "
              <> schema.quote(table.name)
              <> " FOR EACH STATEMENT EXECUTE FUNCTION "
              <> trigger
              <> "()",
            [],
          )
      }
    }
  }
}

/// Remove the function and, with it, every trigger the admin installed.
pub fn uninstall(repo: Repo) -> service.Result(Nil) {
  use conn <- database.connect(repo)
  use backend <- result.try(database.backend(conn))
  case backend {
    Sqlite -> Ok(Nil)
    Postgres ->
      execute(conn, "DROP FUNCTION IF EXISTS " <> trigger <> "() CASCADE", [])
  }
}

/// Call `notify` with each table name announced on the channel, from a
/// process linked to `owner`, until `owner` exits. Connects with the
/// settings the app gave, or else with those found inside the pool. An
/// `Error` means no notifications will come, and says why in the log.
pub fn subscribe(
  repo: Repo,
  settings: Option(pog.Config),
  owner: Pid,
  notify: fn(String) -> Nil,
) -> Result(Nil, Nil) {
  let outcome = case settings {
    Some(config) ->
      listen_via(
        config.host,
        config.port,
        config.database,
        config.user,
        config.password,
        config.ssl,
        config.connection_parameters,
        config.ip_version,
        channel,
        owner,
        notify,
      )
    None -> {
      use pool <- result.try(postgres_pool(repo))
      listen(pool, channel, owner, notify)
    }
  }
  case outcome {
    Ok(Nil) -> Ok(Nil)
    Error(Nil) -> {
      logging.log(
        logging.Warning,
        "howdy/admin: could not listen for changes on PostgreSQL"
          <> case settings {
          Some(_) -> " with the settings given to notify_via"
          None ->
            " because the pool's settings could not be found; pass them with howdy/admin.notify_via"
        }
          <> "; the grid polls instead",
      )
      Error(Nil)
    }
  }
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

fn failed(reason) -> service.Error {
  service.Invalid(gloo_error_to_string(reason))
}

@external(erlang, "gloo@error", "to_string")
fn gloo_error_to_string(reason: a) -> String
