//// The API pages: the endpoints of the OpenAPI documents the app serves,
//// and a form on each to call it and see the response.
////
//// Calls go through the app in this process, with `howdy/testing.send`, so
//// they pass through the app's middleware and guards exactly as a request
//// from outside would, but need no network, CORS or CSRF token. To call as
//// a user, the admin issues a session for them with `auth.impersonate` and
//// sends its token as a bearer credential, which `auth.required` accepts
//// without an Origin. The token is kept for later calls, and replaced if
//// the app ever answers `401` to it.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/float
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleam/uri
import howdy/admin/internal/api_spec.{
  type Document, type Operation, type Parameter, ApiKey, Bearer, Other,
}
import howdy/admin/internal/config.{type Api, type Config}
import howdy/admin/internal/layout
import howdy/auth.{type Auth}
import howdy/auth/secret
import howdy/auth/user
import howdy/auth/users
import howdy/content.{type Content}
import howdy/context.{type Body}
import howdy/controller.{type Context, type Controller}
import howdy/form
import howdy/openapi
import howdy/query
import howdy/service
import howdy/testing
import howdy/ui
import howdy/ui/badge
import howdy/ui/button
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

const actor = user.SystemFrom("howdy_admin")

pub fn controller(config: Config, api: Api) -> Controller {
  controller.new(config.prefix)
  |> controller.get("/api", fn(ctx) { index(config, api, ctx) })
  |> controller.get("/api/operation", fn(ctx) {
    operation_page(config, api, ctx, None)
  })
  |> controller.post("/api/operation", fn(ctx) {
    use fields <- form.read(ctx)
    operation_page(config, api, ctx, Some(fields))
  })
}

// -- Documents ---------------------------------------------------------------

/// The documents to offer: one per version when the app has versions, or
/// the one it serves.
fn documents(api: Api) -> List(openapi.Served) {
  case list.filter(api.documents, fn(served) { !served.main }) {
    [] -> api.documents
    versions -> versions
  }
}

fn key(served: openapi.Served) -> String {
  option.unwrap(served.version, "")
}

/// The document asked for by `version`, or the one the app serves at the
/// path given to `openapi.serve`.
fn pick(
  api: Api,
  version: String,
) -> Result(#(openapi.Served, Document), service.Error) {
  let offered = documents(api)
  let main =
    list.find(api.documents, fn(served) { served.main })
    |> result.map(key)
    |> result.unwrap("")
  let wanted = case version {
    "" -> main
    _ -> version
  }
  use served <- result.try(
    list.find(offered, fn(served) { key(served) == wanted })
    |> result.lazy_or(fn() { list.first(offered) })
    |> result.replace_error(service.NotFound("OpenAPI document")),
  )
  use document <- result.map(
    api_spec.parse(served.document)
    |> result.map_error(service.Invalid),
  )
  #(served, document)
}

// -- Index -------------------------------------------------------------------

fn index(config: Config, api: Api, ctx: Context) -> Response(Content) {
  use version <- query.string_or(ctx, "version", default: "")
  case pick(api, version) {
    Error(error) ->
      layout.failure(
        config,
        ctx,
        current: "/api",
        heading: "API",
        error:,
        back: config.path(config, ""),
      )
    Ok(#(served, document)) ->
      layout.page(
        config,
        ctx,
        current: "/api",
        heading: "API",
        live: False,
        content: [
          ui.stack([], [
            versions(config, api, served),
            about(served, document),
            ..list.map(by_tag(document.operations), fn(group) {
              let #(tag, operations) = group
              operations_card(config, served, document, tag, operations)
            })
          ]),
        ],
      )
  }
}

fn versions(config: Config, api: Api, current: openapi.Served) -> Element(msg) {
  case documents(api) {
    [_, _, ..] as offered ->
      ui.row([], [
        ui.muted("Version"),
        ..list.map(offered, fn(served) {
          case key(served) == key(current) {
            True -> ui.badge(badge.Primary, [], [text(key(served))])
            False ->
              ui.link(
                config.path(
                  config,
                  "/api?version=" <> uri.percent_encode(key(served)),
                ),
                [text(key(served))],
              )
          }
        })
      ])
    _ -> element.none()
  }
}

fn about(served: openapi.Served, document: Document) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text(document.title)]),
      ui.card_description([
        text("Version " <> document.version <> " · "),
        ui.link(served.path, [text(served.path)]),
      ]),
    ]),
    case document.description {
      "" -> element.none()
      description -> ui.card_content([], [ui.p([text(description)])])
    },
  ])
}

/// Operations grouped by their first tag, in the order tags first appear.
fn by_tag(operations: List(Operation)) -> List(#(String, List(Operation))) {
  let tag_of = fn(operation: Operation) {
    list.first(operation.tags) |> result.unwrap("Other")
  }
  let tags = operations |> list.map(tag_of) |> list.unique
  list.map(tags, fn(tag) {
    #(tag, list.filter(operations, fn(operation) { tag_of(operation) == tag }))
  })
}

fn operations_card(
  config: Config,
  served: openapi.Served,
  document: Document,
  tag: String,
  operations: List(Operation),
) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [ui.card_title([text(tag)])]),
    ui.card_content([], [
      ui.table([], [
        ui.table_body(
          [],
          list.map(operations, fn(operation) {
            ui.table_row([], [
              ui.table_cell([attribute.style("width", "5rem")], [
                method_badge(operation.method),
              ]),
              ui.table_cell([], [
                ui.link(operation_href(config, served, operation), [
                  code(operation.path),
                ]),
              ]),
              ui.table_cell([], [
                text(operation.summary),
                case operation.deprecated {
                  True -> ui.badge(badge.Outline, [], [text("deprecated")])
                  False -> element.none()
                },
              ]),
              ui.table_cell([attribute.style("text-align", "right")], [
                case api_spec.security_of(document, operation) {
                  [] -> element.none()
                  schemes ->
                    ui.badge(badge.Secondary, [], [
                      text("needs " <> string.join(schemes, ", ")),
                    ])
                },
              ]),
            ])
          }),
        ),
      ]),
    ]),
  ])
}

fn operation_href(
  config: Config,
  served: openapi.Served,
  operation: Operation,
) -> String {
  config.path(config, "/api/operation?")
  <> uri.query_to_string([
    #("version", key(served)),
    #("method", operation.method),
    #("path", operation.path),
  ])
}

// -- One operation -----------------------------------------------------------

fn operation_page(
  config: Config,
  api: Api,
  ctx: Context,
  submitted: Option(form.Form),
) -> Response(Content) {
  use version <- query.string_or(ctx, "version", default: "")
  use method <- query.string(ctx, "method")
  use path <- query.string(ctx, "path")
  let found = {
    use #(served, document) <- result.try(pick(api, version))
    use operation <- result.map(
      list.find(document.operations, fn(operation) {
        operation.method == method && operation.path == path
      })
      |> result.replace_error(service.NotFound("operation")),
    )
    #(served, document, operation)
  }
  case found {
    Error(error) ->
      layout.failure(
        config,
        ctx,
        current: "/api",
        heading: "API",
        error:,
        back: config.path(config, "/api"),
      )
    Ok(#(served, document, operation)) -> {
      let outcome =
        option.map(submitted, call(config, api, ctx, document, operation, _))
      let values = case submitted {
        Some(fields) -> dict.from_list(form.fields(fields))
        None -> defaults(document, operation)
      }
      layout.page(
        config,
        ctx,
        current: "/api",
        heading: string.uppercase(method) <> " " <> path,
        live: False,
        content: [
          ui.stack([], [
            ui.p([
              ui.link(
                config.path(
                  config,
                  "/api?version=" <> uri.percent_encode(key(served)),
                ),
                [text("All endpoints")],
              ),
            ]),
            summary_card(document, operation),
            request_card(config, served, document, operation, values),
            case outcome {
              Some(outcome) -> outcome_card(outcome)
              None -> element.none()
            },
            responses_card(document, operation),
            case operation.body {
              Some(schema) -> schema_card("Request body", document, schema)
              None -> element.none()
            },
          ]),
        ],
      )
    }
  }
}

fn summary_card(document: Document, operation: Operation) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [
      ui.card_title([
        method_badge(operation.method),
        text(" "),
        text(case operation.summary {
          "" -> operation.path
          summary -> summary
        }),
      ]),
      ui.card_description([
        text(string.join(operation.tags, ", ")),
        case operation.id {
          "" -> element.none()
          id -> text(" · " <> id)
        },
      ]),
    ]),
    ui.card_content([], [
      case operation.description {
        "" -> element.none()
        description -> ui.p([text(description)])
      },
      case operation.deprecated {
        True -> ui.p([ui.badge(badge.Outline, [], [text("deprecated")])])
        False -> element.none()
      },
      case api_spec.security_of(document, operation) {
        [] -> ui.p([ui.muted("No authentication documented.")])
        schemes ->
          ui.p([
            ui.muted("Requires " <> string.join(schemes, " or ") <> "."),
          ])
      },
    ]),
  ])
}

/// Starting values: the only value a parameter can take, such as a version
/// header, and an example body from its schema.
fn defaults(document: Document, operation: Operation) -> Dict(String, String) {
  let parameters =
    list.map(operation.parameters, fn(parameter) {
      #(field_name(parameter), api_spec.preset(parameter.schema))
    })
  let body = case operation.body {
    Some(schema) -> [
      #("body", api_spec.pretty(api_spec.example(document, schema))),
    ]
    None -> []
  }
  dict.from_list(list.append(parameters, body))
}

fn field_name(parameter: Parameter) -> String {
  parameter.location <> ":" <> parameter.name
}

fn request_card(
  config: Config,
  served: openapi.Served,
  document: Document,
  operation: Operation,
  values: Dict(String, String),
) -> Element(msg) {
  let value = fn(name) { dict.get(values, name) |> result.unwrap("") }
  let required = api_spec.security_of(document, operation)
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("Try it")]),
      ui.card_description([
        text(
          "Sent through the app in this process, past its middleware and guards.",
        ),
      ]),
    ]),
    ui.card_content([], [
      html.form(
        [
          attribute.method("post"),
          attribute.action(operation_href(config, served, operation)),
        ],
        [
          ui.stack([], [
            identity_field(config, value("as")),
            ..list.flatten([
              list.filter_map(document.schemes, fn(entry) {
                let #(name, scheme) = entry
                case list.contains(required, name) {
                  True ->
                    Ok(scheme_field(name, scheme, value("scheme:" <> name)))
                  False -> Error(Nil)
                }
              }),
              list.map(operation.parameters, fn(parameter) {
                parameter_field(parameter, value(field_name(parameter)))
              }),
              case operation.body {
                Some(_) -> [
                  ui.field([], [
                    ui.label([attribute.for("body")], [text("Body (JSON)")]),
                    ui.textarea(
                      [
                        attribute.id("body"),
                        attribute.name("body"),
                        attribute.rows(12),
                        attribute.style("font-family", "var(--howdy-font-mono)"),
                        attribute.attribute("spellcheck", "false"),
                      ],
                      value("body"),
                    ),
                  ]),
                ]
                None -> []
              },
              [
                ui.row([], [
                  ui.submit_button(button.Primary, [], [text("Send request")]),
                ]),
              ],
            ])
          ]),
        ],
      ),
    ]),
  ])
}

fn identity_field(config: Config, selected: String) -> Element(msg) {
  case config.identity {
    None -> element.none()
    Some(identity) -> {
      let listed = users.list(identity) |> result.unwrap([]) |> list.take(200)
      ui.field([], [
        ui.label([attribute.for("as")], [text("Send as")]),
        ui.native_select([attribute.id("as"), attribute.name("as")], [
          html.option(
            [attribute.value(""), attribute.selected(selected == "")],
            "Nobody (no session)",
          ),
          ..list.map(listed, fn(account) {
            html.option(
              [
                attribute.value(account.id),
                attribute.selected(selected == account.id),
              ],
              account.email,
            )
          })
        ]),
        ui.field_description([], [
          text(
            "Signs in as the user with a session of the admin's own, sent as a bearer token. Guards see a real session.",
          ),
        ]),
      ])
    }
  }
}

fn scheme_field(
  name: String,
  scheme: api_spec.Scheme,
  value: String,
) -> Element(msg) {
  let id = "scheme:" <> name
  let #(label, description) = case scheme {
    Bearer -> #(name <> " token", "Sent as authorization: Bearer <token>.")
    ApiKey(location:, name: key) -> #(
      name,
      "Sent in the " <> key <> " " <> location <> ".",
    )
    Other(kind) -> #(
      name,
      "A " <> kind <> " scheme; the admin cannot send it for you.",
    )
  }
  ui.field([], [
    ui.label([attribute.for(id)], [text(label)]),
    ui.input([attribute.id(id), attribute.name(id), attribute.value(value)]),
    ui.field_description([], [text(description)]),
  ])
}

fn parameter_field(parameter: Parameter, value: String) -> Element(msg) {
  let id = field_name(parameter)
  let kind = case parameter.schema {
    Some(schema) -> api_spec.type_text(schema)
    None -> "string"
  }
  let notes = case parameter.schema {
    Some(schema) -> api_spec.notes(schema)
    None -> ""
  }
  let input = case api_spec.choices(parameter.schema) {
    [] ->
      ui.input([
        attribute.id(id),
        attribute.name(id),
        attribute.value(value),
        attribute.required(parameter.required),
        attribute.placeholder(case api_spec.is_array(parameter.schema) {
          True -> "values, separated by commas"
          False -> kind
        }),
      ])
    choices ->
      ui.native_select([attribute.id(id), attribute.name(id)], [
        html.option([attribute.value("")], ""),
        ..list.map(choices, fn(choice) {
          html.option(
            [attribute.value(choice), attribute.selected(choice == value)],
            choice,
          )
        })
      ])
  }
  ui.field([], [
    ui.label([attribute.for(id)], [
      text(parameter.name),
      case parameter.required {
        True -> text(" *")
        False -> element.none()
      },
    ]),
    input,
    ui.field_description([], [
      text(
        [parameter.location <> " · " <> kind, notes, parameter.description]
        |> list.filter(fn(part) { part != "" })
        |> string.join(" · "),
      ),
    ]),
  ])
}

fn responses_card(document: Document, operation: Operation) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [ui.card_title([text("Responses")])]),
    ui.card_content([], [
      ui.stack([], [
        ui.table([], [
          ui.table_body(
            [],
            list.map(operation.responses, fn(reply) {
              ui.table_row([], [
                ui.table_cell([attribute.style("width", "5rem")], [
                  status_badge(result.unwrap(int.parse(reply.status), 0)),
                ]),
                ui.table_cell([], [text(reply.description)]),
                ui.table_cell([], [
                  case reply.schema {
                    Some(schema) -> code(api_spec.type_text(schema))
                    None -> ui.muted("no body")
                  },
                ]),
                ui.table_cell([], [
                  ui.muted(option.unwrap(reply.media_type, "")),
                ]),
              ])
            }),
          ),
        ]),
        schema_tables(document, operation),
      ]),
    ]),
  ])
}

/// The fields of the named schemas the responses use, once each.
fn schema_tables(document: Document, operation: Operation) -> Element(msg) {
  let names =
    list.filter_map(operation.responses, fn(reply) {
      option.then(reply.schema, fn(schema) {
        case api_spec.reference(schema) {
          Some(name) -> Some(name)
          None -> api_spec.items(schema) |> option.then(api_spec.reference)
        }
      })
      |> option.to_result(Nil)
    })
    |> list.unique
  ui.stack(
    [],
    list.filter_map(names, fn(name) {
      dict.get(document.schemas, name)
      |> result.map(fn(schema) {
        ui.stack([], [ui.h4(name), fields_table(document, schema)])
      })
    }),
  )
}

fn schema_card(
  title: String,
  document: Document,
  schema: Dynamic,
) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text(title)]),
      ui.card_description([code(api_spec.type_text(schema))]),
    ]),
    ui.card_content([], [fields_table(document, schema)]),
  ])
}

fn fields_table(document: Document, schema: Dynamic) -> Element(msg) {
  case api_spec.properties(document, schema) {
    [] -> element.none()
    properties ->
      ui.table([], [
        ui.table_header([], [
          ui.table_row([], [
            ui.table_head([], [text("Field")]),
            ui.table_head([], [text("Type")]),
            ui.table_head([], [text("Notes")]),
          ]),
        ]),
        ui.table_body(
          [],
          list.map(properties, fn(property) {
            let #(name, schema, required) = property
            ui.table_row([], [
              ui.table_cell([], [
                code(name),
                case required {
                  True -> text(" *")
                  False -> element.none()
                },
              ]),
              ui.table_cell([], [text(api_spec.type_text(schema))]),
              ui.table_cell([], [ui.muted(api_spec.notes(schema))]),
            ])
          }),
        ),
      ])
  }
}

// -- Calling -----------------------------------------------------------------

type Outcome {
  Outcome(
    status: Int,
    headers: List(#(String, String)),
    body: String,
    milliseconds: Float,
    as_user: Option(String),
    curl: String,
  )
  Failed(service.Error)
}

fn call(
  config: Config,
  api: Api,
  ctx: Context,
  document: Document,
  operation: Operation,
  fields: form.Form,
) -> Outcome {
  let base = build_request(document, operation, fields)
  let as_user = case config.identity, form.value(fields, "as") {
    Some(identity), id if id != "" -> Some(#(identity, id))
    _, _ -> None
  }
  let result = case as_user {
    None -> Ok(#(base, send(api, base)))
    Some(#(identity, id)) -> {
      use #(token, cached) <- result.try(token_for(identity, id, fresh: False))
      let req = with_bearer(base, token)
      let res = send(api, req)
      case res.1.status, cached {
        401, True -> {
          use #(token, _) <- result.try(token_for(identity, id, fresh: True))
          let req = with_bearer(base, token)
          Ok(#(req, send(api, req)))
        }
        _, _ -> Ok(#(req, res))
      }
    }
  }
  case result {
    Error(error) -> Failed(error)
    Ok(#(req, #(milliseconds, res))) ->
      Outcome(
        status: res.status,
        headers: res.headers,
        body: body_text(res),
        milliseconds:,
        as_user: option.map(as_user, fn(pair) { email_of(pair.0, pair.1) }),
        curl: curl(ctx, req, form.value(fields, "body"), operation),
      )
  }
}

fn email_of(identity: Auth, id: String) -> String {
  users.list(identity)
  |> result.unwrap([])
  |> list.find(fn(account) { account.id == id })
  |> result.map(fn(account) { account.email })
  |> result.unwrap(id)
}

fn build_request(
  document: Document,
  operation: Operation,
  fields: form.Form,
) -> Request(Body) {
  let value = fn(parameter) { form.value(fields, field_name(parameter)) }
  let path =
    list.fold(operation.parameters, operation.path, fn(path, parameter) {
      case parameter.location {
        "path" ->
          string.replace(
            path,
            "{" <> parameter.name <> "}",
            uri.percent_encode(value(parameter)),
          )
        _ -> path
      }
    })
  let pairs =
    list.flat_map(operation.parameters, fn(parameter) {
      case parameter.location, value(parameter) {
        "query", "" -> []
        "query", text ->
          case api_spec.is_array(parameter.schema) {
            True ->
              string.split(text, ",")
              |> list.map(string.trim)
              |> list.map(fn(item) { #(parameter.name, item) })
            False -> [#(parameter.name, text)]
          }
        _, _ -> []
      }
    })
  let method =
    http.parse_method(string.uppercase(operation.method))
    |> result.unwrap(http.Get)
  let req =
    testing.request(method, path)
    |> testing.header("accept", api_spec.accept_for(operation))
  let req = case pairs {
    [] -> req
    _ -> testing.query(req, pairs)
  }
  let req =
    list.fold(operation.parameters, req, fn(req, parameter) {
      case parameter.location, value(parameter) {
        _, "" -> req
        "header", text -> testing.header(req, parameter.name, text)
        "cookie", text -> request.set_cookie(req, parameter.name, text)
        _, _ -> req
      }
    })
  let req =
    list.fold(api_spec.security_of(document, operation), req, fn(req, name) {
      case
        list.key_find(document.schemes, name),
        form.value(fields, "scheme:" <> name)
      {
        _, "" | Error(Nil), _ -> req
        Ok(Bearer), token ->
          testing.header(req, "authorization", "Bearer " <> token)
        Ok(ApiKey(location: "header", name: header)), key ->
          testing.header(req, header, key)
        Ok(ApiKey(location: "cookie", name: cookie)), key ->
          request.set_cookie(req, cookie, key)
        Ok(ApiKey(location: "query", name: parameter)), key ->
          request.set_query(
            req,
            list.append(request.get_query(req) |> result.unwrap([]), [
              #(parameter, key),
            ]),
          )
        Ok(_), _ -> req
      }
    })
  case operation.body, form.value(fields, "body") {
    Some(_), body if body != "" ->
      req
      |> testing.text_body(body)
      |> testing.header("content-type", "application/json")
    _, _ -> req
  }
}

fn with_bearer(req: Request(Body), token: String) -> Request(Body) {
  testing.header(req, "authorization", "Bearer " <> token)
}

/// Run a request through the app, timing it.
fn send(api: Api, req: Request(Body)) -> #(Float, Response(Content)) {
  let started = timestamp.system_time()
  let res = testing.send(req, api.app)
  let taken =
    timestamp.difference(started, timestamp.system_time())
    |> duration.to_seconds
  #(taken *. 1000.0, res)
}

/// A token for `user_id`: the one kept from an earlier call, unless `fresh`,
/// or a new impersonated session's. Also says whether it was kept.
fn token_for(
  identity: Auth,
  user_id: String,
  fresh fresh: Bool,
) -> Result(#(String, Bool), service.Error) {
  case fresh, cached_token(user_id) {
    False, Ok(token) -> Ok(#(token, True))
    _, _ -> {
      use session <- result.map(auth.impersonate(identity, user_id, by: actor))
      let token = secret.reveal(session.token)
      cache_token(user_id, token)
      #(token, False)
    }
  }
}

@external(erlang, "howdy_admin_ffi", "cached_token")
fn cached_token(user_id: String) -> Result(String, Nil)

@external(erlang, "howdy_admin_ffi", "cache_token")
fn cache_token(user_id: String, token: String) -> Nil

fn body_text(res: Response(Content)) -> String {
  case res.body {
    content.Text(text) -> text
    content.Empty -> ""
    content.Bytes(tree) -> {
      let bits = bytes_tree.to_bit_array(tree)
      case bit_array.to_string(bits) {
        Ok(text) -> text
        Error(Nil) ->
          "(" <> int.to_string(bit_array.byte_size(bits)) <> " bytes of binary)"
      }
    }
    content.Native(_) -> "(a file or streamed body, which cannot be shown here)"
  }
}

/// The same request as a curl command against this server.
fn curl(
  ctx: Context,
  req: Request(Body),
  body: String,
  operation: Operation,
) -> String {
  let origin =
    "http://"
    <> ctx.request.host
    <> case ctx.request.port {
      Some(port) -> ":" <> int.to_string(port)
      None -> ""
    }
  let url =
    origin
    <> req.path
    <> case req.query {
      Some(query) -> "?" <> query
      None -> ""
    }
  let headers =
    req.headers
    |> list.filter(fn(header) { header.0 != "host" })
    |> list.map(fn(header) {
      " \\\n  -H " <> shell(header.0 <> ": " <> header.1)
    })
  let data = case operation.body, body {
    Some(_), body if body != "" -> [" \\\n  -d " <> shell(body)]
    _, _ -> []
  }
  "curl -X "
  <> string.uppercase(operation.method)
  <> " "
  <> shell(url)
  <> string.concat(headers)
  <> string.concat(data)
}

fn shell(text: String) -> String {
  "'" <> string.replace(text, "'", "'\\''") <> "'"
}

fn outcome_card(outcome: Outcome) -> Element(msg) {
  case outcome {
    Failed(error) -> layout.problem(error)
    Outcome(status:, headers:, body:, milliseconds:, as_user:, curl:) ->
      ui.card([attribute.id("response")], [
        ui.card_header([], [
          ui.card_title([text("Response "), status_badge(status)]),
          ui.card_description([
            text(float.to_string(float.to_precision(milliseconds, 1)) <> " ms"),
            text(case as_user {
              Some(email) -> " · as " <> email
              None -> " · anonymously"
            }),
          ]),
        ]),
        ui.card_content([], [
          ui.stack([], [
            case body {
              "" -> ui.muted("No body.")
              body -> monospace(api_spec.pretty_text(body))
            },
            ui.table([], [
              ui.table_body(
                [],
                list.map(headers, fn(header) {
                  ui.table_row([], [
                    ui.table_cell([], [code(header.0)]),
                    ui.table_cell([], [text(header.1)]),
                  ])
                }),
              ),
            ]),
            ui.h4("As curl"),
            monospace(curl),
          ]),
        ]),
      ])
  }
}

// -- Small pieces ------------------------------------------------------------

fn method_badge(method: String) -> Element(msg) {
  let variant = case method {
    "get" -> badge.Secondary
    "delete" -> badge.Danger
    _ -> badge.Primary
  }
  ui.badge(variant, [attribute.style("font-family", "var(--howdy-font-mono)")], [
    text(string.uppercase(method)),
  ])
}

fn status_badge(status: Int) -> Element(msg) {
  let variant = case status {
    s if s >= 400 -> badge.Danger
    s if s >= 300 -> badge.Outline
    0 -> badge.Outline
    _ -> badge.Primary
  }
  let label = case status {
    0 -> "default"
    s -> int.to_string(s)
  }
  ui.badge(variant, [], [text(label)])
}

fn code(value: String) -> Element(msg) {
  html.code([attribute.style("font-family", "var(--howdy-font-mono)")], [
    text(value),
  ])
}

fn monospace(value: String) -> Element(msg) {
  html.pre(
    [
      attribute.style("white-space", "pre-wrap"),
      attribute.style("overflow-wrap", "anywhere"),
      attribute.style("font-family", "var(--howdy-font-mono)"),
      attribute.style("font-size", "0.8125rem"),
      attribute.style("margin", "0"),
    ],
    [text(value)],
  )
}
