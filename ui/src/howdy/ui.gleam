//// Ready-made elements that follow the theme.
////
//// Every element here is a Sketch class built from `howdy/ui/theme/tokens`,
//// so it looks right under any theme in `howdy/ui/theme`. Use them in pages
//// and in live views alike:
////
//// ```gleam
//// import howdy/ui
//// import howdy/ui/button.{Primary, Secondary}
//// import lustre/element.{text}
//// import lustre/event
////
//// ui.card([], [
////   ui.h2("Counter"),
////   ui.row([], [
////     ui.button(Secondary, [event.on_click(Decrement)], [text("-")]),
////     ui.button(Primary, [event.on_click(Increment)], [text("+")]),
////   ]),
//// ])
//// ```
////
//// Each component lives in its own module under `howdy/ui`, and this
//// module re-exports them. To make one your own, copy it into your project:
////
//// ```sh
//// gleam run -m howdy/ui add button
//// ```
////
//// That writes `src/<app>/ui/button.gleam`, the same source as the
//// built-in, for you to edit. `gleam run -m howdy/ui list` shows what is
//// available and `gleam run -m howdy/ui diff button` compares your copy
//// with the version this package ships.
////
//// To add a component from scratch, keep the classes in a styles module,
//// build each from tokens, and attach it with `class`:
////
//// ```gleam
//// // src/my_styles.gleam
//// pub fn badge() -> css.Class {
////   css.class([css.background(tokens.primary), css.color(tokens.on_primary)])
//// }
////
//// pub fn classes() -> List(css.Class) {
////   [badge()]
//// }
//// ```
////
//// ```gleam
//// html.span([ui.class(my_styles.badge())], [text(content)])
//// ```
////
//// The `classes` list is what `howdy/ui/export` uses to write the CSS file
//// for a published site.
////
//// ## Where the CSS goes
////
//// Pages embed the CSS they need by default. In development, mount
//// `stylesheet` and link it with `page.stylesheet` to serve it as one file
//// instead:
////
//// ```gleam
//// howdy.new()
//// |> howdy.controller(pages())
//// |> howdy.controller(ui.stylesheet(at: "/assets/ui.css", themes: theme.default_themes()))
//// ```
////
//// To publish, write a static file with `howdy/ui/export` and serve it
//// with `howdy/static`. Live components carry the CSS for their own
//// classes either way, so they are always styled.

import argv
import gleam/http/request
import gleam/http/response
import gleam/list
import howdy/controller.{type Controller}
import howdy/ui/button
import howdy/ui/cli
import howdy/ui/heading
import howdy/ui/input
import howdy/ui/internal/stylesheet
import howdy/ui/layout
import howdy/ui/style
import howdy/ui/theme.{type Themes}
import howdy/ui/typography
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import sketch/css.{type Class}

/// The command line: `gleam run -m howdy/ui list|add|diff`.
pub fn main() -> Nil {
  cli.run(argv.load().arguments)
}

/// Register a Sketch class and use it on an element. The CSS is included
/// by `howdy/ui/page` and `howdy/ui/live`, or by `styles`.
pub fn class(class: Class) -> Attribute(msg) {
  style.class(class)
}

/// A `<style>` element holding the CSS for every class used so far. Build
/// it after the elements it styles. Pages and live views include this for
/// you.
pub fn styles() -> Element(msg) {
  style.styles()
}

/// Every class the built-in components use. `howdy/ui/export` includes
/// these in the file it writes.
pub fn classes() -> List(Class) {
  list.flatten([
    heading.classes(),
    typography.classes(),
    button.classes(),
    input.classes(),
    layout.classes(),
  ])
}

/// A controller for development that serves the theme variables, base
/// styles and every class registered so far as one `text/css` file at
/// `path`. Link it with `page.stylesheet`. It is sent with an ETag and
/// `cache-control: no-cache`, so browsers revalidate on each page load and
/// see new classes as soon as they exist.
///
/// For a published site, write a static file with `howdy/ui/export` and
/// serve it with `howdy/static` instead.
pub fn stylesheet(at path: String, themes themes: Themes) -> Controller {
  controller.new(path)
  |> controller.get("/", fn(ctx) {
    let css = stylesheet.document_css(themes)
    let etag = stylesheet.etag(css)
    case request.get_header(ctx.request, "if-none-match") == Ok(etag) {
      True -> controller.status(ctx, 304)
      False ->
        controller.text(ctx, css)
        |> response.set_header("content-type", "text/css; charset=utf-8")
    }
    |> response.set_header("cache-control", "no-cache")
    |> response.set_header("etag", etag)
  })
}

// -- Components --------------------------------------------------------------
//
// Thin wrappers so labels and docs survive; each lives in its own module.

/// See `howdy/ui/heading`.
pub fn h1(content: String) -> Element(msg) {
  heading.h1(content)
}

pub fn h2(content: String) -> Element(msg) {
  heading.h2(content)
}

pub fn h3(content: String) -> Element(msg) {
  heading.h3(content)
}

/// See `howdy/ui/typography`.
pub fn p(children: List(Element(msg))) -> Element(msg) {
  typography.p(children)
}

pub fn muted(content: String) -> Element(msg) {
  typography.muted(content)
}

pub fn link(href: String, children: List(Element(msg))) -> Element(msg) {
  typography.link(href, children)
}

/// See `howdy/ui/button`. Variants are `button.Primary`, `button.Secondary`
/// and `button.Danger`.
pub fn button(
  variant: button.Variant,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  button.button(variant, attributes, children)
}

pub fn theme_toggle(
  children: List(Element(msg)),
  from a: String,
  to b: String,
) -> Element(msg) {
  button.theme_toggle(children, from: a, to: b)
}

/// See `howdy/ui/input`.
pub fn input(attributes: List(Attribute(msg))) -> Element(msg) {
  input.input(attributes)
}

pub fn label(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  input.label(attributes, children)
}

/// See `howdy/ui/layout`.
pub fn container(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  layout.container(attributes, children)
}

pub fn card(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  layout.card(attributes, children)
}

pub fn stack(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  layout.stack(attributes, children)
}

pub fn row(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  layout.row(attributes, children)
}
