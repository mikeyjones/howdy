//// Small visual effects: a fade at the edges of a scrolling area, and a
//// shimmer over text that is still arriving.
////
//// ```gleam
//// html.div([effects.scroll_fade(), attribute.style("max-height", "20rem")], items)
//// effects.shimmer([text("Thinking…")])
//// ```

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}

/// Scroll vertically, fading content out as it reaches the top and bottom
/// edges. The fade covers padding at rest, so nothing is faded until it is
/// scrolled towards an edge.
pub fn scroll_fade() -> Attribute(msg) {
  class(scroll_fade_class())
}

/// Text that shimmers while it waits for something, such as a reply being
/// written. It stays still for people who ask for reduced motion.
pub fn shimmer(children: List(Element(msg))) -> Element(msg) {
  html.span([class(shimmer_class()), attribute.data("howdy-shimmer", "")], [
    html.style([], shimmer_css),
    ..children
  ])
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [scroll_fade_class(), shimmer_class()]
}

const fade = "1.5rem"

pub fn scroll_fade_class() -> Class {
  let mask =
    "linear-gradient(to bottom, transparent, #000 "
    <> fade
    <> ", #000 calc(100% - "
    <> fade
    <> "), transparent)"
  css.class([
    css.overflow_y("auto"),
    css.property("padding-block", fade),
    css.property("-webkit-mask-image", mask),
    css.property("mask-image", mask),
  ])
}

pub fn shimmer_class() -> Class {
  css.class([
    css.property(
      "background",
      "linear-gradient(90deg, "
        <> tokens.text_muted
        <> " 0%, "
        <> tokens.text
        <> " 50%, "
        <> tokens.text_muted
        <> " 100%)",
    ),
    css.property("background-size", "200% 100%"),
    css.property("-webkit-background-clip", "text"),
    css.property("background-clip", "text"),
    css.color("transparent"),
  ])
}

// Sketch classes cannot carry `@keyframes`, so the animation travels with
// the element.
const shimmer_css = "@keyframes howdy-shimmer{from{background-position:100% 0}to{background-position:-100% 0}}[data-howdy-shimmer]{animation:howdy-shimmer 2s linear infinite}@media (prefers-reduced-motion:reduce){[data-howdy-shimmer]{animation:none}}"
