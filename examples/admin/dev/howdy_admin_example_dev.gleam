//// Development entry point: `gleam dev`. The same app as `gleam run`, with
//// hot reload and the admin area at <http://localhost:8787/_howdy>.
////
//// The database and auth are opened once here and handed to both the app
//// and the admin, which is how the admin knows what to show: there is no
//// package detection in Gleam, so registration is explicit.

import gleam/erlang/process
import howdy
import howdy/admin
import howdy/dev
import howdy_admin_example as example

pub fn main() -> Nil {
  let db = example.open("admin_example.sqlite")
  let identity = example.identity(db)
  let permissions = example.permissions(db)
  let dashboard =
    admin.new()
    |> admin.named("Notes admin")
    |> admin.auth(identity)
    |> admin.authorization(permissions)

  let assert Ok(_) =
    dev.start(fn() {
      example.app(db, identity, permissions)
      |> admin.mount(dashboard)
      |> howdy.listening(on: 8787)
    })
  process.sleep_forever()
}
