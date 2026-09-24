//// One-time code inputs: a box for each digit of a code sent by email or
//// text message.
////
//// ```gleam
//// input_otp.input_otp(6, [attribute.name("code"), attribute.aria_label("Verification code")])
//// ```
////
//// It is one input drawn as a row of boxes, so pasting a whole code, the
//// phone offering one from a text message, and screen readers all work as
//// they do for any text field. It accepts digits only; for letters too,
//// pass `attribute.attribute("inputmode", "text")` and your own `pattern`.

import gleam/int
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

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
