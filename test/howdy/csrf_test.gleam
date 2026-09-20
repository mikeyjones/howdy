import gleam/http
import gleam/http/request
import howdy
import howdy/controller
import howdy/csrf
import howdy/form
import howdy/testing

const origin = "https://example.com"

fn app() -> howdy.App {
  howdy.new()
  |> howdy.middleware(csrf.middleware(csrf.new([origin])))
  |> howdy.controller(
    controller.new("/notes")
    |> controller.get("/", fn(ctx) { controller.text(ctx, "read") })
    |> controller.post("/", fn(ctx) {
      use fields <- form.read(ctx)
      controller.text(ctx, form.value(fields, "body"))
    })
    |> controller.delete("/", fn(ctx) { controller.text(ctx, "gone") }),
  )
}

fn post(headers: List(#(String, String))) {
  headers
  |> list_fold(testing.post_form("/notes", [#("body", "written")]))
  |> testing.send(app())
}

fn list_fold(
  headers: List(#(String, String)),
  req: request.Request(howdy.Body),
) -> request.Request(howdy.Body) {
  case headers {
    [] -> req
    [#(name, value), ..rest] ->
      list_fold(rest, request.prepend_header(req, name, value))
  }
}

pub fn matching_origin_is_allowed_test() {
  let res = post([#("origin", origin)])
  assert res.status == 200
  assert testing.text(res) == "written"
}

pub fn origin_comparison_ignores_case_test() {
  assert post([#("Origin", "HTTPS://EXAMPLE.COM")]).status == 200
}

pub fn missing_origin_is_rejected_test() {
  let res = post([])
  assert res.status == 403
  assert testing.error(res) == Ok("forbidden")
}

pub fn foreign_origin_is_rejected_test() {
  assert post([#("origin", "https://evil.com")]).status == 403
  // A prefix of the allowed origin is a different origin.
  assert post([#("origin", "https://example.com.evil.com")]).status == 403
  assert post([#("origin", "http://example.com")]).status == 403
  assert post([#("origin", "https://example.com:8443")]).status == 403
}

pub fn null_origin_is_rejected_test() {
  assert post([#("origin", "null")]).status == 403
}

pub fn duplicate_origins_are_rejected_test() {
  assert post([#("origin", origin), #("origin", origin)]).status == 403
}

pub fn reads_are_not_checked_test() {
  let res = testing.get("/notes") |> testing.send(app())
  assert res.status == 200
  assert testing.text(res) == "read"
}

pub fn every_write_method_is_checked_test() {
  let send = fn(method) {
    testing.request(method, "/notes") |> testing.send(app())
  }
  assert send(http.Delete).status == 403
  assert testing.request(http.Delete, "/notes")
    |> testing.header("origin", origin)
    |> testing.send(app())
    |> fn(res) { res.status }
    == 200
}

pub fn exempt_requests_skip_the_check_test() {
  let policy =
    csrf.new([origin])
    |> csrf.exempt(fn(ctx) {
      case request.get_header(ctx.request, "authorization") {
        Ok("Bearer " <> _) -> True
        _ -> False
      }
    })
  let app =
    howdy.new()
    |> howdy.middleware(csrf.middleware(policy))
    |> howdy.controller(
      controller.new("/notes")
      |> controller.post("/", fn(ctx) { controller.text(ctx, "written") }),
    )
  let send = fn(req) { testing.send(req, app) }

  let res =
    send(
      testing.post_form("/notes", [])
      |> testing.header("authorization", "Bearer abc"),
    )
  assert res.status == 200
  assert send(testing.post_form("/notes", [])).status == 403
  assert send(
      testing.post_form("/notes", [])
      |> testing.header("authorization", "Basic abc"),
    ).status
    == 403
}

pub fn check_is_usable_directly_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("/notes")
      |> controller.post("/", fn(ctx) {
        case csrf.check(ctx, [origin]) {
          Ok(Nil) -> controller.text(ctx, "written")
          Error(error) -> service_error(ctx, error)
        }
      }),
    )
  let send = fn(req) { testing.send(req, app) }
  assert send(
      testing.post_form("/notes", []) |> testing.header("origin", origin),
    ).status
    == 200
  assert send(testing.post_form("/notes", [])).status == 403
}

fn service_error(ctx, error) {
  howdy_service_error_response(ctx, error)
}

@external(erlang, "howdy@service", "error_response")
fn howdy_service_error_response(ctx: a, error: b) -> c
