//// Progress bars, for work of a known size such as an upload.
////
//// ```gleam
//// progress.progress(label: "Uploading report.pdf", value: 40, max: 100)
//// ```

import gleam/int
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent}

/// A bar filled `value` out of `max`. `label` names it for screen readers.
pub fn progress(
  label label: String,
  value value: Int,
  max max: Int,
) -> Element(msg) {
  let max = int.max(max, 1)
  let value = int.clamp(value, 0, max)
  html.div(
    [
      class(track_class()),
      attribute.role("progressbar"),
      attribute.aria_label(label),
      attribute.attribute("aria-valuemin", "0"),
      attribute.attribute("aria-valuemax", int.to_string(max)),
      attribute.attribute("aria-valuenow", int.to_string(value)),
    ],
    [
      html.div(
        [
          class(bar_class()),
          attribute.style("width", int.to_string(value * 100 / max) <> "%"),
        ],
        [],
      ),
    ],
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [track_class(), bar_class()]
}

pub fn track_class() -> Class {
  css.class([
    css.width(percent(100)),
    css.property("height", "0.5rem"),
    css.overflow("hidden"),
    css.property("border-radius", "999px"),
    css.background(tokens.muted),
  ])
}

pub fn bar_class() -> Class {
  css.class([
    css.height(percent(100)),
    css.property("border-radius", "999px"),
    css.background(tokens.primary),
    css.transition("width 200ms"),
  ])
}
