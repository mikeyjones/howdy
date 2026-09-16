//// Lustre server components over howdy WebSockets.
////
//// A server component is a Lustre app whose `init`, `update` and `view` run
//// on the server. The browser holds a thin client that sends events up and
//// applies DOM patches that come back. howdy already has the socket, so the
//// bridge is one route:
////
//// ```gleam
//// import howdy/ui/live
////
//// controller.new("/counter")
//// |> controller.get("/", fn(ctx) { live.serve(ctx, counter.app(), with: 0) })
//// ```
////
//// and one element in a page rendered with `howdy/ui/page`:
////
//// ```gleam
//// page.new("Counter")
//// |> page.live
//// |> page.body([live.mount("/counter")])
//// |> page.respond(ctx)
//// ```
////
//// The socket route goes through guards and middleware like any other, so
//// authentication works the same way as for `howdy/websocket`: read a cookie
//// or query parameter, since browsers cannot set handshake headers.
////
//// Each connection gets its own runtime, started when the socket opens and
//// shut down when it closes. For one runtime shared by every client, such
//// as a dashboard, use `start` and `serve_shared`.
////
//// Views are styled with `howdy/ui` components automatically. A component
//// carries the CSS for the classes its view uses, so it is styled whether
//// or not the page links a stylesheet.

import ewe
import gleam/erlang/process.{type Subject}
import gleam/http/response.{type Response}
import howdy/controller.{type GuardedContext}
import howdy/ui/internal/stylesheet
import howdy/websocket.{type Builder, type Socket}
import lustre.{type App, type Runtime}
import lustre/element.{type Element}
import lustre/element/html
import lustre/runtime/app as lustre_app
import lustre/server_component.{type ClientMessage}

/// The `<lustre-server-component>` element that connects to `route`. The
/// page must include the client runtime; `page.live` does that.
pub fn mount(route: String) -> Element(msg) {
  server_component.element([server_component.route(route)], [])
}

/// Upgrade the request to a socket running a fresh runtime of `app`,
/// started with `args`. Equivalent to `socket(app, args)` followed by
/// `websocket.upgrade(ctx)`.
pub fn serve(
  ctx: GuardedContext(guarded),
  app: App(args, model, msg),
  with args: args,
) -> Response(ewe.Body) {
  socket(app, args)
  |> websocket.upgrade(ctx)
}

/// The socket description `serve` uses, for adding your own callbacks
/// before upgrading. The socket state is the runtime.
pub fn socket(
  app: App(args, model, msg),
  args: args,
) -> Builder(Runtime(msg), ClientMessage(msg)) {
  websocket.new(fn(socket) {
    let assert Ok(runtime) = start(app, args)
      as "howdy/ui/live: could not start the server component"
    register(runtime, socket)
    runtime
  })
  |> attach
  |> websocket.on_close(fn(_socket, runtime) {
    lustre.send(runtime, lustre.shutdown())
  })
}

/// Start a runtime that outlives any one connection. Every socket served
/// with `serve_shared` sees the same model.
pub fn start(
  app: App(args, model, msg),
  with args: args,
) -> Result(Runtime(msg), lustre.Error) {
  app
  |> styled
  |> lustre.start_server_component(with: args)
}

/// Upgrade the request to a socket attached to a runtime from `start`.
/// Closing the socket detaches it and leaves the runtime running.
pub fn serve_shared(
  ctx: GuardedContext(guarded),
  runtime: Runtime(msg),
) -> Response(ewe.Body) {
  socket_shared(runtime)
  |> websocket.upgrade(ctx)
}

/// The socket description `serve_shared` uses.
pub fn socket_shared(
  runtime: Runtime(msg),
) -> Builder(Runtime(msg), ClientMessage(msg)) {
  websocket.new(fn(socket) {
    register(runtime, socket)
    runtime
  })
  |> attach
  |> websocket.on_close(fn(socket, runtime) {
    lustre.send(runtime, server_component.deregister_subject(inbox(socket)))
  })
}

/// Send a message to a runtime's `update` function from anywhere.
pub fn dispatch(runtime: Runtime(msg), message: msg) -> Nil {
  lustre.send(runtime, lustre.dispatch(message))
}

// -- Internals ---------------------------------------------------------------

fn styled(app: App(args, model, msg)) -> App(args, model, msg) {
  let view = app.view
  lustre_app.App(..app, view: fn(model) {
    // The component renders into a shadow root, so it carries the CSS for
    // exactly the classes its view used. Lustre diffs the style node like
    // any other, so it only travels when the set of classes changes.
    let #(rendered, css) = stylesheet.scoped(fn() { view(model) })
    element.fragment([html.style([], css), rendered])
  })
}

fn inbox(socket: Socket(ClientMessage(msg))) -> Subject(ClientMessage(msg)) {
  websocket.subject(socket)
}

fn register(runtime: Runtime(msg), socket: Socket(ClientMessage(msg))) -> Nil {
  lustre.send(runtime, server_component.register_subject(inbox(socket)))
}

/// Frames from the browser go to the runtime; runtime output goes to the
/// browser. A client that cannot be written to is dropped.
fn attach(
  builder: Builder(Runtime(msg), ClientMessage(msg)),
) -> Builder(Runtime(msg), ClientMessage(msg)) {
  builder
  |> websocket.on_json(
    server_component.runtime_message_decoder(),
    fn(_socket, runtime, message) {
      lustre.send(runtime, message)
      websocket.continue(runtime)
    },
  )
  |> websocket.on_message(fn(socket, runtime, message) {
    case
      websocket.send_json(
        socket,
        server_component.client_message_to_json(message),
      )
    {
      Ok(Nil) -> websocket.continue(runtime)
      Error(_) -> websocket.stop()
    }
  })
}
