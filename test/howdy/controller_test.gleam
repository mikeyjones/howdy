import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/response
import gleam/json
import howdy
import howdy/controller.{type Context}
import howdy/testing

fn user_controller() -> controller.Controller {
  controller.new("user")
  |> controller.get("/all", fn(ctx: Context) {
    controller.text(ctx, "all users")
  })
  |> controller.get(":id", fn(ctx: Context) {
    let assert Ok(id) = controller.param(ctx, "id")
    controller.json(ctx, json.object([#("id", json.string(id))]))
  })
  |> controller.post("/", fn(ctx: Context) {
    let assert Ok(bits) = controller.read_body(ctx, limit: 1024)
    let assert Ok(body) = bit_array.to_string(bits)
    controller.text(ctx, "created " <> body)
    |> controller.with_status(201)
  })
}

fn app() -> howdy.App {
  howdy.new() |> howdy.controller(user_controller())
}

pub fn static_route_test() {
  let res = testing.get("/user/all") |> testing.send(app())
  assert res.status == 200
  assert testing.text(res) == "all users"
  assert response.get_header(res, "content-type")
    == Ok("text/plain; charset=utf-8")
}

pub fn param_route_test() {
  let res = testing.get("/user/42") |> testing.send(app())
  assert res.status == 200
  assert testing.json(res, decode.at(["id"], decode.string)) == Ok("42")
  assert response.get_header(res, "content-type")
    == Ok("application/json; charset=utf-8")
}

pub fn post_with_status_test() {
  let res =
    testing.request(http.Post, "/user")
    |> testing.text_body("mike")
    |> testing.send(app())
  assert res.status == 201
  assert testing.text(res) == "created mike"
}

pub fn trailing_slash_is_ignored_test() {
  let res =
    testing.request(http.Post, "/user/")
    |> testing.text_body("x")
    |> testing.send(app())
  assert res.status == 201
}

pub fn not_found_test() {
  assert { testing.get("/nope") |> testing.send(app()) }.status == 404
  assert { testing.get("/user/1/extra") |> testing.send(app()) }.status == 404
}

pub fn method_not_allowed_test() {
  let res = testing.delete("/user/all") |> testing.send(app())
  assert res.status == 405
  assert response.get_header(res, "allow") == Ok("GET")
}

pub fn options_is_answered_for_known_paths_test() {
  let res = testing.request(http.Options, "/user/all") |> testing.send(app())
  assert res.status == 204
  assert testing.text(res) == ""
  assert response.get_header(res, "allow") == Ok("GET, OPTIONS")

  let res = testing.request(http.Options, "/nope") |> testing.send(app())
  assert res.status == 404
}

pub fn multiple_controllers_test() {
  let posts =
    controller.new("/posts/")
    |> controller.get("/", fn(ctx: Context) { controller.text(ctx, "posts") })

  let app =
    howdy.new()
    |> howdy.controller(user_controller())
    |> howdy.controller(posts)

  let res = testing.get("/posts") |> testing.send(app)
  assert testing.text(res) == "posts"
}

pub fn nested_prefix_test() {
  let api =
    controller.new("api/v1/user")
    |> controller.get(":id/profile", fn(ctx: Context) {
      let assert Ok(id) = controller.param(ctx, "id")
      controller.text(ctx, "profile " <> id)
    })

  let app = howdy.new() |> howdy.controller(api)
  let res = testing.get("/api/v1/user/7/profile") |> testing.send(app)
  assert testing.text(res) == "profile 7"
}
