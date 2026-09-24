//// Dropdown menus: a list of actions opened from a button.
////
//// ```gleam
//// ui.button(Outline, menu.trigger("account"), [text("Account")]),
//// menu.menu("account", [], [
////   menu.label([text("Signed in as ada")]),
////   menu.item([event.on_click(OpenProfile)], [text("Profile")]),
////   menu.checkbox_item(model.compact, [event.on_click(ToggleCompact)], [text("Compact view")]),
////   menu.separator(),
////   menu.link("/sign-out", [], [text("Sign out")]),
//// ])
//// ```
////
//// The arrow keys, Home, End and the first letters of an item move between
//// items; Escape, Tab or choosing an item closes the menu and returns focus
//// to the button. The trigger and the menu are tied by id, so both must be
//// in the page or both in one live view.

import howdy/ui/style.{anchor_name, class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// Attributes for the button that opens the menu with this id.
pub fn trigger(id: String) -> List(Attribute(msg)) {
  [
    attribute.attribute("popovertarget", id),
    attribute.aria_haspopup("menu"),
    attribute.data("howdy-menu-trigger", ""),
    attribute.style("anchor-name", anchor_name(id)),
  ]
}

pub fn menu(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [
      class(menu_class()),
      attribute.id(id),
      attribute.popover("auto"),
      attribute.role("menu"),
      attribute.style("position-anchor", anchor_name(id)),
      ..attributes
    ],
    children,
  )
}

/// An action. Disable one with `attribute.aria_disabled(True)`, which
/// keeps it visible and announced but not chosen.
pub fn item(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.button(
    [
      class(item_class()),
      attribute.type_("button"),
      attribute.role("menuitem"),
      attribute.tabindex(-1),
      ..attributes
    ],
    children,
  )
}

/// An item that goes to another page.
pub fn link(
  href: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.a(
    [
      class(item_class()),
      attribute.href(href),
      attribute.role("menuitem"),
      attribute.tabindex(-1),
      ..attributes
    ],
    children,
  )
}

/// An item that turns a setting on or off, with a tick when it is on. The
/// menu does not change `checked` itself: update it when the item is
/// clicked.
pub fn checkbox_item(
  checked: Bool,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.button(
    [
      class(item_class()),
      attribute.type_("button"),
      attribute.role("menuitemcheckbox"),
      attribute.aria_checked(case checked {
        True -> "true"
        False -> "false"
      }),
      attribute.tabindex(-1),
      ..attributes
    ],
    children,
  )
}

/// A heading for the items after it.
pub fn label(children: List(Element(msg))) -> Element(msg) {
  html.div([class(label_class()), attribute.role("presentation")], children)
}

pub fn separator() -> Element(msg) {
  html.div([class(separator_class()), attribute.role("separator")], [])
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [menu_class(), item_class(), label_class(), separator_class()]
}

pub fn menu_class() -> Class {
  css.class([
    css.inset("auto"),
    css.margin_("0.375rem 0"),
    css.property("position-area", "block-end span-inline-end"),
    css.property("position-try-fallbacks", "flip-block, flip-inline"),
    css.property("min-width", "10rem"),
    css.property("max-height", "calc(100vh - 2rem)"),
    css.overflow_y("auto"),
    css.padding(rem(0.25)),
    css.background(tokens.surface),
    css.color(tokens.text),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", tokens.radius_medium),
    css.box_shadow("0 10px 30px -10px rgb(0 0 0 / 0.3)"),
  ])
}

pub fn item_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.gap(rem(0.5)),
    css.width(length.percent(100)),
    css.padding_("0.375rem " <> tokens.space_2),
    css.border("0"),
    css.property("border-radius", tokens.radius_small),
    css.background("transparent"),
    css.color(tokens.text),
    css.font_family(tokens.font_body),
    css.font_size(rem(0.875)),
    css.line_height("1.25"),
    css.text_align("left"),
    css.text_decoration("none"),
    css.cursor("pointer"),
    css.property("user-select", "none"),
    css.outline("none"),
    css.hover([css.background(tokens.muted)]),
    css.focus([css.background(tokens.muted)]),
    css.selector("[aria-disabled=\"true\"]", [
      css.property("opacity", "0.5"),
      css.cursor("default"),
      css.property("pointer-events", "none"),
    ]),
    // A checkbox item keeps room for its tick, so labels line up.
    css.selector("[role=\"menuitemcheckbox\"]", [
      css.property("padding-left", "1.75rem"),
      css.position("relative"),
    ]),
    css.selector("[aria-checked=\"true\"]::before", [
      css.content("\"\""),
      css.position("absolute"),
      css.property("left", "0.7rem"),
      css.property("top", "45%"),
      css.property("width", "0.3rem"),
      css.property("height", "0.55rem"),
      css.property("border-right", "2px solid currentColor"),
      css.property("border-bottom", "2px solid currentColor"),
      css.transform_("translateY(-50%) rotate(45deg)"),
    ]),
  ])
}

pub fn label_class() -> Class {
  css.class([
    css.padding_("0.375rem " <> tokens.space_2),
    css.font_size(rem(0.75)),
    css.font_weight("500"),
    css.color(tokens.text_muted),
  ])
}

pub fn separator_class() -> Class {
  css.class([
    css.height(length.px(1)),
    css.margin_(tokens.space_1 <> " -" <> tokens.space_1),
    css.background(tokens.border),
  ])
}
