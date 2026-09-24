import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/time/timestamp
import howdy
import howdy/auth
import howdy/auth/routes
import howdy/rate_limit
import howdy/testing
import support.{count, exec, fixture}

/// A node serving the auth API, with every request from one client.
fn node(identity: auth.Auth) -> howdy.App {
  howdy.new()
  |> howdy.controller(
    routes.api_limited_by(identity, at: "/api/auth", key: fn(_) {
      Some("203.0.113.9")
    }),
  )
}

/// Windows follow the clock's minutes; a test that crossed one would see its
/// count reset partway through.
fn clear_of_window_end() -> Nil {
  let #(seconds, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  case seconds % 60 > 45 {
    True -> process.sleep({ 61 - seconds % 60 } * 1000)
    False -> Nil
  }
}

fn attempt(app: howdy.App) -> Int {
  testing.post(
    "/api/auth/token",
    json.object([#("token", json.string("not-a-real-token"))]),
  )
  |> testing.send(app)
  |> fn(answer) { answer.status }
}

pub fn nodes_share_the_per_client_limit_test() {
  clear_of_window_end()
  use database, identity, _, _ <- fixture
  let identity = auth.with_shared_rate_limits(identity)
  // Two nodes, as behind a load balancer: same database, separate processes'
  // worth of limiters.
  let first = node(identity)
  let second = node(identity)
  let statuses =
    list.repeat(Nil, routes.credential_limit)
    |> list.index_map(fn(_, i) {
      case i % 2 {
        0 -> attempt(first)
        _ -> attempt(second)
      }
    })
  assert list.all(statuses, fn(status) { status == 401 })
  assert attempt(first) == 429
  assert attempt(second) == 429
  // Clients are stored only as digests.
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_rate_limits WHERE key LIKE '%203.0.113.9%'",
    )
    == 0
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_rate_limits") == 1
}

pub fn unshared_nodes_count_apart_test() {
  clear_of_window_end()
  use _, identity, _, _ <- fixture
  let first = node(identity)
  let second = node(identity)
  list.each(list.repeat(Nil, routes.credential_limit), fn(_) {
    assert attempt(first) == 401
  })
  assert attempt(first) == 429
  assert attempt(second) == 401
}

pub fn concurrent_hits_are_all_counted_test() {
  clear_of_window_end()
  use _, identity, _, _ <- fixture
  let store = auth.rate_limit_store(identity)
  let limiter =
    rate_limit.shared(limit: 1000, per_seconds: 60, name: "app.test", store:)
  let done = process.new_subject()
  list.each(list.repeat(Nil, 40), fn(_) {
    process.spawn(fn() {
      process.send(done, rate_limit.check(limiter, "client"))
    })
  })
  list.each(list.repeat(Nil, 40), fn(_) {
    let assert Ok(rate_limit.Allowed(..)) = process.receive(done, 5000)
  })
  let assert rate_limit.Allowed(remaining:, ..) =
    rate_limit.check(limiter, "client")
  assert remaining == 1000 - 41
}

pub fn prune_expired_clears_old_windows_test() {
  use database, identity, _, _ <- fixture
  let identity = auth.with_shared_rate_limits(identity)
  let _ = attempt(node(identity))
  exec(
    database,
    "INSERT INTO howdy_auth_rate_limits(key, window_start, hits, expires_at) VALUES ('old', 1, 5, 1000)",
  )
  let assert Ok(Nil) = auth.prune_expired(identity)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_rate_limits") == 1
}
