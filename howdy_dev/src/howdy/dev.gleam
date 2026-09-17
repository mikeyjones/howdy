//// Hot reload for development.
////
//// Put this in `dev/<app>_dev.gleam` and run it with `gleam dev`:
////
//// ```gleam
//// import howdy/dev
//// import my_app
////
//// pub fn main() {
////   dev.start(my_app.app)
//// }
//// ```
////
//// where `my_app.app` is the function that builds your `howdy.App`. Pass
//// it by name rather than calling it: the server rebuilds the app from it
//// for every request, so a reloaded module is used at once.
////
//// While it runs, every change under `src` triggers `gleam build`. If the
//// build succeeds the changed modules are loaded into the running VM and
//// every open page reloads. If it fails the compiler output appears in the
//// terminal and over the page, and the old code keeps serving.
////
//// ## Staying out of production
////
//// `howdy_dev` is a dev dependency and the entry point lives in `dev/`.
//// `gleam export erlang-shipment` includes neither, so a deployed app has
//// no reload code in it. `gleam run` starts `src/<app>.gleam` as usual.
////
//// ## Limits
////
//// Processes started once in `main`, such as a shared live runtime, keep
//// running the code they were started with. They are ended when that code
//// is purged, two reloads later. Restart `gleam dev` after changing them.
//// Changes to `dev/`, `test/`, `gleam.toml` or dependencies also need a
//// restart. Files are polled four times a second, so a change is noticed
//// within a quarter of a second.

import ewe
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/string
import howdy.{type App}
import howdy/dev/internal/reload
import howdy/dev/internal/watch

/// A development server under construction.
pub opaque type Dev {
  Dev(
    build: fn() -> App,
    watch: List(String),
    interval: Int,
    address: String,
    hosts: List(String),
  )
}

/// Describe a development server for the app `build` makes. Watches `src`.
pub fn new(build: fn() -> App) -> Dev {
  Dev(build:, watch: ["src"], interval: 250, address: "127.0.0.1", hosts: [
    "localhost",
    "127.0.0.1",
    "[::1]",
  ])
}

/// Override the development listener's loopback default. Network exposure
/// is explicit: also list the hostname/IP browsers use with `allow_hosts`.
pub fn bind(dev: Dev, to address: String) -> Dev {
  Dev(..dev, address:)
}

/// Exact request hostnames (without port) allowed to read development pages
/// and connect to reload. This prevents hostile DNS-rebinding hosts from
/// obtaining the reload token. Include brackets for IPv6, e.g. `[::1]`.
pub fn allow_hosts(dev: Dev, hosts: List(String)) -> Dev {
  let assert True =
    list.all(hosts, fn(host) {
      host != "" && !string.contains(host, "*") && !string.contains(host, "/")
    })
    as "howdy/dev: allow_hosts requires exact hostnames, not URLs or wildcards"
  Dev(..dev, hosts:)
}

/// Watch another directory as well, such as `priv/static` for assets that
/// pages should reload for even though nothing compiles.
pub fn watch(dev: Dev, directory: String) -> Dev {
  Dev(..dev, watch: list.append(dev.watch, [directory]))
}

/// How often to look for changes, in milliseconds. Defaults to 250.
pub fn interval(dev: Dev, milliseconds: Int) -> Dev {
  Dev(..dev, interval: milliseconds)
}

/// `new(build) |> start`.
pub fn start(
  build: fn() -> App,
) -> Result(actor.Started(static_supervisor.Supervisor), actor.StartError) {
  new(build) |> run
}

/// Start the server and the file watcher. Returns like `howdy.start`; keep
/// the calling process alive with `process.sleep_forever()`.
pub fn run(
  dev: Dev,
) -> Result(actor.Started(static_supervisor.Supervisor), actor.StartError) {
  let session = reload.new(dev.hosts)
  let handler = fn(request: Request(ewe.Connection)) {
    case reload.allowed_host(session, request.host) {
      False -> reload.forbidden()
      True -> {
        let handle = wrap_session(dev.build, session) |> howdy.handler
        handle(request)
      }
    }
  }
  let started =
    howdy.start_with(dev.build() |> howdy.bind(dev.address), handler)
  case started {
    Ok(_) -> {
      process.spawn(fn() { loop(dev, session, watch.snapshot(dev.watch)) })
      Nil
    }
    Error(_) -> Nil
  }
  started
}

/// The application handler `run` serves, for tests: the app plus the
/// reload socket and script.
@internal
pub fn wrap(build: fn() -> App) -> App {
  wrap_session(build, reload.new(["localhost", "127.0.0.1", "[::1]"]))
}

fn wrap_session(build: fn() -> App, session: reload.Session) -> App {
  build()
  |> howdy.middleware(reload.inject(session))
  |> howdy.controller(reload.controller(session))
}

fn loop(dev: Dev, session: reload.Session, before: watch.Snapshot) -> Nil {
  process.sleep(dev.interval)
  let after = watch.snapshot(dev.watch)
  case watch.changed(before, after) {
    [] -> loop(dev, session, before)
    changed -> {
      // Let an editor finish writing before building.
      process.sleep(50)
      let after = watch.snapshot(dev.watch)
      rebuild(session, changed)
      loop(dev, session, after)
    }
  }
}

@external(erlang, "howdy_dev_ffi", "build")
fn build_project() -> #(Int, String)

@external(erlang, "howdy_dev_ffi", "reload_modules")
fn reload_modules() -> List(String)

fn rebuild(session: reload.Session, changed: List(String)) -> Nil {
  io.println("howdy_dev: " <> string.join(changed, ", ") <> " changed")
  case build_project() {
    #(0, output) -> {
      print_build_output(output)
      let modules = reload_modules()
      io.println(
        "howdy_dev: reloaded "
        <> int.to_string(list.length(modules))
        <> " module(s), refreshing pages",
      )
      reload.reload_all(session)
    }
    #(_, output) -> {
      print_build_output(output)
      io.println("howdy_dev: build failed, still serving the previous code")
      reload.show_error(session, output)
    }
  }
}

fn print_build_output(output: String) -> Nil {
  case string.trim(output) {
    "" -> Nil
    text -> io.println(text)
  }
}
