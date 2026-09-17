import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import howdy
import howdy/controller.{type Context}
import howdy/testing
import howdy/websocket
import howdy/websocket/channel

@external(erlang, "howdy_test_ffi", "channel_member")
fn channel_member(topics: List(String)) -> Pid

@external(erlang, "howdy_test_ffi", "stop_member")
fn stop_member(pid: Pid) -> Nil

@external(erlang, "howdy_ffi", "channel_join")
fn join_pid(topic: String, pid: Pid) -> Nil

@external(erlang, "howdy_ffi", "tuple_second")
fn tuple_second(message: dynamic.Dynamic) -> websocket.Frame

import gleam/dynamic

/// Receive what `channel.broadcast` sends to a member, as a socket would.
fn receive_frame() -> Result(websocket.Frame, Nil) {
  process.new_selector()
  |> process.select_record(atom.create(websocket.channel_tag), 1, tuple_second)
  |> process.selector_receive(200)
}

// -- upgrade -----------------------------------------------------------------

fn app() {
  howdy.new()
  |> howdy.controller(
    controller.new("ws")
    |> controller.get("/", fn(ctx: Context) {
      websocket.new(fn(_socket) { Nil })
      |> websocket.upgrade(ctx)
    }),
  )
}

pub fn upgrade_without_a_connection_is_426_test() {
  let res = testing.get("/ws") |> testing.send(app())

  assert res.status == 426
}

pub fn untrusted_browser_origins_are_rejected_before_upgrade_test() {
  let res =
    testing.get("/ws")
    |> testing.header("origin", "https://attacker.example")
    |> testing.send(app())
  assert res.status == 403
}

pub fn browser_origins_must_be_single_well_formed_and_same_origin_test() {
  use value <- list.each([
    "null", "", "http://localhost/", "http://localhost?x=1",
    "http://user@localhost", "http://localhost#x", "http://localhost.evil",
    "http://localhost:81", "http://localhost", "http://localhost http://evil",
    "http://localhost%00.evil", "http://localhost\\@evil",
  ])
  assert {
      testing.get("/ws")
      |> testing.header("origin", value)
      |> testing.send(app())
    }.status
    == 403
}

pub fn origin_normalization_test() {
  use value <- list.each(["https://localhost", "https://LOCALHOST:443"])
  assert {
      testing.get("/ws")
      |> testing.header("origin", value)
      |> testing.send(app())
    }.status
    == 426
}

pub fn underscore_hosts_support_same_origin_and_allowlists_test() {
  let origin = "http://my_app.localhost:8000"
  let req = testing.get("/ws") |> testing.header("origin", origin)
  let req =
    request.Request(
      ..req,
      scheme: http.Http,
      host: "my_app.localhost",
      port: Some(8000),
    )
  assert { testing.send(req, app()) }.status == 426
  let allowed_app =
    howdy.new()
    |> howdy.controller(
      controller.new("/ws")
      |> controller.get("/", fn(ctx) {
        websocket.new(fn(_) { Nil })
        |> websocket.allow_origins([origin])
        |> websocket.upgrade(ctx)
      }),
    )
  assert { testing.send(req, allowed_app) }.status == 426
}

pub fn https_and_ipv6_use_request_authority_test() {
  let req = testing.get("/ws") |> testing.header("origin", "https://[::1]:443")
  let req =
    request.Request(..req, scheme: http.Https, host: "[::1]", port: None)
  assert { testing.send(req, app()) }.status == 426
  let req = request.Request(..req, port: Some(8443))
  assert { testing.send(req, app()) }.status == 403
}

pub fn duplicate_origin_is_rejected_test() {
  let req =
    testing.get("/ws")
    |> testing.header("origin", "http://localhost")
    |> request.prepend_header("origin", "http://localhost")
  assert { testing.send(req, app()) }.status == 403
}

pub fn explicit_origins_support_proxies_and_required_origin_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("/ws")
      |> controller.get("/", fn(ctx) {
        websocket.new(fn(_) { Nil })
        |> websocket.allow_origins(["https://app.example"])
        |> websocket.require_origin
        |> websocket.upgrade(ctx)
      }),
    )
  assert { testing.get("/ws") |> testing.send(app) }.status == 403
  assert {
      testing.get("/ws")
      |> testing.header("origin", "http://localhost")
      |> testing.send(app)
    }.status
    == 403
  assert {
      testing.get("/ws")
      |> testing.header("origin", "https://app.example:443")
      |> testing.send(app)
    }.status
    == 426
  assert {
      testing.get("/ws")
      |> testing.header("origin", "https://evil.example")
      |> testing.header("x-forwarded-host", "evil.example")
      |> testing.send(app)
    }.status
    == 403
}

// -- channel -----------------------------------------------------------------

pub fn broadcast_reaches_every_member_test() {
  let topic = "test:everyone"
  join_pid(topic, process.self())

  channel.broadcast_text(topic, "hello")

  assert receive_frame() == Ok(websocket.Text("hello"))
}

pub fn broadcast_json_sends_encoded_text_test() {
  let topic = "test:json"
  join_pid(topic, process.self())

  channel.broadcast_json(topic, json.object([#("n", json.int(1))]))

  assert receive_frame() == Ok(websocket.Text("{\"n\":1}"))
}

pub fn broadcast_is_scoped_to_its_topic_test() {
  join_pid("test:mine", process.self())

  channel.broadcast_text("test:other", "not for you")

  assert receive_frame() == Error(Nil)
}

pub fn broadcast_to_empty_topic_is_fine_test() {
  assert channel.broadcast_text("test:nobody", "hello") == Nil
}

pub fn size_counts_live_members_once_test() {
  let topic = "test:size"
  assert channel.size(topic) == 0

  let a = channel_member([topic])
  let b = channel_member([topic])
  join_pid(topic, a)
  process.sleep(20)
  assert channel.size(topic) == 2

  stop_member(a)
  assert channel.size(topic) == 1

  stop_member(b)
  assert channel.size(topic) == 0
}

pub fn joining_twice_delivers_once_test() {
  let topic = "test:twice"
  join_pid(topic, process.self())
  join_pid(topic, process.self())

  channel.broadcast_text(topic, "once")

  assert receive_frame() == Ok(websocket.Text("once"))
  assert receive_frame() == Error(Nil)
}
