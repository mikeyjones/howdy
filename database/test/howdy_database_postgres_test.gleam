import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gloo/migration as gloo_migration
import gloo/repo.{type Repo}
import howdy/database
import howdy/database/postgres
import howdy/migration

@external(erlang, "howdy_database_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "howdy_database_ffi", "monotonic_ms")
fn now() -> Int

fn parsed(url: String) {
  postgres.from_url(url) |> result.map(postgres.inspect)
}

pub fn url_supplies_credentials_port_and_database_test() {
  let assert Ok(#(host, port, database, user, password, ssl, _)) =
    parsed("postgresql://app%40ops:p%3Ass%2Fw@db.example.com:6543/my%20app")
  assert host == "db.example.com"
  assert port == 6543
  assert database == "my app"
  assert user == "app@ops"
  assert password == Some("p:ss/w")
  assert ssl == postgres.SslVerified

  let assert Ok(#(host, port, _, user, password, _, _)) =
    parsed("postgres://[::1]/app")
  assert host == "::1"
  assert port == 5432
  assert user == "postgres"
  assert password == None
}

pub fn tls_defaults_to_verified_except_for_local_hosts_test() {
  let ssl = fn(url) {
    let assert Ok(#(_, _, _, _, _, ssl, _)) = parsed(url)
    ssl
  }
  assert ssl("postgres://u@localhost/app") == postgres.SslDisabled
  assert ssl("postgres://u@127.0.0.1/app") == postgres.SslDisabled
  assert ssl("postgres://u@[::1]/app") == postgres.SslDisabled
  assert ssl("postgres://u@db/app") == postgres.SslDisabled
  assert ssl("postgres://u@10.0.0.5/app") == postgres.SslVerified
  assert ssl("postgres://u@db.internal/app") == postgres.SslVerified
  assert ssl("postgres://u@db.internal/app?sslmode=disable")
    == postgres.SslDisabled
  assert ssl("postgres://u@db/app?sslmode=require") == postgres.SslUnverified
  assert ssl("postgres://u@db/app?sslmode=verify-full") == postgres.SslVerified
}

pub fn malformed_urls_are_refused_without_echoing_them_test() {
  assert postgres.from_url("mysql://u:secret@host/app")
    == Error(postgres.InvalidUrl)
  assert postgres.from_url("postgres://u:secret@host/")
    == Error(postgres.InvalidUrl)
  assert postgres.from_url("postgres://u:secret@host/a/b")
    == Error(postgres.InvalidUrl)
  assert postgres.from_url("postgres://:secret@host/app")
    == Error(postgres.InvalidUrl)
  assert postgres.from_url("postgres://u@host/app?sslmode=prefer")
    == Error(postgres.UnsupportedSslMode("prefer"))
}

pub fn every_connection_starts_with_the_defaults_test() {
  let assert Ok(#(_, _, _, _, _, _, parameters)) =
    postgres.from_url("postgres://u@db/app")
    |> result.map(postgres.parameter(_, "search_path", "app"))
    |> result.map(postgres.lock_timeout(_, 0))
    |> result.map(postgres.statement_timeout(_, 1500))
    |> result.map(postgres.inspect)
  assert parameters
    == [
      #("timezone", "UTC"),
      #("idle_in_transaction_session_timeout", "60000"),
      #("search_path", "app"),
      #("statement_timeout", "1500"),
    ]
}

/// Live tests run when HOWDY_DATABASE_TEST_POSTGRES_URL names a server whose
/// user may create databases.
fn with_postgres(run: fn(postgres.Config) -> Nil) -> Nil {
  case getenv("HOWDY_DATABASE_TEST_POSTGRES_URL") {
    Error(Nil) -> Nil
    Ok(url) -> {
      let assert Ok(config) = postgres.from_url(url)
      run(config)
    }
  }
}

fn setting(db: Repo, name: String) -> String {
  let assert Ok([value]) =
    repo.all(
      db,
      "SELECT current_setting('" <> name <> "')",
      [],
      decode.field(0, decode.string, decode.success),
    )
  value
}

pub fn start_waits_for_the_server_and_applies_session_settings_test() {
  use config <- with_postgres
  let assert Ok(db) =
    config |> postgres.parameter("search_path", "app") |> postgres.start
  assert setting(db, "TimeZone") == "UTC"
  assert setting(db, "search_path") == "app"
  assert setting(db, "statement_timeout") == "30s"
  assert setting(db, "lock_timeout") == "5s"
  assert setting(db, "idle_in_transaction_session_timeout") == "1min"
  let assert Ok(_) = repo.close(db)
  Nil
}

pub fn start_fails_clearly_when_the_server_cannot_be_reached_test() {
  use _ <- with_postgres
  let assert Ok(config) = postgres.from_url("postgres://u@127.0.0.1:1/app")
  let started = now()
  assert postgres.start(config |> postgres.startup_timeout(300))
    == Error(postgres.Unreachable)
  assert now() - started < 5000
}

pub fn migrators_wait_for_each_other_despite_the_lock_timeout_test() {
  use config <- with_postgres
  let assert Ok(admin) = postgres.start(config)
  let name = "howdy_database_test_" <> int_id()
  let assert Ok(_) = repo.execute(admin, "CREATE DATABASE " <> name, [])
  let assert Ok(url) = getenv("HOWDY_DATABASE_TEST_POSTGRES_URL")
  let assert Ok(config) = postgres.from_url(replace_database(url, name))
  let assert Ok(db) =
    config
    |> postgres.lock_timeout(50)
    |> postgres.statement_timeout(50)
    |> postgres.start

  // Hold the migration lock well past both timeouts.
  let holding = process.new_subject()
  process.spawn(fn() {
    database.transaction(db, fn(conn) {
      let assert Ok(_) = database.lock_migrations(conn)
      process.send(holding, Nil)
      process.sleep(300)
      Ok(Nil)
    })
  })
  let assert Ok(Nil) = process.receive(holding, 5000)
  let package =
    migration.Package("notes", [
      gloo_migration.new(
        1,
        "create_notes",
        "CREATE TABLE notes_notes (id TEXT PRIMARY KEY)",
      ),
    ])
  assert migration.run(db, [package]) == Ok(Nil)

  let assert Ok(_) = repo.close(db)
  let assert Ok(_) =
    repo.execute(admin, "DROP DATABASE " <> name <> " WITH (FORCE)", [])
  let assert Ok(_) = repo.close(admin)
  Nil
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn int_id() -> String {
  int.to_string(int.absolute_value(unique_integer()))
}

/// The test URL ends in its database name.
fn replace_database(url: String, name: String) -> String {
  let assert [_, ..rest] = string.split(url, "/") |> list.reverse
  string.join(list.reverse([name, ..rest]), "/")
}
