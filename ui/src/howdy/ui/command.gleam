//// Command menus and comboboxes: a search box over a list of options that
//// narrows as you type.
////
//// ```gleam
//// command.command("actions", placeholder: "Type a command…", attributes: [], children: [
////   command.group("Suggestions", [
////     command.item([event.on_click(NewInvoice)], [text("New invoice")]),
////     command.item([command.keywords("customer client")], [text("Add contact")]),
////   ]),
////   command.empty([text("No results.")]),
//// ])
//// ```
////
//// Typing hides the options that do not match their text or `keywords`;
//// the arrow keys move through the rest and Enter activates one, as if it
//// were clicked. Focus stays in the search box throughout.
////
//// `dialog` opens a command menu over the page, with a keyboard shortcut
//// such as ⌘K. `combobox` is a select with a search box: choosing an option
//// sets a hidden input, like `howdy/ui/select`.
////
//// Filtering happens in the browser. With too many options to send at
//// once, render the matches from the server instead: listen for `input`
//// on the search box and pass `server_filtered` so the browser leaves the
//// list as it is.

import gleam/list
import gleam/string
import howdy/ui/style.{anchor_name, class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

/// A search box above a list of groups, items and an empty message.
/// `attributes` go on the search box.
pub fn command(
  id: String,
  placeholder placeholder: String,
  attributes attributes: List(Attribute(msg)),
  children children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(command_class()), attribute.data("howdy-command", "")], [
    html.input([
      class(input_class()),
      attribute.type_("text"),
      attribute.id(id),
      attribute.role("combobox"),
      attribute.aria_expanded(True),
      attribute.aria_controls(id <> "-list"),
      attribute.aria_autocomplete("list"),
      attribute.autocomplete("off"),
      attribute.attribute("spellcheck", "false"),
      attribute.placeholder(placeholder),
      ..attributes
    ]),
    html.div(
      [
        class(list_class()),
        attribute.id(id <> "-list"),
        attribute.role("listbox"),
        attribute.aria_label(placeholder),
      ],
      children,
    ),
  ])
}

/// Leave the list as the server renders it instead of filtering it in the
/// browser. Put it in the command's `attributes`.
pub fn server_filtered() -> Attribute(msg) {
  attribute.data("howdy-server-filtered", "")
}

/// Options under a heading. Hidden when none of them match.
pub fn group(heading: String, items: List(Element(msg))) -> Element(msg) {
  html.div(
    [
      class(group_class()),
      attribute.role("group"),
      attribute.aria_label(heading),
    ],
    [
      html.div([class(heading_class()), attribute.aria_hidden(True)], [
        text(heading),
      ]),
      ..items
    ],
  )
}

/// An option. Its click handler runs when it is chosen with the mouse or
/// with Enter. Disable one with `attribute.aria_disabled(True)`.
pub fn item(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [class(item_class()), attribute.role("option"), ..attributes],
    children,
  )
}

/// An option that goes to another page when chosen.
pub fn link(
  href: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.a(
    [
      class(item_class()),
      attribute.role("option"),
      attribute.href(href),
      attribute.tabindex(-1),
      ..attributes
    ],
    children,
  )
}

/// Extra words an item matches, beyond its text.
pub fn keywords(words: String) -> Attribute(msg) {
  attribute.data("keywords", words)
}

/// A line between groups.
pub fn separator() -> Element(msg) {
  html.div([class(separator_class()), attribute.role("separator")], [])
}

/// Shown when nothing matches.
pub fn empty(children: List(Element(msg))) -> Element(msg) {
  html.div(
    [
      class(empty_class()),
      attribute.data("howdy-command-empty", ""),
      attribute.role("presentation"),
      attribute.hidden(True),
    ],
    children,
  )
}

/// A command menu in a dialog. `shortcut` is a letter that opens it with
/// ⌘ on macOS or Ctrl elsewhere; pass `""` for none. Open it with a button
/// too, using `howdy/ui/dialog.trigger`.
pub fn dialog(
  id: String,
  shortcut shortcut: String,
  attributes attributes: List(Attribute(msg)),
  command command: Element(msg),
) -> Element(msg) {
  let shortcut = case shortcut {
    "" -> []
    key -> [attribute.data("howdy-shortcut", string.lowercase(key))]
  }
  html.dialog(
    [
      class(dialog_class()),
      attribute.id(id),
      attribute.attribute("closedby", "any"),
      attribute.aria_label("Command menu"),
      ..list.append(shortcut, attributes)
    ],
    [command],
  )
}

/// A button showing the chosen option, or `placeholder`, that opens a
/// searchable list. Choosing sets the hidden input called `name`. Each
/// option is an `item` with a value, made with `option`.
pub fn combobox(
  id id: String,
  name name: String,
  value value: String,
  label label: String,
  placeholder placeholder: String,
  search search: String,
  options options: List(Element(msg)),
) -> Element(msg) {
  let popover = id <> "-popover"
  let #(shown, mark) = case value {
    "" -> #(placeholder, [attribute.data("placeholder", "")])
    _ -> #(label, [])
  }
  html.div([class(combobox_class()), attribute.data("howdy-select", "")], [
    html.input([
      attribute.type_("hidden"),
      attribute.name(name),
      attribute.value(value),
    ]),
    html.button(
      [
        class(trigger_class()),
        attribute.type_("button"),
        attribute.id(id),
        attribute.attribute("popovertarget", popover),
        attribute.aria_haspopup("listbox"),
        attribute.style("anchor-name", anchor_name(popover)),
        ..mark
      ],
      [html.span([attribute.data("howdy-select-value", "")], [text(shown)])],
    ),
    html.div(
      [
        class(popover_class()),
        attribute.id(popover),
        attribute.popover("auto"),
        attribute.style("position-anchor", anchor_name(popover)),
      ],
      [
        command(
          id <> "-search",
          placeholder: search,
          attributes: [],
          children: options,
        ),
      ],
    ),
  ])
}

/// An option in a combobox. `selected` marks the one whose value is the
/// combobox's `value`.
pub fn option(
  value: String,
  selected selected: Bool,
  children children: List(Element(msg)),
) -> Element(msg) {
  item(
    [attribute.data("value", value), attribute.aria_selected(selected)],
    children,
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    command_class(),
    input_class(),
    list_class(),
    group_class(),
    heading_class(),
    item_class(),
    separator_class(),
    empty_class(),
    dialog_class(),
    combobox_class(),
    trigger_class(),
    popover_class(),
  ]
}

pub fn command_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.width(percent(100)),
    css.background(tokens.surface),
    css.color(tokens.text),
  ])
}

pub fn input_class() -> Class {
  css.class([
    css.width(percent(100)),
    css.padding_(tokens.space_3),
    css.border("0"),
    css.property("border-bottom", "1px solid " <> tokens.border),
    css.background("transparent"),
    css.color(tokens.text),
    css.font_family(tokens.font_body),
    css.font_size(rem(0.875)),
    css.outline("none"),
    css.placeholder([css.color(tokens.text_muted)]),
  ])
}

pub fn list_class() -> Class {
  css.class([
    css.property("max-height", "18rem"),
    css.overflow_y("auto"),
    css.padding(rem(0.25)),
    css.property("scroll-padding", "0.25rem"),
  ])
}

pub fn group_class() -> Class {
  css.class([css.selector("[hidden]", [css.display("none")])])
}

pub fn heading_class() -> Class {
  css.class([
    css.padding_("0.375rem " <> tokens.space_2),
    css.font_size(rem(0.75)),
    css.font_weight("500"),
    css.color(tokens.text_muted),
  ])
}

pub fn item_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.gap(rem(0.5)),
    css.position("relative"),
    css.padding_("0.375rem 2rem 0.375rem " <> tokens.space_2),
    css.property("border-radius", tokens.radius_small),
    css.font_size(rem(0.875)),
    css.color(tokens.text),
    css.text_decoration("none"),
    css.cursor("pointer"),
    css.property("user-select", "none"),
    css.selector("[data-active]", [css.background(tokens.muted)]),
    css.selector("[hidden]", [css.display("none")]),
    css.selector("[aria-disabled=\"true\"]", [
      css.property("opacity", "0.5"),
      css.cursor("default"),
      css.property("pointer-events", "none"),
    ]),
    css.selector("[aria-selected=\"true\"]::after", [
      css.content("\"\""),
      css.position("absolute"),
      css.property("right", "0.75rem"),
      css.property("top", "45%"),
      css.property("width", "0.3rem"),
      css.property("height", "0.55rem"),
      css.property("border-right", "2px solid currentColor"),
      css.property("border-bottom", "2px solid currentColor"),
      css.transform_("translateY(-50%) rotate(45deg)"),
    ]),
  ])
}

pub fn separator_class() -> Class {
  css.class([
    css.height(length.px(1)),
    css.margin_(tokens.space_1 <> " -" <> tokens.space_1),
    css.background(tokens.border),
  ])
}

pub fn empty_class() -> Class {
  css.class([
    css.padding_(tokens.space_6 <> " " <> tokens.space_2),
    css.text_align("center"),
    css.font_size(rem(0.875)),
    css.color(tokens.text_muted),
    css.selector("[hidden]", [css.display("none")]),
  ])
}

pub fn dialog_class() -> Class {
  css.class([
    css.width(percent(100)),
    css.property("max-width", "min(32rem, calc(100% - 2rem))"),
    css.property("margin-top", "15vh"),
    css.padding(rem(0.0)),
    css.overflow("hidden"),
    css.background(tokens.surface),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", tokens.radius_large),
    css.box_shadow("0 20px 50px -12px rgb(0 0 0 / 0.35)"),
    css.backdrop([css.background("rgb(0 0 0 / 0.5)")]),
  ])
}

pub fn combobox_class() -> Class {
  css.class([css.display("block"), css.width(percent(100))])
}

pub fn trigger_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.justify_content("space-between"),
    css.gap(rem(0.5)),
    css.width(percent(100)),
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    css.background(tokens.surface),
    css.color(tokens.text),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", tokens.radius_medium),
    css.font_family(tokens.font_body),
    css.font_size(rem(1.0)),
    css.line_height("1.5"),
    css.text_align("left"),
    css.cursor("pointer"),
    css.selector("[data-placeholder]", [css.color(tokens.text_muted)]),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
    css.after([
      css.content("\"\""),
      css.flex_shrink(0.0),
      css.property("width", "0.45rem"),
      css.property("height", "0.45rem"),
      css.property("border-right", "2px solid " <> tokens.text_muted),
      css.property("border-bottom", "2px solid " <> tokens.text_muted),
      css.transform_("translateY(-25%) rotate(45deg)"),
    ]),
  ])
}

pub fn popover_class() -> Class {
  css.class([
    css.inset("auto"),
    css.margin_("0.375rem 0"),
    css.property("position-area", "block-end span-inline-end"),
    css.property("position-try-fallbacks", "flip-block"),
    css.property("min-width", "anchor-size(width)"),
    css.padding(rem(0.0)),
    css.overflow("hidden"),
    css.background(tokens.surface),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", tokens.radius_medium),
    css.box_shadow("0 10px 30px -10px rgb(0 0 0 / 0.3)"),
  ])
}
