//// Chat: a conversation that keeps to its newest message, messages with an
//// avatar and a header, speech bubbles, reactions and notes.
////
//// ```gleam
//// chat.conversation([attribute.aria_label("Messages")], [
////   chat.note([text("Today")]),
////   chat.message(chat.Incoming, avatar: avatar.initials("GH"), header: [text("Grace · 09:41")], content: [
////     chat.bubble(chat.Incoming, [text("Did the deploy go out?")]),
////   ]),
////   chat.message(chat.Outgoing, avatar: element.none(), header: [], content: [
////     chat.bubble(chat.Outgoing, [text("Ten minutes ago.")]),
////     chat.reactions([chat.reaction("👍", 2, [])]),
////   ]),
//// ])
//// ```
////
//// A conversation stays at its newest message as messages arrive or a reply
//// streams in, and keeps its place when you scroll back to read. It needs no
//// script: it is laid out from the bottom, and the browser anchors the
//// scroll position. It is a `log` for screen readers, so they announce new
//// messages. Give each message an `id` to link to it.

import gleam/int
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

/// Who wrote a message: someone else, or the person reading.
pub type Side {
  Incoming
  Outgoing
}

/// The scrolling list of messages. Size it with a height or by placing it
/// in a flex column; label it with `aria-label`.
pub fn conversation(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(scroller_class()), attribute.tabindex(0), ..attributes], [
    html.div([class(log_class()), attribute.role("log")], children),
  ])
}

/// One message: an avatar beside a header and the content. Pass
/// `element.none()` for no avatar, and `[]` for no header.
pub fn message(
  side: Side,
  avatar avatar: Element(msg),
  header header: List(Element(msg)),
  content content: List(Element(msg)),
) -> Element(msg) {
  let header = case header {
    [] -> element.none()
    _ -> html.div([class(header_class())], header)
  }
  html.article([class(message_class(side))], [
    avatar,
    html.div([class(body_class(side))], [header, ..content]),
  ])
}

/// A speech bubble: filled with the primary colour for your own messages,
/// the muted colour for everyone else's.
pub fn bubble(side: Side, children: List(Element(msg))) -> Element(msg) {
  html.div([class(bubble_class(side))], children)
}

/// A row of reactions under a message.
pub fn reactions(children: List(Element(msg))) -> Element(msg) {
  html.div([class(reactions_class())], children)
}

/// A reaction and how many people chose it. Mark the reader's own with
/// `attribute.aria_pressed("true")`, and add a click handler to toggle it.
pub fn reaction(
  emoji: String,
  count: Int,
  attributes: List(Attribute(msg)),
) -> Element(msg) {
  html.button(
    [class(reaction_class()), attribute.type_("button"), ..attributes],
    [text(emoji <> " " <> int.to_string(count))],
  )
}

/// A line of text between messages, such as a date or "Grace joined".
pub fn note(children: List(Element(msg))) -> Element(msg) {
  html.div([class(note_class())], children)
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    scroller_class(),
    log_class(),
    message_class(Incoming),
    message_class(Outgoing),
    body_class(Incoming),
    body_class(Outgoing),
    header_class(),
    bubble_class(Incoming),
    bubble_class(Outgoing),
    reactions_class(),
    reaction_class(),
    note_class(),
  ]
}

pub fn scroller_class() -> Class {
  css.class([
    css.display("flex"),
    // Laid out from the bottom, so the newest message is in view and the
    // browser keeps it there as content grows.
    css.flex_direction("column-reverse"),
    css.overflow_y("auto"),
    css.property("overscroll-behavior", "contain"),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
  ])
}

pub fn log_class() -> Class {
  css.class([
    // Never squeezed: it is the content the scroller scrolls.
    css.flex_shrink(0.0),
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.75)),
    css.padding(rem(1.0)),
  ])
}

pub fn message_class(side: Side) -> Class {
  let direction = case side {
    Incoming -> "row"
    Outgoing -> "row-reverse"
  }
  css.class([
    css.display("flex"),
    css.flex_direction(direction),
    css.align_items("flex-end"),
    css.gap(rem(0.5)),
    css.property("scroll-margin", "1rem"),
  ])
}

pub fn body_class(side: Side) -> Class {
  let align = case side {
    Incoming -> "flex-start"
    Outgoing -> "flex-end"
  }
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.align_items(align),
    css.gap(rem(0.25)),
    css.property("max-width", "min(36rem, 80%)"),
  ])
}

pub fn header_class() -> Class {
  css.class([
    css.padding_("0 " <> tokens.space_1),
    css.font_size(rem(0.75)),
    css.color(tokens.text_muted),
  ])
}

pub fn bubble_class(side: Side) -> Class {
  let #(background, colour, corner) = case side {
    Incoming -> #(tokens.muted, tokens.text, "border-bottom-left-radius")
    Outgoing -> #(
      tokens.primary,
      tokens.on_primary,
      "border-bottom-right-radius",
    )
  }
  css.class([
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    css.property("border-radius", tokens.radius_large),
    css.property(corner, tokens.radius_small),
    css.background(background),
    css.color(colour),
    css.font_size(rem(0.9375)),
    css.line_height("1.45"),
    css.property("overflow-wrap", "anywhere"),
    css.white_space("pre-wrap"),
    css.max_width(percent(100)),
  ])
}

pub fn reactions_class() -> Class {
  css.class([css.display("flex"), css.flex_wrap("wrap"), css.gap(rem(0.25))])
}

pub fn reaction_class() -> Class {
  css.class([
    css.padding_("0.125rem " <> tokens.space_2),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", "999px"),
    css.background(tokens.surface),
    css.color(tokens.text),
    css.font_size(rem(0.75)),
    css.cursor("pointer"),
    css.hover([css.background(tokens.muted)]),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
    css.selector("[aria-pressed=\"true\"]", [
      css.property("border-color", tokens.primary),
      css.background(tokens.muted),
    ]),
  ])
}

pub fn note_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.gap(rem(0.75)),
    css.font_size(rem(0.75)),
    css.color(tokens.text_muted),
    css.before([
      css.content("\"\""),
      css.property("flex", "1"),
      css.property("border-top", "1px solid " <> tokens.border),
    ]),
    css.after([
      css.content("\"\""),
      css.property("flex", "1"),
      css.property("border-top", "1px solid " <> tokens.border),
    ]),
  ])
}
