//// Attach Sketch classes to elements.

import gleam/list
import gleam/string
import howdy/ui/internal/stylesheet
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}

/// Register a Sketch class and use it on an element. The CSS is included
/// by `howdy/ui/page` and `howdy/ui/live`, or by `styles`.
pub fn class(class: Class) -> Attribute(msg) {
  attribute.class(stylesheet.class_name(class))
}

/// A `<style>` element holding the CSS for every class used so far. Build
/// it after the elements it styles. Pages and live views include this for
/// you.
pub fn styles() -> Element(msg) {
  html.style([], stylesheet.css())
}

/// A CSS anchor name derived from an element id, for tying a floating
/// element such as a popover to the element that opens it. Characters that
/// cannot appear in a CSS identifier become `_`.
pub fn anchor_name(id: String) -> String {
  "--howdy-anchor-"
  <> {
    id
    |> string.to_graphemes
    |> list.map(fn(char) {
      case string.contains(identifier_chars, char) {
        True -> char
        False -> "_"
      }
    })
    |> string.concat
  }
}

const identifier_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
