//// The API pages: finding the OpenAPI documents an app serves, and calling
//// its endpoints through the app, anonymously and as a signed-in user.

import gleam/http/request
import gleam/list
import gleam/string
import gleam/uri
import gloo/adapter/sqlite
import gloo/repo
import howdy
import howdy/admin
import howdy/auth
import howdy/auth/secret
import howdy/auth/user.{type Principal}
import howdy/controller
import howdy/database
import howdy/migration
import howdy/openapi
import howdy/openapi/endpoint.{type Endpoint}
import howdy/openapi/schema.{type Schema}
import howdy/service
import howdy/testing
import howdy/version

// -- Fixtures ----------------------------------------------------------------

pub type Note {
  Note(id: Int, title: String)
}

fn note() -> Schema(Note) {
  {
    use id <- schema.field("id", schema.int(), fn(note: Note) { note.id })
    use title <- schema.field(
      "title",
      schema.string() |> schema.not_empty,
      fn(note: Note) { note.title },
    )
    schema.success(Note(id:, title:))
  }
  |> schema.named("Note")
}

fn find() -> Endpoint(Nil) {
  use <- endpoint.describe([
    endpoint.summary("Find a note"),
    endpoint.response(200, "The note", note()),
  ])
  use id <- endpoint.path("id", schema.int())
  use ctx <- endpoint.handle
  Ok(Note(id:, title: "Note " <> string.inspect(id)))
  |> service.respond(ctx, schema.to_json(_, note()))
}

fn create() -> Endpoint(Nil) {
  use <- endpoint.describe([
    endpoint.summary("Create a note"),
    endpoint.response(201, "The note", note()),
  ])
  use input <- endpoint.body(note())
  use ctx <- endpoint.handle
  Ok(input) |> service.created(ctx, schema.to_json(_, note()))
}

fn mine() -> Endpoint(Principal) {
  use <- endpoint.describe([
    endpoint.summary("Who am I"),
    endpoint.security("session"),
    endpoint.response(200, "Your email address", schema.string()),
    endpoint.error(401, "Not signed in"),
  ])
  use ctx: controller.GuardedContext(Principal) <- endpoint.handle
  controller.json(ctx, schema.to_json(ctx.guard.user.email, schema.string()))
}

fn spec() -> openapi.Spec {
  openapi.new(title: "Notes", version: "1.0.0")
  |> openapi.bearer_auth("session")
}

fn api_app(identity: auth.Auth) -> howdy.App {
  let notes =
    controller.new("notes")
    |> endpoint.get("/:id", find())
    |> endpoint.post("/", create())
  let me =
    controller.guarded("me", auth.required(identity))
    |> endpoint.get("/", mine())
    |> controller.build
  howdy.new()
  |> howdy.controller(notes)
  |> howdy.controller(me)
  |> openapi.serve(spec(), at: "/openapi.json")
  |> admin.mount(admin.new() |> admin.auth(identity))
}

fn with_identity(run: fn(auth.Auth) -> a) -> a {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  let assert Ok(Nil) = database.sqlite_defaults(db)
  let assert Ok(Nil) = migration.run(db, [auth.schema()])
  let assert Ok(identity) =
    auth.new_without_email(repo: db, origin: "http://localhost:8787")
  let value = run(identity)
  let assert Ok(_) = repo.close(db)
  value
}

fn get(app: howdy.App, path: String) -> String {
  let res =
    testing.get(path) |> request.set_host("localhost") |> testing.send(app)
  assert res.status == 200
    as { "GET " <> path <> " gave " <> string.inspect(res.status) }
  testing.text(res)
}

fn operation(version: String, method: String, path: String) -> String {
  "/_howdy/api/operation?"
  <> uri.query_to_string([
    #("version", version),
    #("method", method),
    #("path", path),
  ])
}

fn call(app: howdy.App, at: String, fields: List(#(String, String))) -> String {
  let res =
    testing.post_form(at, fields)
    |> request.set_host("localhost")
    |> testing.send(app)
  assert res.status == 200
  testing.text(res)
}

fn new_user(app: howdy.App, email: String) -> String {
  let res =
    testing.post_form("/_howdy/users", [#("email", email)])
    |> request.set_host("localhost")
    |> testing.send(app)
  let assert Ok("/_howdy/users/" <> id) = list.key_find(res.headers, "location")
  id
}

// -- Detection ---------------------------------------------------------------

pub fn nothing_is_shown_without_a_document_test() {
  let app = howdy.new() |> admin.mount(admin.new())
  let page = get(app, "/_howdy")
  assert string.contains(page, "No OpenAPI document found")
  assert !string.contains(page, "/_howdy/api")
  let res =
    testing.get("/_howdy/api")
    |> request.set_host("localhost")
    |> testing.send(app)
  assert res.status == 404
}

pub fn finds_the_document_the_app_serves_test() {
  use identity <- with_identity
  let app = api_app(identity)
  let overview = get(app, "/_howdy")
  assert string.contains(overview, "3 endpoints")
  assert string.contains(overview, "href=\"/_howdy/api\"")

  let page = get(app, "/_howdy/api")
  assert string.contains(page, "Notes")
  assert string.contains(page, "/notes/{id}")
  assert string.contains(page, "Create a note")
  assert string.contains(page, "needs session")
}

pub fn the_operation_page_offers_a_form_test() {
  use identity <- with_identity
  let app = api_app(identity)
  let page = get(app, operation("", "post", "/notes"))
  assert string.contains(page, "Try it")
  // An example body, made from the schema.
  assert string.contains(page, "&quot;title&quot;: &quot;string&quot;")
  assert string.contains(page, "Send as")
  // The Note schema's fields, from the responses.
  assert string.contains(page, "at least 1 character")
}

// -- Calling -----------------------------------------------------------------

pub fn calls_an_endpoint_through_the_app_test() {
  use identity <- with_identity
  let app = api_app(identity)
  let page =
    call(app, operation("", "get", "/notes/{id}"), [
      #("as", ""),
      #("path:id", "7"),
    ])
  assert string.contains(page, "Note 7")
  assert string.contains(page, "anonymously")
  assert string.contains(page, "curl -X GET &#39;http://localhost/notes/7&#39;")

  // The app's own validation answers, as it would anyone.
  let page =
    call(app, operation("", "post", "/notes"), [
      #("as", ""),
      #("body", "{\"id\": 1, \"title\": \"\"}"),
    ])
  assert string.contains(page, ">422<")
  assert string.contains(page, "must not be empty")
}

pub fn calls_a_guarded_endpoint_as_a_user_test() {
  use identity <- with_identity
  let app = api_app(identity)
  let id = new_user(app, "ada@example.com")
  let at = operation("", "get", "/me")

  let page = call(app, at, [#("as", "")])
  assert string.contains(page, ">401<")

  let page = call(app, at, [#("as", id)])
  assert string.contains(page, ">200<")
  assert string.contains(page, "&quot;ada@example.com&quot;")
  assert string.contains(page, "as ada@example.com")

  // The session is kept for the next call rather than opening another.
  let _ = call(app, at, [#("as", id)])
  let assert Ok(sessions) = auth.sessions_of(identity, id)
  assert list.length(sessions) == 1

  // Revoked behind the admin's back, it is replaced on the next call.
  let assert [session] = sessions
  let assert Ok(Nil) =
    auth.revoke_session_of(identity, id, session.id, by: user.System)
  let page = call(app, at, [#("as", id)])
  assert string.contains(page, ">200<")
}

pub fn sends_a_typed_bearer_token_test() {
  use identity <- with_identity
  let app = api_app(identity)
  let id = new_user(app, "grace@example.com")
  let assert Ok(session) = auth.impersonate(identity, id, by: user.System)
  let token = secret.reveal(session.token)
  let page =
    call(app, operation("", "get", "/me"), [
      #("as", ""),
      #("scheme:session", token),
    ])
  assert string.contains(page, "&quot;grace@example.com&quot;")
}

// -- Versions ----------------------------------------------------------------

pub fn offers_each_version_test() {
  use identity <- with_identity
  let v1 = controller.new("notes") |> endpoint.get("/:id", find())
  let v2 =
    controller.new("notes")
    |> endpoint.post("/", create())
  let app =
    howdy.new()
    |> howdy.versions(
      version.new(version.header("x-api-version"))
      |> version.default("v1")
      |> version.add("v1", [v1])
      |> version.add("v2", [v2]),
    )
    |> openapi.serve(spec(), at: "/openapi.json")
    |> admin.mount(admin.new() |> admin.auth(identity))

  let index = get(app, "/_howdy/api")
  assert string.contains(index, "href=\"/_howdy/api?version=v2\"")
  let v2_index = get(app, "/_howdy/api?version=v2")
  assert string.contains(v2_index, "Create a note")
  // v2 falls back to v1 for finding a note.
  assert string.contains(v2_index, "/notes/{id}")

  // The version header starts filled in, so the call reaches v2.
  let at = operation("v2", "get", "/notes/{id}")
  let page = get(app, at)
  assert string.contains(page, "value=\"v2\"")
  let page =
    call(app, at, [
      #("as", ""),
      #("header:x-api-version", "v2"),
      #("path:id", "3"),
    ])
  assert string.contains(page, "Note 3")
}
