import ewe
import gleam/erlang/process
import gleam/int
import howdy
import howdy/remote
import howdy/service
import howdy_remote_fixtures.{User} as fixtures

@external(erlang, "howdy_remote_test_ffi", "crash")
fn crash() -> a

const token = "test-token-with-plenty-of-entropy"

fn crashing() -> remote.Procedure(Nil, Nil) {
  remote.procedure("http.crash", input: remote.nil(), output: remote.nil())
}

/// Serve the users procedures at `/rpc` on a free port and return the URL.
fn serve(token: String) -> String {
  let server =
    fixtures.users_server("http")
    |> remote.handle(crashing(), fn(_) { crash() })
  let listener = process.new_name("remote_http_listener")
  let assert Ok(_) =
    ewe.new(
      listener_name: listener,
      connection_factory_name: process.new_name("remote_http_connections"),
      handler: howdy.new()
        |> howdy.controller(remote.controller(server, at: "/rpc", token:))
        |> howdy.handler,
    )
    |> ewe.bind("127.0.0.1")
    |> ewe.listening(0)
    |> ewe.quiet
    |> ewe.start
  let assert ewe.TcpSocketAddress(_, port) =
    ewe.get_server_info(process.named_subject(listener))
  "http://127.0.0.1:" <> int.to_string(port) <> "/rpc"
}

pub fn http_call_test() {
  let target = remote.http(serve(token), token:)
  assert remote.call(target, fixtures.get_user("http"), 1, timeout: 2000)
    == Ok(User(id: 1, name: "Ada"))
  assert remote.call(target, fixtures.get_user("http"), 2, timeout: 2000)
    == Error(remote.Failed(service.NotFound("user not found")))
  assert remote.call(target, fixtures.whoami("http"), Nil, timeout: 2000)
    == Ok(remote.self())
}

pub fn http_trailing_slash_test() {
  let target = remote.http(serve(token) <> "/", token:)
  assert remote.call(target, fixtures.get_user("http"), 1, timeout: 2000)
    == Ok(User(id: 1, name: "Ada"))
}

pub fn http_wrong_token_is_refused_test() {
  let url = serve(token)
  assert remote.call(
      remote.http(url, token: "guess"),
      fixtures.get_user("http"),
      1,
      timeout: 2000,
    )
    == Error(remote.Refused)
  assert remote.call(
      remote.http(url, token: ""),
      fixtures.get_user("http"),
      1,
      timeout: 2000,
    )
    == Error(remote.Refused)
}

pub fn http_empty_server_token_refuses_everything_test() {
  assert remote.call(
      remote.http(serve(""), token: ""),
      fixtures.get_user("http"),
      1,
      timeout: 2000,
    )
    == Error(remote.Refused)
}

pub fn http_missing_handler_test() {
  assert remote.call(
      remote.http(serve(token), token:),
      fixtures.get_user("elsewhere"),
      1,
      timeout: 2000,
    )
    == Error(remote.NoHandler("elsewhere.users.get"))
}

pub fn http_crash_hides_detail_test() {
  assert remote.call(
      remote.http(serve(token), token:),
      crashing(),
      Nil,
      timeout: 2000,
    )
    == Error(remote.Crashed("see the serving node's log"))
}

pub fn http_unreachable_test() {
  let assert Error(remote.Unavailable(_)) =
    remote.call(
      remote.http("http://127.0.0.1:1/rpc", token:),
      fixtures.get_user("http"),
      1,
      timeout: 2000,
    )
}
