import gleam/http/request
import gleam/string
import gleeunit
import gloo/repo
import howdy/admin
import howdy/testing
import howdy_admin_example as example

pub fn main() {
  gleeunit.main()
}

/// The admin mounts on the example's app and sees its table.
pub fn the_admin_sees_the_notes_table_test() {
  let db = example.open(":memory:")
  let identity = example.identity(db)
  let app =
    example.app(db, identity)
    |> admin.mount(admin.new() |> admin.auth(identity))
  let res =
    testing.get("/_howdy/data")
    |> request.set_host("localhost")
    |> testing.send(app)
  assert res.status == 200
  assert string.contains(testing.text(res), "notes_notes")
  let assert Ok(_) = repo.close(db)
}
