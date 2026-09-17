//// Attach Sketch classes to elements.

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
