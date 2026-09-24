//// Button groups: related buttons joined into one control.
////
//// ```gleam
//// button_group.group(button_group.Horizontal, [attribute.aria_label("Pages")], [
////   button.button(Outline, [], [text("Previous")]),
////   button.button(Outline, [], [text("Next")]),
//// ])
//// ```
////
//// The buttons keep their own variants; the group squares off the corners
//// where they meet and lets their borders overlap.

import howdy/ui/style.{class}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}

pub type Orientation {
  Horizontal
  Vertical
}

pub fn group(
  orientation: Orientation,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [class(group_class(orientation)), attribute.role("group"), ..attributes],
    children,
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [group_class(Horizontal), group_class(Vertical)]
}

pub fn group_class(orientation: Orientation) -> Class {
  let #(direction, joined_start, joined_end, overlap) = case orientation {
    Horizontal -> #(
      "row",
      ["border-top-left-radius", "border-bottom-left-radius"],
      ["border-top-right-radius", "border-bottom-right-radius"],
      "margin-left",
    )
    Vertical -> #(
      "column",
      ["border-top-left-radius", "border-top-right-radius"],
      ["border-bottom-left-radius", "border-bottom-right-radius"],
      "margin-top",
    )
  }
  let square = fn(corners: List(String)) {
    case corners {
      [a, b] -> [css.property(a, "0"), css.property(b, "0")]
      _ -> []
    }
  }
  css.class([
    css.display("inline-flex"),
    css.flex_direction(direction),
    css.selector(" > :not(:first-child)", [
      css.property(overlap, "-1px"),
      ..square(joined_start)
    ]),
    css.selector(" > :not(:last-child)", square(joined_end)),
    // The focused button draws its ring above its neighbours.
    css.selector(" > :focus-visible", [
      css.position("relative"),
      css.z_index(1),
    ]),
  ])
}
