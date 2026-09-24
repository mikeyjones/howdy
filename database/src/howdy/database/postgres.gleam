//// Open a PostgreSQL Repo with production defaults: configuration from a
//// connection URL, TLS unless the server is local, UTC and session timeouts
//// on every connection, and a start that waits for the server and fails
//// clearly instead of leaving every later query to fail. The result is an
//// ordinary Gloo Repo, so an application that builds its own pool loses
//// nothing and can keep doing so.
////
//// ```gleam
//// let assert Ok(db) =
////   postgres.from_env()
////   |> result.map(postgres.pool_size(_, 20))
////   |> result.try(postgres.start)
//// ```

import gleam/bool
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri
import gloo/adapter.{Adapter, PgConnection}
import gloo/repo.{type Repo}
import gloo/telemetry
import pog

/// The oldest PostgreSQL major version still supported upstream.
pub const minimum_version = 14

pub type Ssl {
  /// Unencrypted. Only for a server on the same host or a private network.
  SslDisabled
  /// Encrypted without checking the server's certificate. Protects against
  /// eavesdropping but not impersonation.
  SslUnverified
  /// Encrypted, with the certificate checked against the system's CAs and
  /// the host name.
  SslVerified
}

pub type Error {
  /// The environment variable is unset or empty.
  MissingUrl(variable: String)
  /// The URL is not `postgres://user:password@host:port/database`. It is not
  /// repeated here because it may contain a password.
  InvalidUrl
  /// An `sslmode` other than `disable`, `require`, `verify-ca` or
  /// `verify-full`. There is no fallback to plain text, so `allow` and
  /// `prefer` are refused.
  UnsupportedSslMode(mode: String)
  StartFailed
  /// No query succeeded before the startup timeout: the server is down or
  /// unreachable, refused the credentials, or the database does not exist.
  Unreachable
  UnsupportedVersion(found: Int, minimum: Int)
}

pub opaque type Config {
  Config(
    host: String,
    port: Int,
    database: String,
    user: String,
    password: Option(String),
    ssl: Ssl,
    pool_size: Int,
    parameters: List(#(String, String)),
    startup_timeout: Int,
  )
}

@external(erlang, "howdy_database_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "howdy_database_ffi", "monotonic_ms")
fn now() -> Int

/// Read the connection URL from `DATABASE_URL`, as most hosts provide it.
pub fn from_env() -> Result(Config, Error) {
  case getenv("DATABASE_URL") {
    Ok(url) if url != "" -> from_url(url)
    _ -> Error(MissingUrl("DATABASE_URL"))
  }
}

/// Parse `postgres://user:password@host:port/database?sslmode=...`. The user
/// defaults to `postgres` and the port to 5432; percent-encoded characters in
/// the user, password and database are decoded. Without `sslmode`, TLS is off
/// for loopback addresses and dotless host names such as a Compose service
/// called `db`, and verified for everything else.
///
/// Every connection then starts with these settings:
///
/// - `timezone` `UTC`
/// - `statement_timeout` 30 seconds
/// - `lock_timeout` 5 seconds, the counterpart of SQLite's busy timeout
/// - `idle_in_transaction_session_timeout` 60 seconds, so a transaction left
///   open cannot hold its locks indefinitely
pub fn from_url(url: String) -> Result(Config, Error) {
  use parsed <- result.try(uri.parse(url) |> result.replace_error(InvalidUrl))
  use <- bool.guard(
    parsed.scheme != Some("postgres") && parsed.scheme != Some("postgresql"),
    Error(InvalidUrl),
  )
  use host <- result.try(case parsed.host {
    Some(host) if host != "" ->
      Ok(host |> string.replace("[", "") |> string.replace("]", ""))
    _ -> Error(InvalidUrl)
  })
  use #(user, password) <- result.try(credentials(parsed.userinfo))
  use database <- result.try(case parsed.path {
    "/" <> name if name != "" ->
      case string.contains(name, "/") {
        True -> Error(InvalidUrl)
        False -> decoded(name)
      }
    _ -> Error(InvalidUrl)
  })
  use query <- result.try(case parsed.query {
    None -> Ok([])
    Some(query) -> uri.parse_query(query) |> result.replace_error(InvalidUrl)
  })
  use ssl <- result.try(case list.key_find(query, "sslmode") {
    Error(Nil) -> Ok(default_ssl(host))
    Ok("disable") -> Ok(SslDisabled)
    Ok("require") -> Ok(SslUnverified)
    Ok("verify-ca") | Ok("verify-full") -> Ok(SslVerified)
    Ok(mode) -> Error(UnsupportedSslMode(mode))
  })
  Ok(Config(
    host:,
    port: option.unwrap(parsed.port, 5432),
    database:,
    user:,
    password:,
    ssl:,
    pool_size: 10,
    parameters: [
      #("timezone", "UTC"),
      #("statement_timeout", "30000"),
      #("lock_timeout", "5000"),
      #("idle_in_transaction_session_timeout", "60000"),
    ],
    startup_timeout: 10_000,
  ))
}

fn credentials(
  userinfo: Option(String),
) -> Result(#(String, Option(String)), Error) {
  case userinfo {
    None -> Ok(#("postgres", None))
    Some(userinfo) ->
      case string.split_once(userinfo, ":") {
        Ok(#(user, password)) -> {
          use user <- result.try(decoded(user))
          use password <- result.try(decoded(password))
          use <- bool.guard(user == "", Error(InvalidUrl))
          Ok(#(user, Some(password)))
        }
        Error(Nil) -> {
          use user <- result.try(decoded(userinfo))
          use <- bool.guard(user == "", Error(InvalidUrl))
          Ok(#(user, None))
        }
      }
  }
}

fn decoded(text: String) -> Result(String, Error) {
  uri.percent_decode(text) |> result.replace_error(InvalidUrl)
}

fn default_ssl(host: String) -> Ssl {
  case host {
    "127.0.0.1" | "::1" -> SslDisabled
    _ ->
      case string.contains(host, ".") || string.contains(host, ":") {
        True -> SslVerified
        False -> SslDisabled
      }
  }
}

pub fn ssl(config: Config, ssl: Ssl) -> Config {
  Config(..config, ssl:)
}

/// Connections kept open. Default 10.
pub fn pool_size(config: Config, size: Int) -> Config {
  Config(..config, pool_size: size)
}

/// How long `start` waits for the server to answer. Default 10 seconds.
pub fn startup_timeout(config: Config, milliseconds: Int) -> Config {
  Config(..config, startup_timeout: milliseconds)
}

/// Cancel any statement that runs longer. Zero disables the limit.
/// `howdy/migration` lifts it for its own transaction.
pub fn statement_timeout(config: Config, milliseconds: Int) -> Config {
  timeout(config, "statement_timeout", milliseconds)
}

/// Fail a statement that waits longer for a lock. Zero disables the limit.
pub fn lock_timeout(config: Config, milliseconds: Int) -> Config {
  timeout(config, "lock_timeout", milliseconds)
}

/// End the session of a transaction left idle for longer. Zero disables the
/// limit.
pub fn idle_in_transaction_timeout(
  config: Config,
  milliseconds: Int,
) -> Config {
  timeout(config, "idle_in_transaction_session_timeout", milliseconds)
}

fn timeout(config: Config, name: String, milliseconds: Int) -> Config {
  case milliseconds > 0 {
    True -> parameter(config, name, int.to_string(milliseconds))
    False -> Config(..config, parameters: without(config.parameters, name))
  }
}

/// Set any PostgreSQL run-time parameter when each connection opens,
/// replacing an earlier value for the same name. `application_name` cannot
/// be set here: the driver always reports the Erlang node name, which a
/// release sets to something like `notes@host`. Poolers such as PgBouncer
/// may refuse parameters they do not recognise: set them on the role instead
/// (`ALTER ROLE ... SET`) and pass zero to the timeout functions here.
pub fn parameter(config: Config, name: String, value: String) -> Config {
  Config(
    ..config,
    parameters: list.append(without(config.parameters, name), [#(name, value)]),
  )
}

fn without(parameters: List(#(String, String)), name: String) {
  list.filter(parameters, fn(parameter) { parameter.0 != name })
}

/// Start the pool and wait until the server answers and is at least
/// `minimum_version`. The pool is closed again when it does not.
pub fn start(config: Config) -> Result(Repo, Error) {
  let settings =
    pog.default_config(process.new_name(prefix: "howdy_postgres"))
    |> pog.host(config.host)
    |> pog.port(config.port)
    |> pog.database(config.database)
    |> pog.user(config.user)
    |> pog.password(config.password)
    |> pog.ssl(case config.ssl {
      SslDisabled -> pog.SslDisabled
      SslUnverified -> pog.SslUnverified
      SslVerified -> pog.SslVerified
    })
    |> pog.pool_size(config.pool_size)
  let settings =
    list.fold(config.parameters, settings, fn(settings, parameter) {
      pog.connection_parameter(settings, parameter.0, parameter.1)
    })
  case pog.start(settings) {
    Error(_) -> Error(StartFailed)
    Ok(actor.Started(pid:, data: conn)) -> {
      // Gloo's own Postgres adapter cannot set a port, TLS or parameters, so
      // build the same adapter it would around a pool configured here.
      let db =
        repo.from_adapter(Adapter(
          name: "postgres",
          connection: PgConnection(conn:, pid:),
          quote_identifier: adapter.postgres_quote,
          placeholder: adapter.postgres_placeholder,
          savepoint_depth: 0,
          telemetry: telemetry.disabled(),
        ))
      case ready(db, now() + config.startup_timeout) {
        Ok(Nil) -> Ok(db)
        Error(error) -> {
          let _ = repo.close(db)
          Error(error)
        }
      }
    }
  }
}

/// The pool connects in the background; poll until a query succeeds.
fn ready(db: Repo, deadline: Int) -> Result(Nil, Error) {
  let version =
    repo.all(
      db,
      "SELECT current_setting('server_version_num')",
      [],
      decode.field(0, decode.string, decode.success),
    )
  case version {
    Ok([version, ..]) ->
      case int.parse(version) {
        Ok(number) if number >= minimum_version * 10_000 -> Ok(Nil)
        Ok(number) ->
          Error(UnsupportedVersion(number / 10_000, minimum_version))
        Error(Nil) -> Error(Unreachable)
      }
    _ ->
      case now() >= deadline {
        True -> Error(Unreachable)
        False -> {
          process.sleep(200)
          ready(db, deadline)
        }
      }
  }
}

@internal
pub fn inspect(
  config: Config,
) -> #(
  String,
  Int,
  String,
  String,
  Option(String),
  Ssl,
  List(#(String, String)),
) {
  #(
    config.host,
    config.port,
    config.database,
    config.user,
    config.password,
    config.ssl,
    config.parameters,
  )
}
