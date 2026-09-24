//// Calendars and date pickers.
////
//// ```gleam
//// calendar.new("due", year: 2026, month: 9)
//// |> calendar.selected(Some(calendar.Date(2026, 9, 24)))
//// |> calendar.today(calendar.Date(2026, 9, 24))
//// |> calendar.disabled(fn(date) { calendar.weekday(date) >= 6 })
//// |> calendar.navigation(
////   previous: [event.on_click(PreviousMonth)],
////   next: [event.on_click(NextMonth)],
//// )
//// |> calendar.name("due")
//// |> calendar.view
//// ```
////
//// A calendar shows one month. Clicking a day selects it; the arrow keys
//// move a day or a week, Home and End go to the ends of the week, and Page
//// Up and Page Down press the previous and next month buttons. Selecting
//// a day sets the hidden input called `name`, as `YYYY-MM-DD`, so it
//// submits with a form and a live view hears it with `event.on_change`.
////
//// Changing month is the server's job: `navigation` takes the attributes
//// of the previous and next buttons, such as click handlers in a live
//// view. On a page without a live view, a native `<input type="date">`
//// usually serves better.
////
//// `picker` puts the calendar in a popover behind a button that shows the
//// chosen date.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order}
import gleam/string
import howdy/ui/style.{anchor_name, class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

/// A day in the proleptic Gregorian calendar. Months and days count from 1.
pub type Date {
  Date(year: Int, month: Int, day: Int)
}

/// A calendar under construction.
pub opaque type Calendar(msg) {
  Calendar(
    id: String,
    year: Int,
    month: Int,
    selected: Option(Date),
    today: Option(Date),
    disabled: fn(Date) -> Bool,
    monday_first: Bool,
    previous: List(Attribute(msg)),
    next: List(Attribute(msg)),
    name: Option(String),
  )
}

/// A calendar showing `month` of `year`. `id` must be unique in the
/// document.
pub fn new(id: String, year year: Int, month month: Int) -> Calendar(msg) {
  Calendar(
    id:,
    year:,
    month:,
    selected: None,
    today: None,
    disabled: fn(_) { False },
    monday_first: True,
    previous: [],
    next: [],
    name: None,
  )
}

/// The selected day, if there is one.
pub fn selected(calendar: Calendar(msg), date: Option(Date)) -> Calendar(msg) {
  Calendar(..calendar, selected: date)
}

/// Today, which is marked. The server's today may not be the user's, so
/// pass the date in the user's time zone when you know it.
pub fn today(calendar: Calendar(msg), date: Date) -> Calendar(msg) {
  Calendar(..calendar, today: Some(date))
}

/// Days that cannot be chosen, such as those in the past.
pub fn disabled(
  calendar: Calendar(msg),
  disabled: fn(Date) -> Bool,
) -> Calendar(msg) {
  Calendar(..calendar, disabled:)
}

/// Start weeks on Sunday instead of Monday.
pub fn sunday_first(calendar: Calendar(msg)) -> Calendar(msg) {
  Calendar(..calendar, monday_first: False)
}

/// Show previous and next month buttons with these attributes.
pub fn navigation(
  calendar: Calendar(msg),
  previous previous: List(Attribute(msg)),
  next next: List(Attribute(msg)),
) -> Calendar(msg) {
  Calendar(..calendar, previous:, next:)
}

/// Keep the selected day in a hidden input with this name.
pub fn name(calendar: Calendar(msg), name: String) -> Calendar(msg) {
  Calendar(..calendar, name: Some(name))
}

/// The calendar on its own.
pub fn view(calendar: Calendar(msg)) -> Element(msg) {
  let input = case calendar.name {
    Some(name) -> [hidden_input(name, calendar.selected)]
    None -> []
  }
  html.div(
    [class(root_class()), attribute.data("howdy-calendar", "")],
    list.append(input, [month(calendar)]),
  )
}

/// A button showing the selected day, or `placeholder`, that opens the
/// calendar in a popover. Choosing a day closes it. Give the calendar a
/// `name` so the choice is kept.
pub fn picker(
  calendar: Calendar(msg),
  placeholder placeholder: String,
) -> Element(msg) {
  let popover = calendar.id <> "-popover"
  let #(label, mark) = case calendar.selected {
    Some(date) -> #(long_date(date), [])
    None -> #(placeholder, [attribute.data("placeholder", "")])
  }
  let input = case calendar.name {
    Some(name) -> [hidden_input(name, calendar.selected)]
    None -> []
  }
  html.div(
    [class(picker_class()), attribute.data("howdy-select", "")],
    list.append(input, [
      html.button(
        [
          class(trigger_class()),
          attribute.type_("button"),
          attribute.id(calendar.id),
          attribute.attribute("popovertarget", popover),
          attribute.aria_haspopup("dialog"),
          attribute.style("anchor-name", anchor_name(popover)),
          ..mark
        ],
        [html.span([attribute.data("howdy-select-value", "")], [text(label)])],
      ),
      html.div(
        [
          class(popover_class()),
          attribute.id(popover),
          attribute.popover("auto"),
          attribute.role("dialog"),
          attribute.aria_label("Choose a date"),
          attribute.style("position-anchor", anchor_name(popover)),
        ],
        [
          html.div([class(root_class()), attribute.data("howdy-calendar", "")], [
            month(Calendar(..calendar, id: calendar.id <> "-calendar")),
          ]),
        ],
      ),
    ]),
  )
}

fn hidden_input(name: String, selected: Option(Date)) -> Element(msg) {
  html.input([
    attribute.type_("hidden"),
    attribute.name(name),
    attribute.value(case selected {
      Some(date) -> to_iso(date)
      None -> ""
    }),
  ])
}

fn month(calendar: Calendar(msg)) -> Element(msg) {
  let caption = calendar.id <> "-caption"
  let title = month_name(calendar.month) <> " " <> int.to_string(calendar.year)
  let nav = case calendar.previous, calendar.next {
    [], [] -> []
    previous, next -> [
      nav_button(previous, "Previous month", "‹", "previous"),
      nav_button(next, "Next month", "›", "next"),
    ]
  }
  let weekdays = case calendar.monday_first {
    True -> [1, 2, 3, 4, 5, 6, 7]
    False -> [7, 1, 2, 3, 4, 5, 6]
  }
  html.div([], [
    html.div([class(heading_class())], [
      html.div(
        [
          class(caption_class()),
          attribute.id(caption),
          attribute.aria_live("polite"),
        ],
        [text(title)],
      ),
      html.div([class(nav_class())], nav),
    ]),
    html.table(
      [
        class(grid_class()),
        attribute.role("grid"),
        attribute.aria_labelledby(caption),
      ],
      [
        html.thead([], [
          html.tr(
            [],
            list.map(weekdays, fn(day) {
              html.th(
                [
                  class(weekday_class()),
                  attribute.attribute("scope", "col"),
                  attribute.attribute("abbr", weekday_name(day)),
                ],
                [text(string.slice(weekday_name(day), 0, 2))],
              )
            }),
          ),
        ]),
        html.tbody([], list.map(weeks(calendar), week(calendar, _))),
      ],
    ),
  ])
}

fn nav_button(
  attributes: List(Attribute(msg)),
  label: String,
  symbol: String,
  which: String,
) -> Element(msg) {
  html.button(
    [
      class(nav_button_class()),
      attribute.type_("button"),
      attribute.aria_label(label),
      attribute.data("howdy-calendar-" <> which, ""),
      ..attributes
    ],
    [html.span([attribute.aria_hidden(True)], [text(symbol)])],
  )
}

/// The days shown: whole weeks from the one holding the 1st to the one
/// holding the last day of the month.
fn weeks(calendar: Calendar(msg)) -> List(List(Date)) {
  let first = Date(calendar.year, calendar.month, 1)
  let offset = case calendar.monday_first {
    True -> weekday(first) - 1
    False -> weekday(first) % 7
  }
  let start = add_days(first, -offset)
  let length = offset + days_in_month(calendar.year, calendar.month)
  let count = { length + 6 } / 7
  list.repeat(Nil, count * 7)
  |> list.index_map(fn(_, index) { add_days(start, index) })
  |> list.sized_chunk(7)
}

fn week(calendar: Calendar(msg), days: List(Date)) -> Element(msg) {
  // One day is in the tab order: the selected one, else today, else the
  // first of the month.
  let focus = case calendar.selected, calendar.today {
    Some(date), _
      if date.month == calendar.month && date.year == calendar.year
    -> date
    _, Some(date)
      if date.month == calendar.month && date.year == calendar.year
    -> date
    _, _ -> Date(calendar.year, calendar.month, 1)
  }
  html.tr(
    [],
    list.map(days, fn(date) {
      let outside = date.month != calendar.month
      let flags =
        list.flatten([
          case Some(date) == calendar.selected {
            True -> [attribute.aria_pressed("true")]
            False -> [attribute.aria_pressed("false")]
          },
          case Some(date) == calendar.today {
            True -> [attribute.aria_current("date")]
            False -> []
          },
          case outside {
            True -> [attribute.data("outside", "")]
            False -> []
          },
          case calendar.disabled(date) {
            True -> [attribute.disabled(True)]
            False -> []
          },
        ])
      html.td([], [
        html.button(
          [
            class(day_class()),
            attribute.type_("button"),
            attribute.data("date", to_iso(date)),
            attribute.data("label", long_date(date)),
            attribute.aria_label(
              weekday_name(weekday(date)) <> ", " <> long_date(date),
            ),
            attribute.tabindex(case date == focus {
              True -> 0
              False -> -1
            }),
            ..flags
          ],
          [text(int.to_string(date.day))],
        ),
      ])
    }),
  )
}

// -- Dates -------------------------------------------------------------------

/// `YYYY-MM-DD`.
pub fn to_iso(date: Date) -> String {
  string.pad_start(int.to_string(date.year), 4, "0")
  <> "-"
  <> string.pad_start(int.to_string(date.month), 2, "0")
  <> "-"
  <> string.pad_start(int.to_string(date.day), 2, "0")
}

/// Read `YYYY-MM-DD`, as a hidden input or `<input type="date">` sends it.
pub fn from_iso(value: String) -> Result(Date, Nil) {
  case string.split(value, "-") {
    [year, month, day] -> {
      case int.parse(year), int.parse(month), int.parse(day) {
        Ok(year), Ok(month), Ok(day) if month >= 1 && month <= 12 && day >= 1 ->
          case day <= days_in_month(year, month) {
            True -> Ok(Date(year, month, day))
            False -> Error(Nil)
          }
        _, _, _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

/// "24 September 2026".
pub fn long_date(date: Date) -> String {
  int.to_string(date.day)
  <> " "
  <> month_name(date.month)
  <> " "
  <> int.to_string(date.year)
}

/// The day of the week, from 1 for Monday to 7 for Sunday.
pub fn weekday(date: Date) -> Int {
  // 1970-01-01 was a Thursday. `%` keeps the sign of negative days.
  case { to_days(date) + 3 } % 7 {
    remainder if remainder < 0 -> remainder + 8
    remainder -> remainder + 1
  }
}

pub fn add_days(date: Date, days: Int) -> Date {
  from_days(to_days(date) + days)
}

/// The same day in the month `months` later, or the last day of that month
/// when it is shorter.
pub fn add_months(date: Date, months: Int) -> Date {
  let index = date.year * 12 + date.month - 1 + months
  let year = floor_div(index, 12)
  let month = index - year * 12 + 1
  Date(year, month, int.min(date.day, days_in_month(year, month)))
}

pub fn days_in_month(year: Int, month: Int) -> Int {
  case month {
    2 ->
      case is_leap_year(year) {
        True -> 29
        False -> 28
      }
    4 | 6 | 9 | 11 -> 30
    _ -> 31
  }
}

pub fn is_leap_year(year: Int) -> Bool {
  { year % 4 == 0 && year % 100 != 0 } || year % 400 == 0
}

pub fn compare(a: Date, b: Date) -> Order {
  int.compare(to_days(a), to_days(b))
}

// Days since 1970-01-01, after Howard Hinnant's `days_from_civil`.
fn to_days(date: Date) -> Int {
  let y = case date.month <= 2 {
    True -> date.year - 1
    False -> date.year
  }
  let era = floor_div(y, 400)
  let yoe = y - era * 400
  let mp = { date.month + 9 } % 12
  let doy = { 153 * mp + 2 } / 5 + date.day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146_097 + doe - 719_468
}

fn from_days(days: Int) -> Date {
  let z = days + 719_468
  let era = floor_div(z, 146_097)
  let doe = z - era * 146_097
  let yoe = { doe - doe / 1460 + doe / 36_524 - doe / 146_096 } / 365
  let doy = doe - { 365 * yoe + yoe / 4 - yoe / 100 }
  let mp = { 5 * doy + 2 } / 153
  let day = doy - { 153 * mp + 2 } / 5 + 1
  let month = case mp < 10 {
    True -> mp + 3
    False -> mp - 9
  }
  let year = yoe + era * 400
  let year = case month <= 2 {
    True -> year + 1
    False -> year
  }
  Date(year, month, day)
}

fn floor_div(a: Int, b: Int) -> Int {
  case int.floor_divide(a, b) {
    Ok(quotient) -> quotient
    Error(Nil) -> 0
  }
}

fn month_name(month: Int) -> String {
  case month {
    1 -> "January"
    2 -> "February"
    3 -> "March"
    4 -> "April"
    5 -> "May"
    6 -> "June"
    7 -> "July"
    8 -> "August"
    9 -> "September"
    10 -> "October"
    11 -> "November"
    _ -> "December"
  }
}

fn weekday_name(day: Int) -> String {
  case day {
    1 -> "Monday"
    2 -> "Tuesday"
    3 -> "Wednesday"
    4 -> "Thursday"
    5 -> "Friday"
    6 -> "Saturday"
    _ -> "Sunday"
  }
}

// -- Styles ------------------------------------------------------------------

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    root_class(),
    heading_class(),
    caption_class(),
    nav_class(),
    nav_button_class(),
    grid_class(),
    weekday_class(),
    day_class(),
    picker_class(),
    trigger_class(),
    popover_class(),
  ]
}

pub fn root_class() -> Class {
  css.class([css.display("inline-block"), css.color(tokens.text)])
}

pub fn heading_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.justify_content("space-between"),
    css.gap(rem(0.5)),
    css.margin_("0 0 " <> tokens.space_2),
    css.property("min-height", "2rem"),
  ])
}

pub fn caption_class() -> Class {
  css.class([
    css.padding_("0 " <> tokens.space_2),
    css.font_size(rem(0.875)),
    css.font_weight("500"),
  ])
}

pub fn nav_class() -> Class {
  css.class([css.display("flex"), css.gap(rem(0.25))])
}

pub fn nav_button_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.property("width", "2rem"),
    css.property("height", "2rem"),
    css.padding(rem(0.0)),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", tokens.radius_small),
    css.background("transparent"),
    css.color(tokens.text),
    css.font_size(rem(1.125)),
    css.line_height("1"),
    css.cursor("pointer"),
    css.hover([css.background(tokens.muted)]),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
  ])
}

pub fn grid_class() -> Class {
  css.class([
    css.border_collapse("collapse"),
    css.property("border-spacing", "0"),
  ])
}

pub fn weekday_class() -> Class {
  css.class([
    css.padding_("0 0 " <> tokens.space_1),
    css.font_size(rem(0.75)),
    css.font_weight("400"),
    css.color(tokens.text_muted),
    css.text_align("center"),
  ])
}

pub fn day_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.property("width", "2.25rem"),
    css.property("height", "2.25rem"),
    css.padding(rem(0.0)),
    css.border("0"),
    css.property("border-radius", tokens.radius_small),
    css.background("transparent"),
    css.color(tokens.text),
    css.font_family(tokens.font_body),
    css.font_size(rem(0.875)),
    css.cursor("pointer"),
    css.hover([css.background(tokens.muted)]),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "1px"),
    ]),
    css.selector("[data-outside]", [css.color(tokens.text_muted)]),
    css.selector("[aria-current=\"date\"]", [
      css.property("box-shadow", "inset 0 0 0 1px " <> tokens.border),
      css.font_weight("600"),
    ]),
    css.selector("[aria-pressed=\"true\"]", [
      css.background(tokens.primary),
      css.color(tokens.on_primary),
    ]),
    css.disabled([
      css.property("opacity", "0.4"),
      css.cursor("default"),
      css.background("transparent"),
      css.text_decoration("line-through"),
    ]),
  ])
}

pub fn picker_class() -> Class {
  css.class([css.display("block"), css.width(percent(100))])
}

pub fn trigger_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.width(percent(100)),
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    css.background(tokens.surface),
    css.color(tokens.text),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", tokens.radius_medium),
    css.font_family(tokens.font_body),
    css.font_size(rem(1.0)),
    css.line_height("1.5"),
    css.text_align("left"),
    css.cursor("pointer"),
    css.selector("[data-placeholder]", [css.color(tokens.text_muted)]),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
  ])
}

pub fn popover_class() -> Class {
  css.class([
    css.inset("auto"),
    css.margin_("0.375rem 0"),
    css.property("position-area", "block-end span-inline-end"),
    css.property("position-try-fallbacks", "flip-block, flip-inline"),
    css.padding(rem(0.75)),
    css.background(tokens.surface),
    css.color(tokens.text),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", tokens.radius_medium),
    css.box_shadow("0 10px 30px -10px rgb(0 0 0 / 0.3)"),
  ])
}
