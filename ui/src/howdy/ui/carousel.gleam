//// Carousels: slides side by side, one in view at a time, with previous
//// and next buttons.
////
//// ```gleam
//// carousel.carousel("tour", label: "Product tour", attributes: [], slides: [
////   carousel.slide([ui.card([], [text("One")])]),
////   carousel.slide([ui.card([], [text("Two")])]),
//// ])
//// ```
////
//// The slides scroll natively, snapping to each one, so swiping, a
//// trackpad and the keyboard all work; the buttons scroll by one slide.
//// Each slide is announced as "slide 2 of 5". Nothing moves on its own.

import gleam/int
import gleam/list
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

pub opaque type Slide(msg) {
  Slide(children: List(Element(msg)))
}

pub fn slide(children: List(Element(msg))) -> Slide(msg) {
  Slide(children)
}

pub fn carousel(
  id: String,
  label label: String,
  attributes attributes: List(Attribute(msg)),
  slides slides: List(Slide(msg)),
) -> Element(msg) {
  let count = int.to_string(list.length(slides))
  let viewport = id <> "-slides"
  html.section(
    [
      class(carousel_class()),
      attribute.id(id),
      attribute.aria_label(label),
      attribute.attribute("aria-roledescription", "carousel"),
      attribute.data("howdy-carousel", ""),
      ..attributes
    ],
    [
      html.div(
        [class(viewport_class()), attribute.id(viewport), attribute.tabindex(0)],
        list.index_map(slides, fn(slide, index) {
          html.div(
            [
              class(slide_class()),
              attribute.role("group"),
              attribute.attribute("aria-roledescription", "slide"),
              attribute.aria_label(int.to_string(index + 1) <> " of " <> count),
            ],
            slide.children,
          )
        }),
      ),
      html.div([class(controls_class())], [
        control("previous", "Previous slide", "‹", viewport),
        control("next", "Next slide", "›", viewport),
      ]),
    ],
  )
}

fn control(
  which: String,
  label: String,
  symbol: String,
  viewport: String,
) -> Element(msg) {
  html.button(
    [
      class(control_class()),
      attribute.type_("button"),
      attribute.aria_label(label),
      attribute.aria_controls(viewport),
      attribute.data("howdy-carousel-" <> which, ""),
    ],
    [html.span([attribute.aria_hidden(True)], [text(symbol)])],
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    carousel_class(),
    viewport_class(),
    slide_class(),
    controls_class(),
    control_class(),
  ]
}

pub fn carousel_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.75)),
  ])
}

pub fn viewport_class() -> Class {
  css.class([
    css.display("flex"),
    css.gap(rem(1.0)),
    css.overflow_x("auto"),
    css.property("scroll-snap-type", "x mandatory"),
    css.property("scroll-behavior", "smooth"),
    css.property("overscroll-behavior-x", "contain"),
    css.property("scrollbar-width", "none"),
    css.property("border-radius", tokens.radius_medium),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
  ])
}

pub fn slide_class() -> Class {
  css.class([
    css.property("flex", "0 0 100%"),
    css.property("scroll-snap-align", "start"),
    css.property("min-width", "0"),
  ])
}

pub fn controls_class() -> Class {
  css.class([
    css.display("flex"),
    css.justify_content("flex-end"),
    css.gap(rem(0.5)),
  ])
}

pub fn control_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.property("width", "2.25rem"),
    css.property("height", "2.25rem"),
    css.padding(rem(0.0)),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", "999px"),
    css.background(tokens.surface),
    css.color(tokens.text),
    css.font_size(rem(1.25)),
    css.line_height("1"),
    css.cursor("pointer"),
    css.hover([css.background(tokens.muted)]),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
  ])
}
