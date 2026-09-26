//// Endpoints are handlers that declare their inputs with schemas, so the
//// OpenAPI document shows exactly what each route reads. Mount them on an
//// ordinary controller with `endpoint.get`, `endpoint.post` and the rest.
////
//// ```gleam
//// import howdy/openapi/endpoint.{type Endpoint}
//// import howdy/openapi/schema
////
//// pub fn controller() -> controller.Controller {
////   controller.new("user")
////   |> endpoint.get("/:id", by_id())
//// }
////
//// fn by_id() -> Endpoint(Nil) {
////   use <- endpoint.describe([
////     endpoint.summary("Find a user"),
////     endpoint.response(200, "The user", user.schema()),
////     endpoint.error(404, "No user has this id"),
////   ])
////   use id <- endpoint.path("id", schema.int())
////   use ctx <- endpoint.handle
////   user_service.find(id)
////   |> service.respond(ctx, schema.to_json(_, user.schema()))
//// }
//// ```
////
//// Each input runs in order before the handler. A missing or malformed
//// parameter answers `400`, as `howdy/param` and `howdy/query` do. A body
//// that is not JSON answers `400`; one that does not match its schema
//// answers `422` with an error for every field, as `howdy/validate` does.
////
//// Like schema objects, an endpoint is documented by running its inputs
//// with placeholder values. Do the work inside `handle`, not between the
//// inputs, so documenting an endpoint never runs it.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http.{type Method}
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import howdy/body
import howdy/content.{type Content}
import howdy/context
import howdy/controller.{
  type Builder, type GuardedContext, type Middleware, type Route,
}
import howdy/openapi/schema.{type Schema}
import howdy/query
import howdy/service

/// A handler together with the inputs it reads and its documentation.
/// `guarded` is the controller guard's result type, as for controllers.
pub opaque type Endpoint(guarded) {
  Endpoint(
    inputs: fn() -> List(Input),
    docs: fn() -> List(Doc),
    handler: fn(GuardedContext(guarded)) -> Response(Content),
  )
}

type Input {
  Parameter(location: String, name: String, required: Bool, node: schema.Node)
  Body(node: schema.Node)
}

/// A piece of documentation for an endpoint. See `describe`.
pub opaque type Doc {
  Summary(String)
  Description(String)
  Tag(String)
  OperationId(String)
  Deprecated
  Reply(status: Int, description: String, body: Option(schema.Node))
  Security(String)
}

/// What a route's annotation holds: an endpoint without its handler.
type Operation {
  Operation(inputs: fn() -> List(Input), docs: fn() -> List(Doc))
}

const annotation_key = "howdy_openapi"

// -- Mounting ----------------------------------------------------------------

/// Add an endpoint to a controller, like `controller.route`.
pub fn route(
  controller: Builder(guarded),
  method: Method,
  path: String,
  endpoint: Endpoint(guarded),
) -> Builder(guarded) {
  let operation = Operation(inputs: endpoint.inputs, docs: endpoint.docs)
  controller.route(controller, method, path, endpoint.handler)
  |> controller.annotate(annotation_key, to_dynamic(operation))
}

pub fn get(
  controller: Builder(guarded),
  path: String,
  endpoint: Endpoint(guarded),
) -> Builder(guarded) {
  route(controller, http.Get, path, endpoint)
}

pub fn post(
  controller: Builder(guarded),
  path: String,
  endpoint: Endpoint(guarded),
) -> Builder(guarded) {
  route(controller, http.Post, path, endpoint)
}

pub fn put(
  controller: Builder(guarded),
  path: String,
  endpoint: Endpoint(guarded),
) -> Builder(guarded) {
  route(controller, http.Put, path, endpoint)
}

pub fn patch(
  controller: Builder(guarded),
  path: String,
  endpoint: Endpoint(guarded),
) -> Builder(guarded) {
  route(controller, http.Patch, path, endpoint)
}

pub fn delete(
  controller: Builder(guarded),
  path: String,
  endpoint: Endpoint(guarded),
) -> Builder(guarded) {
  route(controller, http.Delete, path, endpoint)
}

/// Run middleware around one endpoint, like `middleware.wrap` for a
/// handler. It runs after the controller guard.
pub fn wrap(endpoint: Endpoint(Nil), middleware: Middleware) -> Endpoint(Nil) {
  Endpoint(..endpoint, handler: controller.wrap(endpoint.handler, middleware))
}

// -- Building ----------------------------------------------------------------

/// The handler, which runs once every input has been read.
pub fn handle(
  handler: fn(GuardedContext(guarded)) -> Response(Content),
) -> Endpoint(guarded) {
  Endpoint(inputs: fn() { [] }, docs: fn() { [] }, handler:)
}

/// Document the endpoint. Usually the first line of it.
pub fn describe(
  docs: List(Doc),
  next: fn() -> Endpoint(guarded),
) -> Endpoint(guarded) {
  Endpoint(
    inputs: fn() { next().inputs() },
    docs: fn() { list.append(docs, next().docs()) },
    handler: fn(ctx) { next().handler(ctx) },
  )
}

/// A path parameter captured by a `:name` or `*name` segment. Parameters in
/// the route that an endpoint does not read are documented as strings.
pub fn path(
  name: String,
  input: Schema(a),
  next: fn(a) -> Endpoint(guarded),
) -> Endpoint(guarded) {
  use ctx <- step(
    Parameter("path", name, True, schema.node(input)),
    input,
    next,
  )
  case controller.param(ctx, name) {
    Ok(text) ->
      schema.from_text(input, [text])
      |> result.map_error(fn(errors) {
        "parameter " <> name <> " " <> first_message(errors)
      })
    Error(Nil) -> Error("missing parameter " <> name)
  }
}

/// A required query parameter. With a `schema.list` it takes every
/// occurrence of the key, and is `[]` when there are none.
pub fn query(
  name: String,
  input: Schema(a),
  next: fn(a) -> Endpoint(guarded),
) -> Endpoint(guarded) {
  let required = !schema.is_repeated(input)
  let parameter = Parameter("query", name, required, schema.node(input))
  use ctx <- step(parameter, input, next)
  use values <- result.try(query_values(ctx, name))
  case values, required {
    [], True -> Error("missing query parameter " <> name)
    _, _ -> read_query(input, name, values)
  }
}

/// A query parameter that may be left out.
pub fn optional_query(
  name: String,
  input: Schema(a),
  next: fn(Option(a)) -> Endpoint(guarded),
) -> Endpoint(guarded) {
  let parameter = Parameter("query", name, False, schema.node(input))
  use ctx <- optional_step(parameter, next)
  use values <- result.try(query_values(ctx, name))
  case values {
    [] -> Ok(None)
    _ -> read_query(input, name, values) |> result.map(Some)
  }
}

fn query_values(
  ctx: GuardedContext(guarded),
  name: String,
) -> Result(List(String), String) {
  case query.get_query(ctx.request) {
    Ok(pairs) ->
      Ok(
        list.filter_map(pairs, fn(pair) {
          case pair.0 == name {
            True -> Ok(pair.1)
            False -> Error(Nil)
          }
        }),
      )
    Error(Nil) -> Error("query string has invalid encoding")
  }
}

fn read_query(
  input: Schema(a),
  name: String,
  values: List(String),
) -> Result(a, String) {
  case values, schema.is_repeated(input) {
    [_, _, ..], False ->
      Error("query parameter " <> name <> " must occur only once")
    _, _ ->
      schema.from_text(input, values)
      |> result.map_error(fn(errors) {
        "query parameter " <> name <> " " <> first_message(errors)
      })
  }
}

/// A required request header.
pub fn header(
  name: String,
  input: Schema(a),
  next: fn(a) -> Endpoint(guarded),
) -> Endpoint(guarded) {
  let name = string.lowercase(name)
  use ctx <- step(
    Parameter("header", name, True, schema.node(input)),
    input,
    next,
  )
  case request.get_header(ctx.request, name) {
    Ok(text) -> read_header(input, name, text)
    Error(Nil) -> Error("missing header " <> name)
  }
}

/// A request header that may be left out.
pub fn optional_header(
  name: String,
  input: Schema(a),
  next: fn(Option(a)) -> Endpoint(guarded),
) -> Endpoint(guarded) {
  let name = string.lowercase(name)
  let parameter = Parameter("header", name, False, schema.node(input))
  use ctx <- optional_step(parameter, next)
  case request.get_header(ctx.request, name) {
    Ok(text) -> read_header(input, name, text) |> result.map(Some)
    Error(Nil) -> Ok(None)
  }
}

fn read_header(
  input: Schema(a),
  name: String,
  text: String,
) -> Result(a, String) {
  schema.from_text(input, [text])
  |> result.map_error(fn(errors) {
    "header " <> name <> " " <> first_message(errors)
  })
}

/// A JSON request body, up to `body.default_limit` bytes.
pub fn body(
  input: Schema(a),
  next: fn(a) -> Endpoint(guarded),
) -> Endpoint(guarded) {
  body_with_limit(input, body.default_limit, next)
}

/// A JSON request body, up to `limit` bytes.
pub fn body_with_limit(
  input: Schema(a),
  limit: Int,
  next: fn(a) -> Endpoint(guarded),
) -> Endpoint(guarded) {
  let rest = fn() { next(schema.placeholder(input)) }
  Endpoint(
    inputs: fn() { [Body(schema.node(input)), ..rest().inputs()] },
    docs: fn() { rest().docs() },
    handler: fn(ctx) {
      case read_body(ctx, input, limit) {
        Ok(value) -> next(value).handler(ctx)
        Error(error) -> service.error_response(ctx, error)
      }
    },
  )
}

fn read_body(
  ctx: GuardedContext(guarded),
  input: Schema(a),
  limit: Int,
) -> Result(a, service.Error) {
  use bits <- result.try(
    controller.read_body(ctx, limit:)
    |> result.map_error(fn(error) {
      case error {
        context.BodyTooLarge -> service.Invalid("request body too large")
        context.InvalidBody -> service.Invalid("request body could not be read")
      }
    }),
  )
  use data <- result.try(
    json.parse_bits(bits, decode.dynamic)
    |> result.replace_error(service.Invalid("request body is not valid JSON")),
  )
  decode.run(data, schema.decoder(input))
  |> result.map_error(fn(errors) {
    service.Validation(body_errors(input, data, errors))
  })
}

/// Field errors for a body. A body that should be an object but is not
/// would otherwise report every field as the object it is missing.
fn body_errors(
  input: Schema(a),
  data: Dynamic,
  errors: List(decode.DecodeError),
) -> List(service.FieldError) {
  let is_object =
    decode.run(data, decode.dict(decode.string, decode.dynamic))
    |> result.is_ok
  case is_object || !schema.is_object(input) {
    True ->
      list.map(errors, fn(error) {
        let field = case error.path {
          [] -> "body"
          path -> string.join(path, ".")
        }
        service.FieldError(field:, message: message(error))
      })
    False -> [service.FieldError(field: "body", message: "must be an object")]
  }
}

fn step(
  input: Input,
  value_schema: Schema(a),
  next: fn(a) -> Endpoint(guarded),
  read: fn(GuardedContext(guarded)) -> Result(a, String),
) -> Endpoint(guarded) {
  let rest = fn() { next(schema.placeholder(value_schema)) }
  Endpoint(
    inputs: fn() { [input, ..rest().inputs()] },
    docs: fn() { rest().docs() },
    handler: fn(ctx) {
      case read(ctx) {
        Ok(value) -> next(value).handler(ctx)
        Error(message) -> service.error_response(ctx, service.Invalid(message))
      }
    },
  )
}

fn optional_step(
  input: Input,
  next: fn(Option(a)) -> Endpoint(guarded),
  read: fn(GuardedContext(guarded)) -> Result(Option(a), String),
) -> Endpoint(guarded) {
  let rest = fn() { next(None) }
  Endpoint(
    inputs: fn() { [input, ..rest().inputs()] },
    docs: fn() { rest().docs() },
    handler: fn(ctx) {
      case read(ctx) {
        Ok(value) -> next(value).handler(ctx)
        Error(message) -> service.error_response(ctx, service.Invalid(message))
      }
    },
  )
}

fn first_message(errors: List(decode.DecodeError)) -> String {
  case errors {
    [error, ..] -> message(error)
    [] -> "is invalid"
  }
}

/// A decode error as the message a client sees. Schema constraints fail
/// with their message already; the decoders' type names are translated.
fn message(error: decode.DecodeError) -> String {
  case error.expected {
    "String" -> "must be a string"
    "Int" -> "must be an integer"
    "Float" -> "must be a number"
    "Bool" -> "must be true or false"
    "List" -> "must be an array"
    "Dict" -> "must be an object"
    "Field" -> "is required"
    "Nil" -> "must be null"
    expected -> expected
  }
}

// -- Documentation -----------------------------------------------------------

/// A one-line summary, shown next to the route.
pub fn summary(text: String) -> Doc {
  Summary(text)
}

/// A longer description. OpenAPI allows Markdown here.
pub fn description(text: String) -> Doc {
  Description(text)
}

/// Group the endpoint under a tag. Without one, an endpoint is tagged with
/// the first fixed segment of its path, such as `user` for `/user/:id`.
pub fn tag(name: String) -> Doc {
  Tag(name)
}

/// The operation's id, which client generators use as a function name.
/// Without one it is the method and path, with parameters named after
/// `by`: `get_user` for `GET /user`, `get_user_by_id` for `GET /user/:id`.
/// Ids must be unique; building a document with a repeated one panics.
pub fn operation_id(id: String) -> Doc {
  OperationId(id)
}

pub fn deprecated() -> Doc {
  Deprecated
}

/// A response with a JSON body described by `body`. Pass the same schema to
/// `schema.to_json` when building the response, so they cannot disagree.
pub fn response(status: Int, description: String, body: Schema(a)) -> Doc {
  Reply(status:, description:, body: Some(schema.node(body)))
}

/// A response without a body, such as `204`.
pub fn empty_response(status: Int, description: String) -> Doc {
  Reply(status:, description:, body: None)
}

/// An error response with Howdy's error body, `{"error": "..."}`, as
/// `service.error_response` sends. Endpoints with inputs document their
/// `400`, and those with a body their `422`, without being told.
pub fn error(status: Int, description: String) -> Doc {
  Reply(status:, description:, body: Some(schema.node(error_schema())))
}

/// Require a security scheme declared on the document, such as one added
/// with `openapi.bearer_auth`. Documentation only: enforce it with a guard
/// or middleware.
pub fn security(scheme: String) -> Doc {
  Security(scheme)
}

type ErrorBody {
  ErrorBody(error: String, fields: Option(List(service.FieldError)))
}

fn error_schema() -> Schema(ErrorBody) {
  let field_error =
    {
      use field <- schema.field(
        "field",
        schema.string(),
        fn(e: service.FieldError) { e.field },
      )
      use message <- schema.field(
        "message",
        schema.string(),
        fn(e: service.FieldError) { e.message },
      )
      schema.success(service.FieldError(field:, message:))
    }
    |> schema.named("FieldError")
  {
    use error <- schema.field("error", schema.string(), fn(body: ErrorBody) {
      body.error
    })
    use fields <- schema.optional_field(
      "fields",
      schema.list(field_error),
      fn(body: ErrorBody) { body.fields },
    )
    schema.success(ErrorBody(error:, fields:))
  }
  |> schema.named("Error")
}

// -- Rendering ---------------------------------------------------------------

/// A documented route, ready to go in a document.
@internal
pub type Rendered {
  Rendered(
    path: String,
    method: String,
    operation_id: String,
    operation: Json,
    components: schema.Components,
  )
}

/// Where a route is reached, beyond its own path: how a request selects
/// the version whose controllers it belongs to.
@internal
pub type Mount {
  Mount(
    /// Segments before the route's own, such as `["v2"]`.
    prefix: List(String),
    /// A header naming the version: its name, the version and whether a
    /// request must send it.
    header: Option(#(String, String, Bool)),
    /// The media type of JSON responses, such as
    /// `application/vnd.howdy.v2+json`.
    media_type: String,
  )
}

/// A route outside any version group.
@internal
pub fn unversioned() -> Mount {
  Mount(prefix: [], header: None, media_type: "application/json")
}

/// Render a route added as an endpoint. `Error` for any other route.
@internal
pub fn render(
  route: Route,
  mount: Mount,
  components: schema.Components,
) -> Result(Rendered, Nil) {
  use annotation <- result.map(controller.annotation(route, annotation_key))
  let operation: Operation = from_dynamic(annotation)
  let inputs = case mount.header {
    Some(#(name, version, required)) -> {
      let node = schema.node(schema.enum([#(version, Nil)]))
      [Parameter("header", name, required, node), ..operation.inputs()]
    }
    None -> operation.inputs()
  }
  let docs = operation.docs()
  let path = openapi_path(list.append(mount.prefix, route.segments))
  let method = string.lowercase(http.method_to_string(route.method))

  let declared =
    list.filter_map(inputs, fn(input) {
      case input {
        Parameter(location: "path", name:, ..) -> Ok(name)
        _ -> Error(Nil)
      }
    })
  let captured = path_names(route.segments)
  list.each(declared, fn(name) {
    case list.contains(captured, name) {
      True -> Nil
      False ->
        panic as {
          "howdy/openapi: "
          <> string.uppercase(method)
          <> " "
          <> path
          <> " reads path parameter "
          <> name
          <> ", which its route does not capture"
        }
    }
  })
  let undeclared =
    captured
    |> list.filter(fn(name) { !list.contains(declared, name) })
    |> list.map(fn(name) {
      Parameter("path", name, True, schema.node(schema.string()))
    })
  let inputs = list.append(inputs, undeclared)

  let #(parameters, components) =
    list.fold(inputs, #([], components), fn(acc, input) {
      let #(rendered, components) = acc
      case input {
        Parameter(location:, name:, required:, node:) -> {
          let #(node, components) = schema.render(node, components)
          let parameter =
            json.object([
              #("name", json.string(name)),
              #("in", json.string(location)),
              #("required", json.bool(required)),
              #("schema", node),
            ])
          #([parameter, ..rendered], components)
        }
        Body(..) -> acc
      }
    })
  let parameters = list.reverse(parameters)

  let body =
    list.find_map(inputs, fn(input) {
      case input {
        Body(node:) -> Ok(node)
        Parameter(..) -> Error(Nil)
      }
    })
  let #(request_body, components) = case body {
    Ok(node) -> {
      let #(node, components) = schema.render(node, components)
      #(
        [
          #(
            "requestBody",
            json.object([
              #("required", json.bool(True)),
              #("content", content_of(node, "application/json")),
            ]),
          ),
        ],
        components,
      )
    }
    Error(Nil) -> #([], components)
  }

  let replies =
    list.filter_map(docs, fn(doc) {
      case doc {
        Reply(..) -> Ok(doc)
        _ -> Error(Nil)
      }
    })
  let replies = case replies {
    [] -> [Reply(status: 200, description: "Success", body: None)]
    _ -> replies
  }
  let automatic = case inputs, result.is_ok(body) {
    [], _ -> []
    _, False -> [#(400, "The request is malformed")]
    _, True -> [
      #(400, "The request is malformed"),
      #(422, "The request body failed validation"),
    ]
  }
  let replies =
    list.fold(automatic, replies, fn(replies, extra) {
      let #(status, description) = extra
      case list.any(replies, fn(reply) { status_of(reply) == status }) {
        True -> replies
        False -> list.append(replies, [error(status, description)])
      }
    })
    |> list.sort(fn(a, b) { int.compare(status_of(a), status_of(b)) })
  let #(responses, components) =
    list.fold(replies, #([], components), fn(acc, reply) {
      let #(rendered, components) = acc
      case reply {
        Reply(status:, description:, body:) -> {
          let #(content, components) = case body {
            Some(node) -> {
              let #(node, components) = schema.render(node, components)
              #([#("content", content_of(node, mount.media_type))], components)
            }
            None -> #([], components)
          }
          let response =
            json.object([#("description", json.string(description)), ..content])
          #([#(int.to_string(status), response), ..rendered], components)
        }
        _ -> acc
      }
    })

  let tags =
    list.filter_map(docs, fn(doc) {
      case doc {
        Tag(name) -> Ok(name)
        _ -> Error(Nil)
      }
    })
  let tags = case tags, fixed_segments(route.segments) {
    [], [first, ..] -> [first]
    tags, _ -> tags
  }
  let operation_id =
    list.find_map(docs, fn(doc) {
      case doc {
        OperationId(id) -> Ok(id)
        _ -> Error(Nil)
      }
    })
    |> result.lazy_unwrap(fn() { default_operation_id(method, route.segments) })
  let text = fn(pick: fn(Doc) -> Result(String, Nil), key: String) {
    case list.find_map(docs, pick) {
      Ok(value) -> [#(key, json.string(value))]
      Error(Nil) -> []
    }
  }
  let security =
    list.filter_map(docs, fn(doc) {
      case doc {
        Security(name) ->
          Ok(json.object([#(name, json.array([], json.string))]))
        _ -> Error(Nil)
      }
    })

  let fields =
    list.flatten([
      case tags {
        [] -> []
        _ -> [#("tags", json.array(tags, json.string))]
      },
      text(
        fn(doc) {
          case doc {
            Summary(text) -> Ok(text)
            _ -> Error(Nil)
          }
        },
        "summary",
      ),
      text(
        fn(doc) {
          case doc {
            Description(text) -> Ok(text)
            _ -> Error(Nil)
          }
        },
        "description",
      ),
      [#("operationId", json.string(operation_id))],
      case parameters {
        [] -> []
        _ -> [#("parameters", json.preprocessed_array(parameters))]
      },
      request_body,
      [#("responses", json.object(list.reverse(responses)))],
      case security {
        [] -> []
        _ -> [#("security", json.preprocessed_array(security))]
      },
      case list.contains(docs, Deprecated) {
        True -> [#("deprecated", json.bool(True))]
        False -> []
      },
    ])
  Rendered(
    path:,
    method:,
    operation_id:,
    operation: json.object(fields),
    components:,
  )
}

fn default_operation_id(method: String, segments: List(String)) -> String {
  segments
  |> list.map(fn(segment) {
    case segment {
      ":" <> name | "*" <> name -> "by_" <> name
      _ -> segment
    }
  })
  |> list.prepend(method)
  |> string.join("_")
}

fn status_of(doc: Doc) -> Int {
  case doc {
    Reply(status:, ..) -> status
    _ -> 0
  }
}

fn content_of(node: Json, media_type: String) -> Json {
  json.object([#(media_type, json.object([#("schema", node)]))])
}

/// `["user", ":id"]` as `/user/{id}`.
fn openapi_path(segments: List(String)) -> String {
  "/"
  <> segments
  |> list.map(fn(segment) {
    case segment {
      ":" <> name | "*" <> name -> "{" <> name <> "}"
      _ -> segment
    }
  })
  |> string.join("/")
}

fn path_names(segments: List(String)) -> List(String) {
  list.filter_map(segments, fn(segment) {
    case segment {
      ":" <> name | "*" <> name -> Ok(name)
      _ -> Error(Nil)
    }
  })
}

fn fixed_segments(segments: List(String)) -> List(String) {
  list.filter(segments, fn(segment) {
    !string.starts_with(segment, ":") && !string.starts_with(segment, "*")
  })
}

@external(erlang, "howdy_openapi_ffi", "identity")
fn to_dynamic(value: a) -> Dynamic

@external(erlang, "howdy_openapi_ffi", "identity")
fn from_dynamic(value: Dynamic) -> a
