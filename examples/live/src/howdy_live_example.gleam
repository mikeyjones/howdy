//// A themed page with two live components. Run with `gleam run` from
//// `examples/live`, then open http://localhost:8790 in two browser tabs.
//// Or run `gleam dev` for the same app with hot reload.
////
//// The first counter is private to each tab: every socket starts its own
//// runtime. The second is shared: one runtime started at boot, and every
//// tab sees the same number. The theme button switches light and dark
//// without a reload and remembers the choice in a cookie.
////
//// In development the CSS is served from `/assets/ui.css` and linked from
//// the page. `gleam run -m tasks/css` writes the same CSS to a static
//// file for publishing.
////
//// The buttons come from `howdy_live_example/ui/button`, a copy of the
//// built-in made with `gleam run -m howdy/ui add button` and then edited
//// to give every button pill-shaped corners.

import gleam/erlang/process
import gleam/int
import howdy
import howdy/controller.{type Context}
import howdy/cookie
import howdy/ui
import howdy/ui/live
import howdy/ui/page
import howdy/ui/theme
import howdy_live_example/ui/button
import lustre
import lustre/element.{text}
import lustre/event

pub fn main() -> Nil {
  let assert Ok(shared) = live.start(counter("Everyone's count"), with: 0)

  let assert Ok(_) =
    app(shared)
    |> howdy.listening(on: 8790)
    |> howdy.start

  process.sleep_forever()
}

pub fn app(shared: lustre.Runtime(Msg)) -> howdy.App {
  howdy.new()
  |> howdy.controller(pages())
  |> howdy.controller(
    controller.new("/live")
    |> controller.get("/mine", fn(ctx) {
      live.serve(ctx, counter("Your count"), with: 0)
    })
    |> controller.get("/everyone", fn(ctx) { live.serve_shared(ctx, shared) }),
  )
  |> howdy.controller(ui.stylesheet(
    at: "/assets/ui.css",
    themes: theme.default_themes(),
  ))
}

fn pages() {
  controller.new("/")
  |> controller.get("/", fn(ctx: Context) {
    use theme <- cookie.string_or(ctx, "theme", default: "system")

    page.new("Howdy live")
    |> page.stylesheet(at: "/assets/ui.css")
    |> page.theme(theme)
    |> page.live
    |> page.body([
      ui.container([], [
        ui.stack([], [
          ui.row([], [
            ui.h1("Howdy live"),
            button.theme_toggle(
              [text("Toggle theme")],
              from: "light",
              to: "dark",
            ),
          ]),
          ui.p([
            text("Open this page in a second tab. "),
            ui.muted("The first counter is yours; the second is shared."),
          ]),
          live.mount("/live/mine"),
          live.mount("/live/everyone"),
        ]),
      ]),
    ])
    |> page.respond(ctx)
  })
}

// -- The component -----------------------------------------------------------

pub type Msg {
  Increment
  Decrement
  Reset
}

pub fn counter(title: String) -> lustre.App(Int, Int, Msg) {
  lustre.simple(
    init: fn(start) { start },
    update: fn(count, msg) {
      case msg {
        Increment -> count + 1
        Decrement -> count - 1
        Reset -> 0
      }
    },
    view: fn(count) {
      ui.card([], [
        ui.h2(title),
        ui.p([text(int.to_string(count))]),
        ui.row([], [
          button.button(button.Secondary, [event.on_click(Decrement)], [
            text("-"),
          ]),
          button.button(button.Primary, [event.on_click(Increment)], [text("+")]),
          button.button(button.Danger, [event.on_click(Reset)], [text("Reset")]),
        ]),
      ])
    },
  )
}
