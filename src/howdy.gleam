//// howdy is an opinionated web framework on top of ewe.
////
//// ```gleam
//// let assert Ok(_) =
////   howdy.new()
////   |> howdy.controller(user_controller())
////   |> howdy.start
//// ```

import ewe
import gleam/dict
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import howdy/content.{type Content}
import howdy/context.{type Body, Context}
import howdy/controller.{type Controller, type Middleware}
import howdy/router
import howdy/service
import howdy/trace
import howdy/version.{type Group}

/// The howdy framework version. Keep in sync with `gleam.toml`.
pub const version = "2.0.0"

pub opaque type App {
  App(
    controllers: List(Controller),
    middleware: List(Middleware),
    versions: Option(Group),
    bind_address: String,
    port: Int,
    tls: Option(Tls),
  )
}

type Tls {
  CertificateFiles(cert: String, key: String)
  CertificatePem(cert: BitArray, key: BitArray)
}

/// Where a started server is listening. `port` is the one the operating
/// system chose when the app listens on port `0`.
pub type Address {
  Address(ip: String, port: Int)
}

pub fn new() -> App {
  App(
    controllers: [],
    middleware: [],
    versions: None,
    bind_address: "0.0.0.0",
    port: 8787,
    tls: None,
  )
}

/// Set the network interface to listen on. Defaults to `"0.0.0.0"`
/// (all IPv4 interfaces). Use `"127.0.0.1"` for local access only.
/// An invalid address panics when the server starts, as in ewe.
pub fn bind(app: App, to address: String) -> App {
  App(..app, bind_address: address)
}

/// Set the listening port. Defaults to `8787`. Use `0` to let the operating
/// system choose an available port. The last call wins.
pub fn listening(app: App, on port: Int) -> App {
  App(..app, port:)
}

/// Serve HTTPS using PEM-encoded certificate and key files. Browsers only
/// speak HTTP/2 over TLS, so this is also what enables HTTP/2 for them; it is
/// offered through ALPN alongside HTTP/1.1. For in-memory certificates use
/// `tls_pem`. Without TLS, HTTP/2 is still served to clients that open
/// with the HTTP/2 preface, such as `curl --http2-prior-knowledge`.
pub fn tls(app: App, cert cert: String, key key: String) -> App {
  App(..app, tls: Some(CertificateFiles(cert:, key:)))
}

/// Serve HTTPS using a PEM-encoded certificate and key held in memory, such
/// as ones read from a secret store. Otherwise the same as `tls`.
pub fn tls_pem(app: App, cert cert: BitArray, key key: BitArray) -> App {
  App(..app, tls: Some(CertificatePem(cert:, key:)))
}

/// Start the app's HTTP server.
/// Defaults to `0.0.0.0:8787`; override with `bind` and `listening`.
/// Prints a howdy banner with the framework version and bound URL once listening.
///
/// Returns the server's process and the `Address` it is listening on. The
/// server is linked to the calling process; keep it alive with
/// `process.sleep_forever()`. For advanced server configuration or
/// supervision, use `handler` with ewe directly.
///
/// Clients that disconnect while the server is still writing to them, such
/// as a browser tab closed mid WebSocket, are not logged as crashes.
pub fn start(app: App) -> Result(actor.Started(Address), actor.StartError) {
  start_with(app, serve(app))
}

/// Start a server for `app` that answers requests with `handler` instead of
/// the app's own. The address, port and banner come from `app`. This is
/// what development tooling such as `howdy_dev` uses to wrap an app.
pub fn start_with(
  app: App,
  handler: fn(Request(Body)) -> Response(Content),
) -> Result(actor.Started(Address), actor.StartError) {
  quiet_disconnects()
  ewe.new(handler: to_ewe(handler))
  |> ewe.bind(to: app.bind_address)
  |> ewe.listening(on: app.port)
  |> with_tls(app.tls)
  |> ewe.on_start(fn(scheme, address) {
    startup_banner(scheme, to_address(address))
  })
  |> ewe.start
  |> result.map(fn(started) {
    actor.Started(..started, data: to_address(started.data))
  })
}

/// Stop OTP reporting a client that went away mid write as a crashed
/// connection. Installed once per node; other reports are untouched.
@external(erlang, "howdy_ffi", "quiet_disconnects")
fn quiet_disconnects() -> Nil

fn with_tls(builder: ewe.Builder, tls: Option(Tls)) -> ewe.Builder {
  case tls {
    Some(CertificateFiles(cert:, key:)) ->
      ewe.with_tls(builder, ewe.Disk(cert:, key:))
    Some(CertificatePem(cert:, key:)) ->
      ewe.with_tls(builder, ewe.Pem(cert:, key:))
    None -> builder
  }
}

fn to_address(address: ewe.SocketAddress) -> Address {
  case address {
    ewe.TcpSocketAddress(ip_address:, port:) ->
      Address(ip: ewe.ip_address_to_string(ip_address), port:)
    // `bind` only takes network interfaces.
    ewe.UnixSocketAddress(..) ->
      panic as "howdy: the server is listening on a Unix socket"
  }
}

fn startup_banner(scheme: http.Scheme, address: Address) -> Nil {
  let host = case string.contains(address.ip, ":") {
    True -> "[" <> address.ip <> "]"
    False -> address.ip
  }
  let url =
    http.scheme_to_string(scheme)
    <> "://"
    <> host
    <> ":"
    <> int.to_string(address.port)

  io.println("
 _   _                  _
| | | | _____      ____| |_   _
| |_| |/ _ \\ \\ /\\ / / _` | | | |
|  _  | (_) \\ V  V / (_| | |_| |
|_| |_|\\___/ \\_/\\_/ \\__,_|\\__, |
                          |___/

  howdy v" <> version <> "
  Listening on " <> url <> "
")
}

/// Add middleware that runs for every request the app handles, outside any
/// controller or route middleware. The first added is the outermost.
pub fn middleware(app: App, middleware: Middleware) -> App {
  App(..app, middleware: [middleware, ..app.middleware])
}

/// Mount a controller. Controllers are matched in the order they are added.
pub fn controller(app: App, controller: Controller) -> App {
  App(..app, controllers: list.append(app.controllers, [controller]))
}

/// Mount a version group from `howdy/version`. Unversioned controllers are
/// matched first; the group answers whatever they do not. An app has at
/// most one group, so mounting a second panics.
pub fn versions(app: App, group: Group) -> App {
  case app.versions {
    None -> App(..app, versions: Some(group))
    Some(_) -> panic as "howdy: an app can only have one version group"
  }
}

/// Compile routes and middleware into a reusable ewe request handler, for
/// running the app under ewe directly with options `start` does not offer.
/// Pass the result to `ewe.new`; construct it once and reuse it for every
/// request. This is the one part of howdy's API that uses ewe's types.
///
/// To exercise an app without a server, see `howdy/testing`.
pub fn handler(app: App) -> fn(Request(ewe.Connection)) -> Response(ewe.Body) {
  to_ewe(serve(app))
}

fn to_ewe(
  serve: fn(Request(Body)) -> Response(Content),
) -> fn(Request(ewe.Connection)) -> Response(ewe.Body) {
  fn(request: Request(ewe.Connection)) {
    serve(request.set_body(request, context.live(request.body)))
    |> response.map(content.to_ewe)
  }
}

/// The handler for requests whose body has already been wrapped in a
/// `context.Body`. `handler` and `howdy/testing` both build on this.
@internal
pub fn serve(app: App) -> fn(Request(Body)) -> Response(Content) {
  let middleware = list.reverse(app.middleware)
  let routes = router.compile(app.controllers, middleware)
  let versions =
    option.map(app.versions, fn(group) {
      let table =
        version.table(group)
        |> dict.map_values(fn(_, controllers) {
          router.compile(controllers, middleware)
        })
      #(group, table)
    })
  fn(request: Request(Body)) {
    use <- traced(request)
    case router.match_table(routes, request.method, request.path), versions {
      router.NotFound, Some(#(group, table)) -> versioned(group, table, request)
      match, _ -> respond(match, request, None, "")
    }
  }
}

/// Answer the request inside a server span that continues any trace the
/// client started. The span is named after the method until a route
/// matches, then after the method and route, as OpenTelemetry's HTTP
/// conventions ask; the raw path would give every user id its own name.
/// Query strings, headers and bodies are left out, as they can hold secrets.
fn traced(
  request: Request(Body),
  respond: fn() -> Response(Content),
) -> Response(Content) {
  let method = http.method_to_string(request.method)
  trace.new(method)
  |> trace.kind(trace.Server)
  |> trace.continue_from(request.headers)
  |> trace.attributes(request_attributes(request, method))
  |> trace.run(fn() {
    let response = respond()
    trace.set_attributes([
      trace.int("http.response.status_code", response.status),
    ])
    case response.status >= 500 {
      True -> {
        trace.set_attributes([
          trace.string("error.type", int.to_string(response.status)),
        ])
        trace.set_error("HTTP " <> int.to_string(response.status))
      }
      False -> Nil
    }
    response
  })
}

fn request_attributes(
  request: Request(Body),
  method: String,
) -> List(trace.Attribute) {
  let optional = [
    option.map(request.port, trace.int("server.port", _)),
    option.map(context.client_ip(request), trace.string("client.address", _)),
    request.get_header(request, "user-agent")
      |> option.from_result
      |> option.map(trace.string("user_agent.original", _)),
  ]
  [
    trace.string("http.request.method", method),
    trace.string("url.path", request.path),
    trace.string("url.scheme", http.scheme_to_string(request.scheme)),
    trace.string("server.address", request.host),
    ..option.values(optional)
  ]
}

/// Name the request's span after the route that answers it.
fn traced_route(request: Request(Body), route: String) -> Nil {
  case trace.is_recording() {
    True -> {
      rename_span(http.method_to_string(request.method) <> " " <> route)
      trace.set_attributes([trace.string("http.route", route)])
    }
    False -> Nil
  }
}

@external(erlang, "howdy_trace_ffi", "update_name")
fn rename_span(name: String) -> Nil

fn versioned(
  group: Group,
  table: dict.Dict(String, router.Table),
  request: Request(Body),
) -> Response(Content) {
  let response = case version.resolve(group, request) {
    version.Version(name:, path:) -> {
      let assert Ok(routes) = dict.get(table, name)
      // Under the path strategy the version was the first segment; put it
      // back so the traced route reads like the request.
      let prefix = case path == request.path {
        True -> ""
        False -> "/" <> name
      }
      router.match_table(routes, request.method, path)
      |> respond(request, Some(name), prefix)
    }
    version.Missing(message) ->
      service.error_response(
        Context(request:, params: dict.new(), guard: Nil, version: None),
        service.Invalid(message),
      )
    version.NotVersioned -> not_found()
  }
  case version.vary_header(group) {
    Some(header) -> add_vary(response, header)
    None -> response
  }
}

/// Append to an existing `vary` header, since middleware such as
/// `howdy/cors` may already have set one.
fn add_vary(response: Response(Content), header: String) -> Response(Content) {
  case response.get_header(response, "vary") {
    Ok(existing) ->
      response.set_header(response, "vary", existing <> ", " <> header)
    Error(Nil) -> response.set_header(response, "vary", header)
  }
}

fn respond(
  match: router.Match,
  request: Request(Body),
  version: Option(String),
  route_prefix: String,
) -> Response(Content) {
  case match {
    router.Found(handler:, params:, route:) -> {
      traced_route(request, route_prefix <> route)
      handler(Context(request:, params:, guard: Nil, version:))
    }
    router.NotFound -> not_found()
    router.MethodNotAllowed(allowed:) ->
      response.new(405)
      |> response.set_header(
        "allow",
        allowed |> list.map(http.method_to_string) |> string.join(", "),
      )
      |> response.set_body(content.Empty)
  }
}

fn not_found() -> Response(Content) {
  response.new(404)
  |> response.set_body(content.Empty)
}
