//// Paragraphs, secondary text and links.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// A paragraph.
pub fn p(children: List(Element(msg))) -> Element(msg) {
  html.p([class(paragraph_class())], children)
}

/// Secondary text such as a caption or hint.
pub fn muted(content: String) -> Element(msg) {
  html.span([class(muted_class())], [text(content)])
}

/// A link.
pub fn link(href: String, children: List(Element(msg))) -> Element(msg) {
  html.a([class(link_class()), attribute.href(href)], children)
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [paragraph_class(), muted_class(), link_class()]
}

pub fn paragraph_class() -> Class {
  css.class([css.margin_("0 0 " <> tokens.space_4), css.color(tokens.text)])
}

pub fn muted_class() -> Class {
  css.class([css.color(tokens.text_muted), css.font_size(rem(0.875))])
}

pub fn link_class() -> Class {
  css.class([
    css.color(tokens.primary),
    css.text_decoration("none"),
    css.hover([css.text_decoration("underline")]),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
  ])
}
