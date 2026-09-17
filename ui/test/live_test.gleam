import gleam/erlang/process
import gleam/json
import gleam/string
import howdy
import howdy/controller
import howdy/testing
import howdy/ui
import howdy/ui/button
import howdy/ui/live
import lustre
import lustre/element.{text}
import lustre/event
import lustre/server_component

type Msg {
  Increment
}

fn counter() -> lustre.App(Int, Int, Msg) {
  lustre.simple(
    init: fn(start) { start },
    update: fn(count, msg) {
      case msg {
        Increment -> count + 1
      }
    },
    view: fn(count) {
      ui.card([], [
        ui.h2("Count: " <> string.inspect(count)),
        ui.button(button.Primary, [event.on_click(Increment)], [text("+")]),
      ])
    },
  )
}

fn app() -> howdy.App {
  howdy.new()
  |> howdy.controller(
    controller.new("/counter")
    |> controller.get("/", fn(ctx) { live.serve(ctx, counter(), with: 0) }),
  )
}

pub fn socket_route_needs_a_real_connection_test() {
  let res = testing.get("/counter") |> testing.send(app())
  assert res.status == 426
}

pub fn runtime_sends_a_styled_mount_then_patches_test() {
  let assert Ok(runtime) = live.start(counter(), with: 5)
  let inbox = process.new_subject()
  lustre.send(runtime, server_component.register_subject(inbox))

  let assert Ok(mount) = process.receive(inbox, 1000)
  let mount = json.to_string(server_component.client_message_to_json(mount))
  assert string.contains(mount, "Count: 5")
  // The component's own <style> node carries the CSS for the classes its
  // view used into its shadow root, and nothing else.
  assert string.contains(mount, "background: var(--howdy-primary)")
  assert string.contains(mount, "border-radius: var(--howdy-radius-large)")
  assert !string.contains(mount, "::placeholder")

  live.dispatch(runtime, Increment)
  let assert Ok(patch) = process.receive(inbox, 1000)
  let patch = json.to_string(server_component.client_message_to_json(patch))
  assert string.contains(patch, "Count: 6")

  lustre.send(runtime, lustre.shutdown())
}
