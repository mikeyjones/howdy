//// Calls between two real nodes. The test node becomes distributed and
//// starts a peer node that loads the same code, as a second service would.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/string
import howdy/remote
import howdy/service
import howdy_remote_fixtures.{User} as fixtures

@external(erlang, "howdy_remote_test_ffi", "start_distribution")
fn start_distribution() -> Nil

@external(erlang, "howdy_remote_test_ffi", "start_peer")
fn start_peer() -> #(Pid, String)

@external(erlang, "howdy_remote_test_ffi", "stop_peer")
fn stop_peer(peer: Pid) -> Nil

fn with_peer(prefix: String, test_body: fn(String) -> Nil) -> Nil {
  start_distribution()
  let #(peer, node) = start_peer()
  // Start the server on the peer with a plain Erlang call.
  let assert Ok(True) =
    remote.apply(
      on: node,
      module: "howdy_remote_fixtures",
      function: "serve_users",
      args: [dynamic.string(prefix)],
      decoder: decode.bool,
      timeout: 5000,
    )
  assert fixtures.await_provider(fixtures.whoami(prefix), node, 100)
  test_body(node)
  stop_peer(peer)
}

pub fn cluster_call_reaches_another_node_test() {
  use node <- with_peer("peer_cluster")
  assert remote.call(
      remote.cluster(),
      fixtures.whoami("peer_cluster"),
      Nil,
      timeout: 2000,
    )
    == Ok(node)
  assert remote.call(
      remote.cluster(),
      fixtures.get_user("peer_cluster"),
      2,
      timeout: 2000,
    )
    == Error(remote.Failed(service.NotFound("user not found")))
}

pub fn node_target_test() {
  use node <- with_peer("peer_node")
  assert remote.call(
      remote.node(node),
      fixtures.get_user("peer_node"),
      1,
      timeout: 2000,
    )
    == Ok(User(id: 1, name: "Ada"))
}

pub fn cluster_prefers_this_node_test() {
  use node <- with_peer("peer_local")
  let assert Ok(_) = remote.start(fixtures.users_server("peer_local"))
  assert remote.providers(fixtures.whoami("peer_local"))
    == list.sort([node, remote.self()], string.compare)
  assert remote.call(
      remote.cluster(),
      fixtures.whoami("peer_local"),
      Nil,
      timeout: 2000,
    )
    == Ok(remote.self())
  assert remote.multicall(fixtures.whoami("peer_local"), Nil, timeout: 2000)
    == list.sort(
      [#(node, Ok(node)), #(remote.self(), Ok(remote.self()))],
      fn(a, b) { string.compare(a.0, b.0) },
    )
}

pub fn first_call_from_a_fresh_node_test() {
  start_distribution()
  let assert Ok(_) = remote.start(fixtures.users_server("fresh"))
  let #(peer, node) = start_peer()
  // The peer has never touched howdy_remote, so its scope starts during
  // this very call and knows no members yet.
  assert remote.apply(
      on: node,
      module: "howdy_remote_fixtures",
      function: "first_call_via_cluster",
      args: [dynamic.string("fresh")],
      decoder: decode.string,
      timeout: 5000,
    )
    == Ok(remote.self())
  stop_peer(peer)
}

pub fn stopped_node_test() {
  start_distribution()
  let #(peer, node) = start_peer()
  let assert Ok(True) =
    remote.apply(
      on: node,
      module: "howdy_remote_fixtures",
      function: "serve_users",
      args: [dynamic.string("peer_gone")],
      decoder: decode.bool,
      timeout: 5000,
    )
  assert fixtures.await_provider(fixtures.whoami("peer_gone"), node, 100)
  stop_peer(peer)
  process.sleep(50)
  assert remote.providers(fixtures.whoami("peer_gone")) == []
  assert remote.call(
      remote.cluster(),
      fixtures.whoami("peer_gone"),
      Nil,
      timeout: 1000,
    )
    == Error(remote.NoHandler("peer_gone.whoami"))
  let assert Error(remote.Unavailable(_)) =
    remote.call(
      remote.node(node),
      fixtures.whoami("peer_gone"),
      Nil,
      timeout: 1000,
    )
}
