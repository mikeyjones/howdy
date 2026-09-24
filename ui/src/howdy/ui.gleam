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
import howdy/ui/accordion
import howdy/ui/alert
import howdy/ui/badge
import howdy/ui/button
import howdy/ui/card
import howdy/ui/checkbox
import howdy/ui/cli
import howdy/ui/dialog
import howdy/ui/field
import howdy/ui/heading
import howdy/ui/input
import howdy/ui/internal/stylesheet
import howdy/ui/layout
import howdy/ui/loading
import howdy/ui/menu
import howdy/ui/popover
import howdy/ui/select
import howdy/ui/style
import howdy/ui/table
import howdy/ui/tabs
import howdy/ui/theme.{type Themes}
import howdy/ui/tooltip
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
    field.classes(),
    checkbox.classes(),
    layout.classes(),
    card.classes(),
    badge.classes(),
    alert.classes(),
    table.classes(),
    loading.classes(),
    dialog.classes(),
    popover.classes(),
    tooltip.classes(),
    menu.classes(),
    tabs.classes(),
    accordion.classes(),
    select.classes(),
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

/// See `howdy/ui/button`. Variants are `button.Primary`, `Secondary`,
/// `Outline`, `Ghost`, `Link` and `Danger`.
pub fn button(
  variant: button.Variant,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  button.button(variant, attributes, children)
}

/// A button of a given size: `button.Small`, `Medium`, `Large` or `Icon`.
pub fn sized_button(
  variant: button.Variant,
  size: button.Size,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  button.sized(variant, size, attributes, children)
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

pub fn textarea(
  attributes: List(Attribute(msg)),
  content: String,
) -> Element(msg) {
  input.textarea(attributes, content)
}

pub fn native_select(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  input.native_select(attributes, children)
}

pub fn label(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  input.label(attributes, children)
}

/// See `howdy/ui/field`.
pub fn field(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  field.field(attributes, children)
}

pub fn field_description(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  field.description(attributes, children)
}

pub fn field_error(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  field.error(attributes, children)
}

pub fn fieldset(
  attributes: List(Attribute(msg)),
  legend legend: List(Element(msg)),
  children children: List(Element(msg)),
) -> Element(msg) {
  field.fieldset(attributes, legend:, children:)
}

/// See `howdy/ui/checkbox`.
pub fn checkbox(attributes: List(Attribute(msg))) -> Element(msg) {
  checkbox.checkbox(attributes)
}

pub fn radio(attributes: List(Attribute(msg))) -> Element(msg) {
  checkbox.radio(attributes)
}

pub fn choice(
  control: Element(msg),
  children: List(Element(msg)),
) -> Element(msg) {
  checkbox.choice(control, children)
}

pub fn radio_group(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  checkbox.radio_group(attributes, children)
}

/// See `howdy/ui/layout`.
pub fn container(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  layout.container(attributes, children)
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

pub fn separator(
  orientation: layout.Orientation,
  attributes: List(Attribute(msg)),
) -> Element(msg) {
  layout.separator(orientation, attributes)
}

/// See `howdy/ui/card`.
pub fn card(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  card.card(attributes, children)
}

pub fn card_header(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  card.header(attributes, children)
}

pub fn card_title(children: List(Element(msg))) -> Element(msg) {
  card.title(children)
}

pub fn card_description(children: List(Element(msg))) -> Element(msg) {
  card.description(children)
}

pub fn card_action(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  card.action(attributes, children)
}

pub fn card_content(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  card.content(attributes, children)
}

pub fn card_footer(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  card.footer(attributes, children)
}

/// See `howdy/ui/badge`.
pub fn badge(
  variant: badge.Variant,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  badge.badge(variant, attributes, children)
}

/// See `howdy/ui/alert`.
pub fn alert(
  variant: alert.Variant,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  alert.alert(variant, attributes, children)
}

pub fn alert_title(children: List(Element(msg))) -> Element(msg) {
  alert.title(children)
}

pub fn alert_description(children: List(Element(msg))) -> Element(msg) {
  alert.description(children)
}

/// See `howdy/ui/table`.
pub fn table(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  table.table(attributes, children)
}

pub fn table_caption(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  table.caption(attributes, children)
}

pub fn table_header(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  table.header(attributes, children)
}

pub fn table_body(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  table.body(attributes, children)
}

pub fn table_footer(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  table.footer(attributes, children)
}

pub fn table_row(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  table.row(attributes, children)
}

pub fn table_head(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  table.head(attributes, children)
}

pub fn table_cell(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  table.cell(attributes, children)
}

/// See `howdy/ui/loading`.
pub fn skeleton(attributes: List(Attribute(msg))) -> Element(msg) {
  loading.skeleton(attributes)
}

pub fn spinner(
  label: String,
  attributes: List(Attribute(msg)),
) -> Element(msg) {
  loading.spinner(label, attributes)
}

/// See `howdy/ui/dialog`.
pub fn dialog(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  dialog.dialog(id, attributes, children)
}

pub fn alert_dialog(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  dialog.alert_dialog(id, attributes, children)
}

pub fn sheet(
  id: String,
  side: dialog.Side,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  dialog.sheet(id, side, attributes, children)
}

pub fn dialog_trigger(id: String) -> List(Attribute(msg)) {
  dialog.trigger(id)
}

pub fn dialog_close(id: String) -> List(Attribute(msg)) {
  dialog.close(id)
}

pub fn dialog_header(children: List(Element(msg))) -> Element(msg) {
  dialog.header(children)
}

pub fn dialog_title(id: String, children: List(Element(msg))) -> Element(msg) {
  dialog.title(id, children)
}

pub fn dialog_description(
  id: String,
  children: List(Element(msg)),
) -> Element(msg) {
  dialog.description(id, children)
}

pub fn dialog_footer(children: List(Element(msg))) -> Element(msg) {
  dialog.footer(children)
}

/// See `howdy/ui/popover`.
pub fn popover(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  popover.popover(id, attributes, children)
}

pub fn popover_trigger(id: String) -> List(Attribute(msg)) {
  popover.trigger(id)
}

pub fn popover_close(id: String) -> List(Attribute(msg)) {
  popover.close(id)
}

/// See `howdy/ui/tooltip`.
pub fn tooltip(id: String, children: List(Element(msg))) -> Element(msg) {
  tooltip.tooltip(id, children)
}

pub fn tooltip_trigger(id: String) -> List(Attribute(msg)) {
  tooltip.trigger(id)
}

/// See `howdy/ui/menu`.
pub fn menu(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  menu.menu(id, attributes, children)
}

pub fn menu_trigger(id: String) -> List(Attribute(msg)) {
  menu.trigger(id)
}

pub fn menu_item(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  menu.item(attributes, children)
}

pub fn menu_link(
  href: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  menu.link(href, attributes, children)
}

pub fn menu_checkbox_item(
  checked: Bool,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  menu.checkbox_item(checked, attributes, children)
}

pub fn menu_label(children: List(Element(msg))) -> Element(msg) {
  menu.label(children)
}

pub fn menu_separator() -> Element(msg) {
  menu.separator()
}

/// See `howdy/ui/tabs`.
pub fn tabs(
  id: String,
  selected selected: String,
  attributes attributes: List(Attribute(msg)),
  tabs items: List(tabs.Tab(msg)),
) -> Element(msg) {
  tabs.tabs(id, selected:, attributes:, tabs: items)
}

pub fn tab(
  value: String,
  attributes: List(Attribute(msg)),
  label label: List(Element(msg)),
  panel panel: List(Element(msg)),
) -> tabs.Tab(msg) {
  tabs.tab(value, attributes, label:, panel:)
}

/// See `howdy/ui/accordion`.
pub fn accordion(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  accordion.accordion(attributes, children)
}

pub fn accordion_item(
  group: String,
  open open: Bool,
  summary summary: List(Element(msg)),
  content content: List(Element(msg)),
) -> Element(msg) {
  accordion.item(group, open:, summary:, content:)
}

pub fn collapsible(
  attributes: List(Attribute(msg)),
  open open: Bool,
  summary summary: List(Element(msg)),
  content content: List(Element(msg)),
) -> Element(msg) {
  accordion.collapsible(attributes, open:, summary:, content:)
}

/// See `howdy/ui/select`. For the browser's own select, see
/// `native_select`.
pub fn select(
  id id: String,
  name name: String,
  value value: String,
  placeholder placeholder: String,
  attributes attributes: List(Attribute(msg)),
  items items: List(select.Item),
) -> Element(msg) {
  select.select(id:, name:, value:, placeholder:, attributes:, items:)
}

pub fn select_item(value: String, label: String) -> select.Item {
  select.item(value, label)
}

pub fn select_group(label: String, items: List(select.Item)) -> select.Item {
  select.group(label, items)
}
