//// One-time code inputs: a box for each digit of a code sent by email or
//// text message.
////
//// ```gleam
//// input_otp.input_otp(6, [attribute.name("code"), attribute.aria_label("Verification code")])
//// ```
////
//// It is one input drawn as a row of boxes, so pasting a whole code, the
//// phone offering one from a text message, and screen readers all work as
//// they do for any text field. Anything but digits is kept out as it is
//// typed or pasted, so a pasted `123 456` becomes `123456`. For codes with
//// letters, pass `attribute.attribute("inputmode", "text")` and your own
//// `pattern`; then only spaces are kept out.

import gleam/int
import gleam/list
import gleam/string
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// An input for a code in groups, such as `grouped([3, 3], ...)` for
/// `123–456`: a dash is drawn between the groups. The code itself has no
/// dash; the input holds only its characters.
pub fn grouped(
  groups: List(Int),
  attributes: List(Attribute(msg)),
) -> Element(msg) {
  let length = int.sum(groups)
  let boundaries =
    groups
    |> list.scan(0, int.add)
    |> list.take(list.length(groups) - 1)
  let dash = fn(after) {
    #(
      "linear-gradient("
        <> tokens.text_muted
        <> ", "
        <> tokens.text_muted
        <> ")",
      "calc(var(--cell) * " <> int.to_string(after) <> " - 0.45rem) 50%",
      "0.4rem 2px",
    )
  }
  let boxes = #(
    "repeating-linear-gradient(to right, "
      <> tokens.muted
      <> " 0 calc(var(--cell) - 0.5rem), transparent calc(var(--cell) - 0.5rem) var(--cell))",
    "0 0",
    "calc(var(--cell) * " <> int.to_string(length) <> ") 100%",
  )
  let layers = list.append(list.map(boundaries, dash), [boxes])
  let join = fn(pick) { layers |> list.map(pick) |> string.join(", ") }
  input_otp(length, [
    attribute.style("background-image", join(fn(layer) { layer.0 })),
    attribute.style("background-position", join(fn(layer) { layer.1 })),
    attribute.style("background-size", join(fn(layer) { layer.2 })),
    ..attributes
  ])
}

/// An input for a code `length` characters long.
pub fn input_otp(
  length: Int,
  attributes: List(Attribute(msg)),
) -> Element(msg) {
  let length = int.max(length, 1)
  html.input([
    class(otp_class()),
    attribute.type_("text"),
    attribute.attribute("inputmode", "numeric"),
    attribute.autocomplete("one-time-code"),
    attribute.pattern("[0-9]*"),
    attribute.attribute("maxlength", int.to_string(length)),
    attribute.attribute("spellcheck", "false"),
    // The behaviour script keeps anything but digits out, typed or pasted.
    attribute.data("howdy-otp", ""),
    // Each box is `--cell` wide; the input is exactly as wide as the boxes.
    attribute.style("--howdy-otp-length", int.to_string(length)),
    ..attributes
  ])
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [otp_class()]
}

// The boxes are a repeating background, one per character; letter spacing
// puts each monospaced character in the middle of its box.
pub fn otp_class() -> Class {
  let cell = "2.75rem"
  let gap = "0.5rem"
  css.class([
    // Codes read left to right in any language.
    css.property("direction", "ltr"),
    css.property("--cell", cell),
    css.property("box-sizing", "content-box"),
    // The text, trailing letter spacing included, is exactly this wide, so
    // a full code never scrolls.
    css.property("width", "calc(var(--cell) * var(--howdy-otp-length))"),
    css.property("height", "3rem"),
    css.padding(rem(0.0)),
    css.property(
      "padding-left",
      "calc((var(--cell) - " <> gap <> " - 1ch) / 2)",
    ),
    css.property("letter-spacing", "calc(var(--cell) - 1ch)"),
    css.border("0"),
    css.property("border-radius", tokens.radius_small),
    css.color(tokens.text),
    css.font_family(tokens.font_mono),
    css.font_size(rem(1.25)),
    css.property("caret-color", tokens.primary),
    css.property(
      "background",
      "repeating-linear-gradient(to right, "
        <> tokens.muted
        <> " 0 calc(var(--cell) - "
        <> gap
        <> "), transparent calc(var(--cell) - "
        <> gap
        <> ") var(--cell))",
    ),
    // Exactly one box per character.
    css.property("background-repeat", "no-repeat"),
    css.property(
      "background-size",
      "calc(var(--cell) * var(--howdy-otp-length)) 100%",
    ),
    css.outline("none"),
    css.focus_visible([
      css.property("box-shadow", "0 0 0 2px " <> tokens.focus),
    ]),
    css.selector("[aria-invalid=\"true\"]", [
      css.property("box-shadow", "0 0 0 2px " <> tokens.danger),
    ]),
    css.disabled([css.property("opacity", "0.5"), css.cursor("not-allowed")]),
  ])
}
