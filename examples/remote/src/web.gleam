//// The public web service. It has no user data of its own and asks the
//// users service for it.
////
//// ```sh
//// ERL_FLAGS="-sname web -setcookie howdy" gleam run -m web
//// # or, without distribution:
//// USERS_URL=http://localhost:8788/rpc RPC_TOKEN=secret gleam run -m web
//// ```

import envoy
import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/json
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision.{type ChildSpecification}
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
  let tree = supervisor.new(supervisor.OneForOne)
  let #(users, tree) = case envoy.get("USERS_URL") {
    Ok(url) -> #(
      remote.http(url, token: envoy.get("RPC_TOKEN") |> result.unwrap("")),
      tree,
    )
    Error(Nil) -> {
      // `-sname web` on this machine is `web@<host>`; the users node shares
      // the host part.
      let assert [_, host] = string.split(remote.self(), "@")
      #(remote.cluster(), supervisor.add(tree, reconnector("users@" <> host)))
    }
  }

  // Supervised inside an OTP application: restarted on a crash, drained on
  // SIGTERM. The server listens on 127.0.0.1:8787.
  let assert Ok(_) =
    tree
    |> supervisor.add(howdy.supervised(
      app(users) |> howdy.bind(to: "127.0.0.1"),
    ))
    |> howdy.start_application(name: "howdy_remote_web")
  process.sleep_forever()
}

// -- Reconnecting ------------------------------------------------------------

type Tick {
  Tick
}

type Connection {
  Connection(node: String, connected: Bool, self: Subject(Tick))
}

/// Erlang does not reconnect a lost node by itself, so an actor under the
/// supervisor tries every few seconds, ticking itself with `send_after`
/// rather than sleeping. Once connected, `remote.cluster()` finds the users
/// server.
fn reconnector(node: String) -> ChildSpecification(Subject(Tick)) {
  use <- supervision.worker
  actor.new_with_initialiser(1000, fn(self) {
    process.send(self, Tick)
    actor.initialised(Connection(node:, connected: False, self:))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(fn(state, _tick) {
    let connected = remote.connect(state.node) == Ok(Nil)
    case connected, state.connected {
      True, False -> io.println("Connected to " <> state.node)
      False, True -> io.println("Lost " <> state.node <> ", retrying")
      _, _ -> Nil
    }
    process.send_after(state.self, 5000, Tick)
    actor.continue(Connection(..state, connected:))
  })
  |> actor.start
}
