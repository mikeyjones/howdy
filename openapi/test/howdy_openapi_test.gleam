import gleam/dict
import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import howdy
import howdy/controller
import howdy/openapi
import howdy/openapi/endpoint.{type Endpoint}
import howdy/openapi/schema.{type Schema}
import howdy/service
import howdy/testing
import howdy/validate
import howdy/version

pub fn main() -> Nil {
  gleeunit.main()
}

// -- Fixtures ----------------------------------------------------------------

pub type Role {
  Admin
  Member
}

pub type User {
  User(id: Int, name: String, role: Role, nickname: Option(String))
}

pub type NewUser {
  NewUser(name: String, email: String, age: Int, tags: List(String))
}

fn role() -> Schema(Role) {
  schema.enum([#("admin", Admin), #("member", Member)])
}

fn user() -> Schema(User) {
  {
    use id <- schema.field("id", schema.int(), fn(user: User) { user.id })
    use name <- schema.field("name", schema.string(), fn(user: User) {
      user.name
    })
    use role <- schema.field("role", role(), fn(user: User) { user.role })
    use nickname <- schema.optional_field(
      "nickname",
      schema.string(),
      fn(user: User) { user.nickname },
    )
    schema.success(User(id:, name:, role:, nickname:))
  }
  |> schema.named("User")
}

fn new_user() -> Schema(NewUser) {
  use name <- schema.field(
    "name",
    schema.string()
      |> schema.rule(validate.trim())
      |> schema.not_empty
      |> schema.max_length(50),
    fn(input: NewUser) { input.name },
  )
  use email <- schema.field(
    "email",
    schema.string() |> schema.email,
    fn(input: NewUser) { input.email },
  )
  use age <- schema.field(
    "age",
    schema.int() |> schema.minimum(13),
    fn(input: NewUser) { input.age },
  )
  use tags <- schema.field(
    "tags",
    schema.list(schema.string()),
    fn(input: NewUser) { input.tags },
  )
  schema.success(NewUser(name:, email:, age:, tags:))
}

fn by_id() -> Endpoint(Nil) {
  use <- endpoint.describe([
    endpoint.summary("Find a user"),
    endpoint.response(200, "The user", user()),
    endpoint.error(404, "No user has this id"),
  ])
  use id <- endpoint.path("id", schema.int() |> schema.minimum(1))
  use ctx <- endpoint.handle
  case id {
    1 -> Ok(User(id: 1, name: "Ada", role: Admin, nickname: None))
    _ -> Error(service.NotFound("no such user"))
  }
  |> service.respond(ctx, schema.to_json(_, user()))
}

fn search() -> Endpoint(Nil) {
  use page <- endpoint.query("page", schema.int())
  use tags <- endpoint.query("tag", schema.list(schema.string()))
  use role <- endpoint.optional_query("role", role())
  use trace <- endpoint.optional_header("X-Trace", schema.string())
  use ctx <- endpoint.handle
  let role = case role {
    Some(Admin) -> "admin"
    Some(Member) -> "member"
    None -> "any"
  }
  controller.text(
    ctx,
    string.join(
      [
        string.inspect(page),
        string.join(tags, ","),
        role,
        option.unwrap(trace, "-"),
      ],
      " ",
    ),
  )
}

fn create() -> Endpoint(Nil) {
  use <- endpoint.describe([
    endpoint.summary("Create a user"),
    endpoint.tag("People"),
    endpoint.security("bearer"),
    endpoint.response(201, "The new user", user()),
  ])
  use input <- endpoint.body(new_user())
  use ctx <- endpoint.handle
  User(id: 7, name: input.name, role: Member, nickname: None)
  |> schema.to_json(user())
  |> controller.json(ctx, _)
  |> controller.with_status(201)
}

fn users() -> controller.Controller {
  controller.new("user")
  |> endpoint.get("/search", search())
  |> endpoint.get("/:id", by_id())
  |> endpoint.post("/", create())
  |> controller.get("/plain", fn(ctx) { controller.text(ctx, "plain") })
}

fn app() -> howdy.App {
  howdy.new() |> howdy.controller(users())
}

fn spec() -> openapi.Spec {
  openapi.new(title: "Users", version: "1.0.0")
  |> openapi.bearer_auth("bearer")
}

fn document() -> decode.Dynamic {
  let text = json.to_string(openapi.document(spec(), app()))
  let assert Ok(data) = json.parse(text, decode.dynamic)
  data
}

fn at(
  data: decode.Dynamic,
  path: List(String),
  decoder: decode.Decoder(a),
) -> a {
  let assert Ok(value) = decode.run(data, decode.at(path, decoder))
  value
}

// -- Schemas -----------------------------------------------------------------

pub fn schema_round_trips_test() {
  let value = User(id: 1, name: "Ada", role: Admin, nickname: Some("ada"))
  let text = json.to_string(schema.to_json(value, user()))
  assert text
    == "{\"id\":1,\"name\":\"Ada\",\"role\":\"admin\",\"nickname\":\"ada\"}"
  assert json.parse(text, schema.decoder(user())) == Ok(value)
}

pub fn optional_field_is_left_out_test() {
  let value = User(id: 2, name: "Bo", role: Member, nickname: None)
  assert json.to_string(schema.to_json(value, user()))
    == "{\"id\":2,\"name\":\"Bo\",\"role\":\"member\"}"
  assert json.parse(
      "{\"id\":2,\"name\":\"Bo\",\"role\":\"member\",\"nickname\":null}",
      schema.decoder(user()),
    )
    == Ok(value)
}

pub fn rules_normalise_while_decoding_test() {
  let body = "{\"name\":\"  Ada \",\"email\":\"a@b.co\",\"age\":30,\"tags\":[]}"
  let assert Ok(input) = json.parse(body, schema.decoder(new_user()))
  assert input.name == "Ada"
}

pub fn map_changes_the_type_test() {
  let ids =
    schema.int() |> schema.map(to: fn(n) { #(n) }, from: fn(id) { id.0 })
  assert json.parse("5", schema.decoder(ids)) == Ok(#(5))
  assert json.to_string(schema.to_json(#(5), ids)) == "5"
}

pub fn dict_and_nullable_test() {
  let scores = schema.dict(schema.nullable(schema.int()))
  let assert Ok(value) =
    json.parse("{\"a\":1,\"b\":null}", schema.decoder(scores))
  assert value == dict.from_list([#("a", Some(1)), #("b", None)])
}

// -- Endpoints ---------------------------------------------------------------

pub fn path_parameter_test() {
  let res = testing.get("/user/1") |> testing.send(app())
  assert res.status == 200
  assert testing.text(res) == "{\"id\":1,\"name\":\"Ada\",\"role\":\"admin\"}"

  let res = testing.get("/user/abc") |> testing.send(app())
  assert res.status == 400
  assert testing.error(res) == Ok("parameter id must be an integer")

  let res = testing.get("/user/0") |> testing.send(app())
  assert res.status == 400
  assert testing.error(res) == Ok("parameter id must be at least 1")

  let res = testing.get("/user/2") |> testing.send(app())
  assert res.status == 404
}

pub fn query_and_header_parameters_test() {
  let res =
    testing.get("/user/search")
    |> testing.query([#("page", "2"), #("tag", "a"), #("tag", "b")])
    |> testing.header("x-trace", "t1")
    |> testing.send(app())
  assert testing.text(res) == "2 a,b any t1"

  let res =
    testing.get("/user/search")
    |> testing.query([#("page", "1"), #("role", "member")])
    |> testing.send(app())
  assert testing.text(res) == "1  member -"

  let res = testing.get("/user/search") |> testing.send(app())
  assert res.status == 400
  assert testing.error(res) == Ok("missing query parameter page")

  let res =
    testing.get("/user/search")
    |> testing.query([#("page", "1"), #("page", "2")])
    |> testing.send(app())
  assert testing.error(res) == Ok("query parameter page must occur only once")

  let res =
    testing.get("/user/search")
    |> testing.query([#("page", "1"), #("role", "owner")])
    |> testing.send(app())
  assert testing.error(res)
    == Ok("query parameter role must be one of admin, member")
}

pub fn body_is_decoded_and_checked_test() {
  let res =
    testing.post(
      "/user",
      json.object([
        #("name", json.string(" Ada ")),
        #("email", json.string("ada@example.com")),
        #("age", json.int(30)),
        #("tags", json.array([], json.string)),
      ]),
    )
    |> testing.send(app())
  assert res.status == 201
  assert testing.text(res) == "{\"id\":7,\"name\":\"Ada\",\"role\":\"member\"}"
}

pub fn body_errors_are_field_errors_test() {
  let res =
    testing.post(
      "/user",
      json.object([
        #("name", json.string("   ")),
        #("email", json.string("nope")),
        #("age", json.string("old")),
        #("tags", json.array([json.int(1)], fn(x) { x })),
      ]),
    )
    |> testing.send(app())
  assert res.status == 422
  assert testing.field_errors(res)
    == Ok([
      service.FieldError("name", "must not be empty"),
      service.FieldError("email", "must be a valid email address"),
      service.FieldError("age", "must be an integer"),
      service.FieldError("tags.0", "must be a string"),
    ])

  let res = testing.post("/user", json.object([])) |> testing.send(app())
  let assert Ok([service.FieldError("name", "is required"), ..]) =
    testing.field_errors(res)

  let res = testing.post("/user", json.string("hi")) |> testing.send(app())
  assert testing.field_errors(res)
    == Ok([service.FieldError("body", "must be an object")])

  let res =
    testing.request(http.Post, "/user")
    |> testing.text_body("{nope")
    |> testing.send(app())
  assert res.status == 400
  assert testing.error(res) == Ok("request body is not valid JSON")
}

// -- The document ------------------------------------------------------------

pub fn document_lists_only_endpoints_test() {
  let doc = document()
  assert at(doc, ["openapi"], decode.string) == "3.1.0"
  assert at(doc, ["info", "title"], decode.string) == "Users"
  let paths = at(doc, ["paths"], decode.dict(decode.string, decode.dynamic))
  assert dict.keys(paths) |> list.sort(string.compare)
    == ["/user", "/user/search", "/user/{id}"]
}

pub fn document_describes_path_parameters_and_responses_test() {
  let doc = document()
  let op = at(doc, ["paths", "/user/{id}", "get"], decode.dynamic)
  assert at(op, ["summary"], decode.string) == "Find a user"
  assert at(op, ["tags"], decode.list(decode.string)) == ["user"]
  assert at(op, ["operationId"], decode.string) == "get_user_by_id"
  let assert Ok([param]) =
    decode.run(op, decode.at(["parameters"], decode.list(decode.dynamic)))
  assert at(param, ["in"], decode.string) == "path"
  assert at(param, ["schema", "minimum"], decode.int) == 1
  assert at(
      op,
      ["responses", "200", "content", "application/json", "schema", "$ref"],
      decode.string,
    )
    == "#/components/schemas/User"
  assert at(
      op,
      ["responses", "404", "content", "application/json", "schema", "$ref"],
      decode.string,
    )
    == "#/components/schemas/Error"
  assert at(op, ["responses", "400", "description"], decode.string)
    == "The request is malformed"
}

pub fn document_describes_bodies_test() {
  let doc = document()
  let op = at(doc, ["paths", "/user", "post"], decode.dynamic)
  assert at(op, ["tags"], decode.list(decode.string)) == ["People"]
  assert at(
      op,
      ["security"],
      decode.list(decode.dict(decode.string, decode.list(decode.string))),
    )
    == [dict.from_list([#("bearer", [])])]
  let body =
    at(
      op,
      ["requestBody", "content", "application/json", "schema"],
      decode.dynamic,
    )
  assert at(body, ["required"], decode.list(decode.string))
    == ["name", "email", "age", "tags"]
  assert at(body, ["properties", "name", "maxLength"], decode.int) == 50
  assert at(body, ["properties", "email", "format"], decode.string) == "email"
  assert at(body, ["properties", "tags", "items", "type"], decode.string)
    == "string"
  assert at(op, ["responses", "422", "description"], decode.string)
    == "The request body failed validation"
}

pub fn document_describes_query_parameters_test() {
  let doc = document()
  let params =
    at(
      doc,
      ["paths", "/user/search", "get", "parameters"],
      decode.list({
        use name <- decode.field("name", decode.string)
        use location <- decode.field("in", decode.string)
        use required <- decode.field("required", decode.bool)
        decode.success(#(name, location, required))
      }),
    )
  assert params
    == [
      #("page", "query", True),
      #("tag", "query", False),
      #("role", "query", False),
      #("x-trace", "header", False),
    ]
}

pub fn document_collects_components_test() {
  let doc = document()
  let user = at(doc, ["components", "schemas", "User"], decode.dynamic)
  assert at(user, ["required"], decode.list(decode.string))
    == ["id", "name", "role"]
  assert at(user, ["properties", "role", "enum"], decode.list(decode.string))
    == ["admin", "member"]
  assert at(
      doc,
      [
        "components",
        "schemas",
        "Error",
        "properties",
        "fields",
        "items",
        "$ref",
      ],
      decode.string,
    )
    == "#/components/schemas/FieldError"
  assert at(
      doc,
      ["components", "securitySchemes", "bearer", "scheme"],
      decode.string,
    )
    == "bearer"
}

pub fn undeclared_path_parameters_are_strings_test() {
  let files =
    controller.new("org/:org")
    |> endpoint.get("/files/*path", {
      use ctx <- endpoint.handle
      controller.text(ctx, "ok")
    })
  let text =
    openapi.document(spec(), howdy.new() |> howdy.controller(files))
    |> json.to_string
  assert string.contains(text, "\"/org/{org}/files/{path}\"")
  assert string.contains(
    text,
    "{\"name\":\"org\",\"in\":\"path\",\"required\":true,\"schema\":{\"type\":\"string\"}}",
  )
}

pub fn serve_and_reference_test() {
  let app =
    app()
    |> openapi.serve(spec(), at: "/openapi.json")
    |> openapi.reference(at: "/docs", document: "/openapi.json")
  let res = testing.get("/openapi.json") |> testing.send(app)
  assert res.status == 200
  assert string.contains(testing.text(res), "\"openapi\":\"3.1.0\"")
  // The document's own route is not in the document.
  assert !string.contains(testing.text(res), "/openapi.json")

  let res = testing.get("/docs") |> testing.send(app)
  assert string.contains(testing.text(res), "{\"url\":\"/openapi.json\"}")
}

// -- Versions ----------------------------------------------------------------

fn listing(label: String) -> Endpoint(Nil) {
  use <- endpoint.describe([
    endpoint.summary(label),
    endpoint.response(200, "The users", schema.list(schema.string())),
  ])
  use ctx <- endpoint.handle
  controller.text(ctx, label)
}

fn versioned_app(resolver: version.Resolver) -> howdy.App {
  let health =
    controller.new("health")
    |> endpoint.get("/", listing("health"))
  let v1 =
    controller.new("users")
    |> endpoint.get("/", listing("v1 list"))
    |> endpoint.get("/:id", by_id())
  let v2 =
    controller.new("users")
    |> endpoint.get("/", listing("v2 list"))
  let group =
    version.new(resolver)
    |> version.default("v1")
    |> version.add("v1", [v1])
    |> version.add("v2", [v2])
  howdy.new()
  |> howdy.controller(health)
  |> howdy.versions(group)
}

fn version_doc(app: howdy.App, name: String) -> decode.Dynamic {
  let assert Ok(document) = openapi.version_document(spec(), app, name)
  let assert Ok(data) = json.parse(json.to_string(document), decode.dynamic)
  data
}

fn path_keys(doc: decode.Dynamic) -> List(String) {
  at(doc, ["paths"], decode.dict(decode.string, decode.dynamic))
  |> dict.keys
  |> list.sort(string.compare)
}

pub fn path_versions_are_prefixed_test() {
  let app = versioned_app(version.path())
  assert openapi.versions(app) == ["v1", "v2"]

  let v2 = version_doc(app, "v2")
  assert at(v2, ["info", "version"], decode.string) == "v2"
  // v2 overrides the list and falls back to v1 for the rest; unversioned
  // routes answer in every version, unprefixed.
  assert path_keys(v2) == ["/health", "/v2/users", "/v2/users/{id}"]
  assert at(v2, ["paths", "/v2/users", "get", "summary"], decode.string)
    == "v2 list"
  assert at(v2, ["paths", "/v2/users/{id}", "get", "summary"], decode.string)
    == "Find a user"
  // Tags and ids come from the route, not the version prefix.
  assert at(v2, ["paths", "/v2/users", "get", "operationId"], decode.string)
    == "get_users"

  let v1 = version_doc(app, "v1")
  assert at(v1, ["paths", "/v1/users", "get", "summary"], decode.string)
    == "v1 list"
  assert openapi.version_document(spec(), app, "v3") == Error(Nil)
}

pub fn no_fallback_leaves_out_earlier_versions_test() {
  let app =
    howdy.new()
    |> howdy.versions(
      version.new(version.path())
      |> version.no_fallback
      |> version.add("v1", [
        controller.new("a") |> endpoint.get("/", listing("a")),
      ])
      |> version.add("v2", [
        controller.new("b") |> endpoint.get("/", listing("b")),
      ]),
    )
  assert path_keys(version_doc(app, "v2")) == ["/v2/b"]
}

pub fn header_versions_take_the_header_test() {
  let app = versioned_app(version.header("X-API-Version"))
  let parameter = fn(doc, path) {
    let assert [first, ..] =
      at(
        doc,
        ["paths", path, "get", "parameters"],
        decode.list({
          use name <- decode.field("name", decode.string)
          use location <- decode.field("in", decode.string)
          use required <- decode.field("required", decode.bool)
          use values <- decode.subfield(
            ["schema", "enum"],
            decode.list(decode.string),
          )
          decode.success(#(name, location, required, values))
        }),
      )
    first
  }
  let v2 = version_doc(app, "v2")
  assert path_keys(v2) == ["/health", "/users", "/users/{id}"]
  assert parameter(v2, "/users") == #("x-api-version", "header", True, ["v2"])
  // An unknown version is a 400.
  assert at(
      v2,
      ["paths", "/users", "get", "responses", "400", "description"],
      decode.string,
    )
    == "The request is malformed"
  // The default version may be asked for without the header.
  assert parameter(version_doc(app, "v1"), "/users")
    == #("x-api-version", "header", False, ["v1"])
  // Unversioned routes do not take it.
  let assert Error(_) =
    decode.run(
      v2,
      decode.at(["paths", "/health", "get", "parameters"], decode.dynamic),
    )
}

pub fn accept_versions_have_vendor_media_types_test() {
  let app = versioned_app(version.accept("vnd.howdy"))
  let v2 = version_doc(app, "v2")
  let content =
    at(
      v2,
      ["paths", "/users", "get", "responses", "200", "content"],
      decode.dict(decode.string, decode.dynamic),
    )
  assert dict.keys(content) == ["application/vnd.howdy.v2+json"]
  let health =
    at(
      v2,
      ["paths", "/health", "get", "responses", "200", "content"],
      decode.dict(decode.string, decode.dynamic),
    )
  assert dict.keys(health) == ["application/json"]
}

pub fn serve_serves_every_version_test() {
  let app =
    versioned_app(version.path())
    |> openapi.serve(spec(), at: "/openapi.json")
    |> openapi.reference(at: "/docs", document: "/openapi.json")
  let version_of = fn(path) {
    let res = testing.get(path) |> testing.send(app)
    assert res.status == 200
    let assert Ok(name) =
      json.parse(
        testing.text(res),
        decode.at(["info", "version"], decode.string),
      )
    name
  }
  // The main document is the default version's.
  assert version_of("/openapi.json") == "v1"
  assert version_of("/openapi/v1.json") == "v1"
  assert version_of("/openapi/v2.json") == "v2"

  let page = testing.get("/docs") |> testing.send(app) |> testing.text
  assert string.contains(
    page,
    "{\"title\":\"v1\",\"slug\":\"v1\",\"url\":\"/openapi/v1.json\",\"default\":true}",
  )
  assert string.contains(page, "\"url\":\"/openapi/v2.json\",\"default\":false")
}

pub fn main_document_is_the_newest_without_a_default_test() {
  let app =
    howdy.new()
    |> howdy.versions(
      version.new(version.header("x-v"))
      |> version.add("v1", [
        controller.new("a") |> endpoint.get("/", listing("a")),
      ])
      |> version.add("v2", [
        controller.new("b") |> endpoint.get("/", listing("b")),
      ]),
    )
  let text = json.to_string(openapi.document(spec(), app))
  assert string.contains(text, "\"version\":\"v2\"")
}

pub fn served_lists_the_documents_test() {
  assert openapi.served(app()) == []
  let single = app() |> openapi.serve(spec(), at: "/openapi.json")
  let assert [
    openapi.Served(path: "/openapi.json", version: None, main: True, document:),
  ] = openapi.served(single)
  assert string.contains(document, "\"openapi\":\"3.1.0\"")

  let versioned =
    versioned_app(version.path()) |> openapi.serve(spec(), at: "/openapi.json")
  let found =
    openapi.served(versioned)
    |> list.map(fn(served) { #(served.path, served.version, served.main) })
  assert found
    == [
      #("/openapi.json", Some("v1"), True),
      #("/openapi/v1.json", Some("v1"), False),
      #("/openapi/v2.json", Some("v2"), False),
    ]
}
