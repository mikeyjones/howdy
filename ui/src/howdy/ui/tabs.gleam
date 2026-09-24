//// Tabs: panels of content, one shown at a time, picked from a row of tabs.
////
//// ```gleam
//// tabs.tabs("account", selected: "profile", attributes: [], tabs: [
////   tabs.tab("profile", [], label: [text("Profile")], panel: [profile_form]),
////   tabs.tab("password", [], label: [text("Password")], panel: [password_form]),
//// ])
//// ```
////
//// Clicking a tab shows its panel; the arrow keys, Home and End move
//// between tabs. The browser switches panels itself, so a live view need
//// not handle anything. If it does keep the selected tab in its model,
//// update the model from a click on every tab, through the tab's
//// attributes, so the server's idea of which panel is shown never falls
//// behind the browser's.

import gleam/list
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// One tab and its panel.
pub opaque type Tab(msg) {
  Tab(
    value: String,
    attributes: List(Attribute(msg)),
    label: List(Element(msg)),
    panel: List(Element(msg)),
  )
}

/// A tab. `attributes` go on the tab's button, for example a click handler.
pub fn tab(
  value: String,
  attributes: List(Attribute(msg)),
  label label: List(Element(msg)),
  panel panel: List(Element(msg)),
) -> Tab(msg) {
  Tab(value:, attributes:, label:, panel:)
}

/// The tabs and their panels, showing the panel of the tab whose value is
/// `selected`. `id` must be unique in the document; the tabs' and panels'
/// ids are built from it.
pub fn tabs(
  id: String,
  selected selected: String,
  attributes attributes: List(Attribute(msg)),
  tabs tabs: List(Tab(msg)),
) -> Element(msg) {
  let triggers =
    list.map(tabs, fn(tab) {
      let is_selected = tab.value == selected
      html.button(
        [
          class(tab_class()),
          attribute.type_("button"),
          attribute.role("tab"),
          attribute.id(tab_id(id, tab.value)),
          attribute.aria_controls(panel_id(id, tab.value)),
          attribute.aria_selected(is_selected),
          attribute.tabindex(case is_selected {
            True -> 0
            False -> -1
          }),
          ..tab.attributes
        ],
        tab.label,
      )
    })
  let panels =
    list.map(tabs, fn(tab) {
      html.div(
        [
          class(panel_class()),
          attribute.role("tabpanel"),
          attribute.id(panel_id(id, tab.value)),
          attribute.aria_labelledby(tab_id(id, tab.value)),
          attribute.tabindex(0),
          attribute.hidden(tab.value != selected),
        ],
        tab.panel,
      )
    })
  html.div([attribute.id(id), attribute.data("howdy-tabs", ""), ..attributes], [
    html.div([class(list_class()), attribute.role("tablist")], triggers),
    ..panels
  ])
}

fn tab_id(id: String, value: String) -> String {
  id <> "-tab-" <> value
}

fn panel_id(id: String, value: String) -> String {
  id <> "-panel-" <> value
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [list_class(), tab_class(), panel_class()]
}

pub fn list_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.gap(rem(0.25)),
    css.padding(rem(0.25)),
    css.background(tokens.muted),
    css.property("border-radius", tokens.radius_medium),
    css.property("max-width", "100%"),
    css.overflow_x("auto"),
  ])
}

pub fn tab_class() -> Class {
  css.class([
    css.padding_("0.375rem " <> tokens.space_3),
    css.border("0"),
    css.property("border-radius", tokens.radius_small),
    css.background("transparent"),
    css.color(tokens.text_muted),
    css.font_family(tokens.font_body),
    css.font_size(rem(0.875)),
    css.font_weight("500"),
    css.line_height("1.25"),
    css.white_space("nowrap"),
    css.cursor("pointer"),
    css.transition("background 120ms, color 120ms"),
    css.hover([css.color(tokens.text)]),
    css.selector("[aria-selected=\"true\"]", [
      css.background(tokens.surface),
      css.color(tokens.text),
      css.box_shadow("0 1px 3px rgb(0 0 0 / 0.12)"),
    ]),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
    css.disabled([css.property("opacity", "0.5"), css.cursor("default")]),
  ])
}

pub fn panel_class() -> Class {
  css.class([
    css.margin_(tokens.space_4 <> " 0 0"),
    css.property("border-radius", tokens.radius_small),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
  ])
}
