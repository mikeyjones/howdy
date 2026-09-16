//// Containers, cards, stacks and rows.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{px, rem}

/// A centred column with a maximum width and page padding.
pub fn container(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(container_class()), ..attributes], children)
}

/// A raised surface with a border and padding.
pub fn card(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(card_class()), ..attributes], children)
}

/// Children stacked vertically with a gap.
pub fn stack(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(stack_class()), ..attributes], children)
}

/// Children in a row with a gap, wrapping when they run out of room.
pub fn row(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(row_class()), ..attributes], children)
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [container_class(), card_class(), stack_class(), row_class()]
}

pub fn container_class() -> Class {
  css.class([
    css.max_width(px(960)),
    css.margin_("0 auto"),
    css.padding(rem(1.5)),
  ])
}

pub fn card_class() -> Class {
  css.class([
    css.background(tokens.surface),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", tokens.radius_large),
    css.padding(rem(1.5)),
  ])
}

pub fn stack_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(1.0)),
  ])
}

pub fn row_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.align_items("center"),
    css.gap(rem(0.75)),
  ])
}
