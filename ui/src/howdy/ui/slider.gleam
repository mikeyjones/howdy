//// Sliders: pick a number from a range by dragging or with the arrow keys.
////
//// ```gleam
//// slider.slider([attribute.name("volume"), attribute.min("0"), attribute.max("100"), attribute.value("40")])
//// ```
////
//// A slider is the browser's own range input in the theme's primary
//// colour, so it works with a keyboard, a pointer and a form as usual.
//// Label it, and show the value beside it when it matters.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

pub fn slider(attributes: List(Attribute(msg))) -> Element(msg) {
  html.input([class(slider_class()), attribute.type_("range"), ..attributes])
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [slider_class()]
}

pub fn slider_class() -> Class {
  css.class([
    css.display("block"),
    css.width(percent(100)),
    css.margin(rem(0.0)),
    css.property("accent-color", tokens.primary),
    css.cursor("pointer"),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "4px"),
    ]),
    css.disabled([css.property("opacity", "0.5"), css.cursor("not-allowed")]),
  ])
}
