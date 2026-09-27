import gleam/dynamic/decode
import gleam/json
import howdy/testing
import howdy_chat_example.{app}

pub fn room_starts_empty_test() {
  let res = testing.get("/rooms/lobby") |> testing.send(app())

  let members = {
    use members <- decode.field("members", decode.int)
    decode.success(members)
  }
  assert res.status == 200
  assert testing.json(res, members) == Ok(0)
}

pub fn announce_is_accepted_test() {
  let res =
    testing.post(
      "/rooms/lobby/announce",
      json.object([#("text", json.string("hi"))]),
    )
    |> testing.send(app())

  assert res.status == 202
}

pub fn chat_requires_a_name_test() {
  let res = testing.get("/chat/lobby") |> testing.send(app())

  assert res.status == 400
  assert testing.error(res) == Ok("missing query parameter name")
}

pub fn chat_cannot_upgrade_without_a_connection_test() {
  let res = testing.get("/chat/lobby?name=Ada") |> testing.send(app())

  assert res.status == 426
}
