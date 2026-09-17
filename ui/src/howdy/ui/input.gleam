//// Form fields.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

pub fn input(attributes: List(Attribute(msg))) -> Element(msg) {
  html.input([class(input_class()), ..attributes])
}

pub fn label(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.label([class(label_class()), ..attributes], children)
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [input_class(), label_class()]
}

pub fn input_class() -> Class {
  css.class([
    css.display("block"),
    css.width(percent(100)),
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    css.background(tokens.surface),
    css.color(tokens.text),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", tokens.radius_medium),
    css.font_family(tokens.font_body),
    css.font_size(rem(1.0)),
    css.placeholder([css.color(tokens.text_muted)]),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
  ])
}

pub fn label_class() -> Class {
  css.class([
    css.display("block"),
    css.margin_("0 0 " <> tokens.space_1),
    css.font_size(rem(0.875)),
    css.font_weight("500"),
    css.color(tokens.text),
  ])
}
