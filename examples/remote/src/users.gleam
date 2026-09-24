//// The users service. It owns the data and offers it to the cluster over
//// Erlang distribution, and to callers outside the cluster over HTTP.
////
//// ```sh
//// ERL_FLAGS="-sname users -setcookie howdy" RPC_TOKEN=secret gleam run -m users
//// ```

import envoy
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/result
import howdy
import howdy/remote
import howdy/service
import users_api.{type User, User}

const users = [User(1, "Ada"), User(2, "Grace"), User(3, "Barbara")]

pub fn find(id: Int) -> service.Result(User) {
  list.find(users, fn(user) { user.id == id })
  |> result.replace_error(service.NotFound("user not found"))
}

pub fn server() -> remote.Server {
  remote.server()
  |> remote.handle(users_api.get_user(), find)
  |> remote.handle(users_api.list_users(), fn(_) { Ok(users) })
}

pub fn main() -> Nil {
  let server = server()
  let assert Ok(_) = remote.start(server)
  io.println("Serving users procedures as " <> remote.self())

  case envoy.get("RPC_TOKEN") {
    Ok(token) -> {
      let assert Ok(_) =
        howdy.new()
        |> howdy.controller(remote.controller(server, at: "/rpc", token:))
        |> howdy.listening(on: 8788)
        |> howdy.start
      Nil
    }
    Error(Nil) -> io.println("Set RPC_TOKEN to serve over HTTP as well")
  }

  process.sleep_forever()
}
