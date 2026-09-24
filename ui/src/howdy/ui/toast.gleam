//// Toasts: short notifications in a corner of the screen that go away on
//// their own.
////
//// ```gleam
//// toast.region([], [
////   toast.toast(toast.Info, [], [
////     toast.title([text("Saved")]),
////     toast.description([text("Your changes are live.")]),
////     toast.close([attribute.aria_label("Dismiss")]),
////   ]),
//// ])
//// ```
////
//// Render the region once, on every page or in the live view, and put
//// toasts in it. It is a live region, so a screen reader reads a toast
//// when it appears. A toast fades out after five seconds, or the time set
//// with `duration`; hovering over it or focusing inside it pauses the
//// countdown. `persistent` keeps it until it is closed.
////
//// The countdown is a CSS animation, so it needs no script and works the
//// same for a flash message rendered with a page and a toast a live view
//// adds to its model. A live view that keeps toasts in its model should
//// still remove old ones: a toast that has faded is hidden, not removed.

import gleam/int
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

pub type Variant {
  Info
  Danger
}

/// The corner toasts appear in. Keep it in the page even when it is empty,
/// so a screen reader is already listening when a toast arrives.
pub fn region(
  attributes: List(Attribute(msg)),
  toasts: List(Element(msg)),
) -> Element(msg) {
  html.section(
    [
      class(region_class()),
      attribute.aria_label("Notifications"),
      attribute.aria_live("polite"),
      ..attributes
    ],
    [html.style([], animation_css), ..toasts],
  )
}

pub fn toast(
  variant: Variant,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [
      class(toast_class(variant)),
      attribute.data("howdy-toast", ""),
      ..attributes
    ],
    children,
  )
}

pub fn title(children: List(Element(msg))) -> Element(msg) {
  html.div([class(title_class())], children)
}

pub fn description(children: List(Element(msg))) -> Element(msg) {
  html.div([class(description_class())], children)
}

/// A button in the top corner that hides the toast. Give it an
/// `aria-label`; in a live view, add a click handler to drop the toast
/// from the model too.
pub fn close(attributes: List(Attribute(msg))) -> Element(msg) {
  html.button(
    [
      class(close_class()),
      attribute.type_("button"),
      attribute.data("howdy-toast-close", ""),
      ..attributes
    ],
    [html.span([attribute.aria_hidden(True)], [text("×")])],
  )
}

/// How long the toast stays before fading, in milliseconds.
pub fn duration(milliseconds: Int) -> Attribute(msg) {
  attribute.style("--howdy-toast-duration", int.to_string(milliseconds) <> "ms")
}

/// Keep the toast until it is closed.
pub fn persistent() -> Attribute(msg) {
  attribute.data("persistent", "")
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    region_class(),
    toast_class(Info),
    toast_class(Danger),
    title_class(),
    description_class(),
    close_class(),
  ]
}

pub fn region_class() -> Class {
  css.class([
    css.position("fixed"),
    css.property("right", tokens.space_4),
    css.property("bottom", tokens.space_4),
    css.z_index(50),
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.5)),
    css.property("width", "min(24rem, calc(100vw - 2rem))"),
    css.property("pointer-events", "none"),
  ])
}

pub fn toast_class(variant: Variant) -> Class {
  let colour = case variant {
    Info -> tokens.text
    Danger -> tokens.danger
  }
  css.class([
    css.position("relative"),
    css.display("grid"),
    css.gap(rem(0.25)),
    css.padding_(
      tokens.space_4 <> " 2.5rem " <> tokens.space_4 <> " " <> tokens.space_4,
    ),
    css.background(tokens.surface),
    css.color(colour),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", tokens.radius_medium),
    css.box_shadow("0 10px 30px -10px rgb(0 0 0 / 0.3)"),
    css.font_size(rem(0.875)),
    css.property("pointer-events", "auto"),
    css.selector("[hidden]", [css.display("none")]),
  ])
}

pub fn title_class() -> Class {
  css.class([css.font_weight("600")])
}

pub fn description_class() -> Class {
  css.class([css.color(tokens.text_muted)])
}

pub fn close_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("top", tokens.space_2),
    css.property("right", tokens.space_2),
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.property("width", "1.5rem"),
    css.property("height", "1.5rem"),
    css.padding(rem(0.0)),
    css.border("0"),
    css.property("border-radius", tokens.radius_small),
    css.background("transparent"),
    css.color(tokens.text_muted),
    css.font_size(rem(1.125)),
    css.line_height("1"),
    css.cursor("pointer"),
    css.hover([css.color(tokens.text), css.background(tokens.muted)]),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
  ])
}

// Sketch classes cannot carry `@keyframes`, so they travel with the region.
// Fading out ends with `display: none`, so a faded toast gives up its space.
const animation_css = "@keyframes howdy-toast-in{from{opacity:0;transform:translateY(.5rem)}}@keyframes howdy-toast-out{to{opacity:0;visibility:hidden;display:none}}[data-howdy-toast]{animation:howdy-toast-in .2s ease-out,howdy-toast-out .2s ease-in var(--howdy-toast-duration,5s) forwards}[data-howdy-toast][data-persistent]{animation:howdy-toast-in .2s ease-out}[data-howdy-toast]:hover,[data-howdy-toast]:focus-within{animation-play-state:paused}@media (prefers-reduced-motion:reduce){[data-howdy-toast]{animation-name:none,howdy-toast-out}[data-howdy-toast][data-persistent]{animation:none}}"
