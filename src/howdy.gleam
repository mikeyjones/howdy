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
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/string
import howdy/context.{type Body, Context}
import howdy/controller.{type Controller, type Middleware}
import howdy/router
import howdy/service
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
    tls: Option(ewe.Tls),
  )
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
/// `tls_with`. Without TLS, HTTP/2 is still served to clients that open
/// with the HTTP/2 preface, such as `curl --http2-prior-knowledge`.
pub fn tls(app: App, cert cert: String, key key: String) -> App {
  tls_with(app, ewe.Disk(cert:, key:))
}

/// Serve HTTPS from any `ewe.Tls` source, such as `ewe.Pem` for
/// certificates held in memory.
pub fn tls_with(app: App, tls: ewe.Tls) -> App {
  App(..app, tls: Some(tls))
}

/// Start the app's HTTP server, creating fresh process names for each start.
/// Defaults to `0.0.0.0:8787`; override with `bind` and `listening`.
/// Prints a howdy banner with the framework version and bound URL once listening.
///
/// Returns ewe's startup result, including the server supervisor. The server
/// is linked to the calling process; keep it alive with `process.sleep_forever()`.
/// For advanced ewe configuration or supervision, use `handler` with ewe directly.
/// WebSockets over HTTP/2 are enabled; ewe turns them off by default, so
/// pass `websocket: True` in your HTTP/2 options if you go direct.
pub fn start(
  app: App,
) -> Result(actor.Started(static_supervisor.Supervisor), actor.StartError) {
  start_with(app, handler(app))
}

/// Start a server for `app` that answers requests with `handler` instead of
/// the app's own. The address, port and banner come from `app`. This is
/// what development tooling such as `howdy_dev` uses to wrap an app.
pub fn start_with(
  app: App,
  handler: fn(Request(ewe.Connection)) -> Response(ewe.Body),
) -> Result(actor.Started(static_supervisor.Supervisor), actor.StartError) {
  ewe.new(
    listener_name: process.new_name("howdy_listener"),
    connection_factory_name: process.new_name("howdy_connection_factory"),
    handler:,
  )
  |> ewe.bind(to: app.bind_address)
  |> ewe.listening(on: app.port)
  |> ewe.with_http2(
    ewe.Http2Options(..ewe.default_http2_options(), websocket: True),
  )
  |> with_tls(app.tls)
  |> ewe.on_start(startup_banner)
  |> ewe.start
}

fn with_tls(builder: ewe.Builder, tls: Option(ewe.Tls)) -> ewe.Builder {
  case tls {
    Some(tls) -> ewe.with_tls(builder, tls)
    None -> builder
  }
}

fn startup_banner(scheme: http.Scheme, address: ewe.SocketAddress) -> Nil {
  let url = case address {
    ewe.TcpSocketAddress(ip_address:, port:) -> {
      let host = case ip_address {
        ewe.IpV4(..) -> ewe.ip_address_to_string(ip_address)
        ewe.IpV6(..) -> "[" <> ewe.ip_address_to_string(ip_address) <> "]"
      }
      http.scheme_to_string(scheme)
      <> "://"
      <> host
      <> ":"
      <> int.to_string(port)
    }
    ewe.UnixSocketAddress(path:) -> "unix:" <> path
  }

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

/// Compile routes and middleware into a reusable request handler. Pass the
/// result to `ewe.new`; construct it once and reuse it for every request.
///
/// To exercise an app without a server, see `howdy/testing`.
pub fn handler(app: App) -> fn(Request(ewe.Connection)) -> Response(ewe.Body) {
  let serve = serve(app)
  fn(request: Request(ewe.Connection)) {
    serve(request.set_body(request, context.live(request.body)))
  }
}

/// The handler for requests whose body has already been wrapped in a
/// `context.Body`. `handler` and `howdy/testing` both build on this.
@internal
pub fn serve(app: App) -> fn(Request(Body)) -> Response(ewe.Body) {
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
    case router.match_table(routes, request.method, request.path), versions {
      router.NotFound, Some(#(group, table)) -> versioned(group, table, request)
      match, _ -> respond(match, request, None)
    }
  }
}

fn versioned(
  group: Group,
  table: dict.Dict(String, router.Table),
  request: Request(Body),
) -> Response(ewe.Body) {
  let response = case version.resolve(group, request) {
    version.Version(name:, path:) -> {
      let assert Ok(routes) = dict.get(table, name)
      router.match_table(routes, request.method, path)
      |> respond(request, Some(name))
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
fn add_vary(
  response: Response(ewe.Body),
  header: String,
) -> Response(ewe.Body) {
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
) -> Response(ewe.Body) {
  case match {
    router.Found(handler:, params:) ->
      handler(Context(request:, params:, guard: Nil, version:))
    router.NotFound -> not_found()
    router.MethodNotAllowed(allowed:) ->
      response.new(405)
      |> response.set_header(
        "allow",
        allowed |> list.map(http.method_to_string) |> string.join(", "),
      )
      |> response.set_body(ewe.Empty)
  }
}

fn not_found() -> Response(ewe.Body) {
  response.new(404)
  |> response.set_body(ewe.Empty)
}
