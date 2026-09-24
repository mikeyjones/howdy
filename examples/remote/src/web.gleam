//// The public web service. It has no user data of its own and asks the
//// users service for it.
////
//// ```sh
//// ERL_FLAGS="-sname web -setcookie howdy" gleam run -m web
//// # or, without distribution:
//// USERS_URL=http://localhost:8788/rpc RPC_TOKEN=secret gleam run -m web
//// ```

import envoy
import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/result
import gleam/string
import howdy
import howdy/controller
import howdy/param
import howdy/remote
import users_api

pub fn app(users: remote.Target) -> howdy.App {
  howdy.new()
  |> howdy.controller(
    controller.new("/users")
    |> controller.get("/", fn(ctx) {
      remote.call(users, users_api.list_users(), Nil, timeout: 5000)
      |> remote.respond(ctx, json.array(_, users_api.user_to_json))
    })
    |> controller.get("/:id", fn(ctx) {
      use id <- param.int(ctx, "id")
      remote.call(users, users_api.get_user(), id, timeout: 5000)
      |> remote.respond(ctx, users_api.user_to_json)
    }),
  )
}

pub fn main() -> Nil {
  let users = case envoy.get("USERS_URL") {
    Ok(url) ->
      remote.http(url, token: envoy.get("RPC_TOKEN") |> result.unwrap(""))
    Error(Nil) -> {
      // `-sname web` on this machine is `web@<host>`; the users node shares
      // the host part.
      let assert [_, host] = string.split(remote.self(), "@")
      stay_connected("users@" <> host)
      remote.cluster()
    }
  }

  let assert Ok(_) = app(users) |> howdy.start
  process.sleep_forever()
}

/// Erlang does not reconnect a lost node by itself, so try every few
/// seconds. Once connected, `remote.cluster()` finds the users server.
fn stay_connected(node: String) -> Nil {
  process.spawn(fn() { reconnect(node, False) })
  Nil
}

fn reconnect(node: String, was_connected: Bool) -> Nil {
  let connected = remote.connect(node) == Ok(Nil)
  case connected, was_connected {
    True, False -> io.println("Connected to " <> node)
    False, True -> io.println("Lost " <> node <> ", retrying")
    _, _ -> Nil
  }
  process.sleep(5000)
  reconnect(node, connected)
}
