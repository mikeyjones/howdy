//// Charts: bar, line and area charts drawn as SVG on the server, in the
//// theme's chart colours.
////
//// ```gleam
//// chart.bar(
////   title: "Revenue by month",
////   labels: ["Jan", "Feb", "Mar"],
////   series: [
////     chart.Series("Online", [4200.0, 5100.0, 6100.0]),
////     chart.Series("In store", [3100.0, 2900.0, 3300.0]),
////   ],
//// )
//// |> chart.view
//// ```
////
//// Every series is one entry per label. Series take the theme's chart
//// colours in order, so a series keeps its colour as long as it keeps its
//// place: when a filter removes some, pass the survivors in the same order
//// with `colours` rather than letting them shift. There are five colours;
//// past five series, fold the rest into an "Other" series or draw several
//// charts. A sixth and later series is drawn in the muted text colour.
////
//// Hovering over or focusing a label's column shows every series' value
//// there; with Tab a keyboard reaches each column, and a screen reader
//// reads the same values. Under the chart, "Show data" opens the numbers as
//// a table. None of it needs a script.
////
//// The value axis always includes zero, so bars grow from a baseline and a
//// line's height is honest. Two measures on different scales belong in two
//// charts, never on two axes of one.

import gleam/float
import gleam/int
import gleam/list
import gleam/string
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/element/svg
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

/// A named list of values, one per label.
pub type Series {
  Series(name: String, values: List(Float))
}

pub type Kind {
  Bar
  Line
  Area
}

pub opaque type Chart {
  Chart(
    kind: Kind,
    title: String,
    labels: List(String),
    series: List(Series),
    colours: List(Int),
    format: fn(Float) -> String,
  )
}

/// Columns, grouped by label when there are several series.
pub fn bar(
  title title: String,
  labels labels: List(String),
  series series: List(Series),
) -> Chart {
  new(Bar, title, labels, series)
}

/// Lines, for change over an ordered range such as time.
pub fn line(
  title title: String,
  labels labels: List(String),
  series series: List(Series),
) -> Chart {
  new(Line, title, labels, series)
}

/// Lines with a light wash beneath, for volumes over time.
pub fn area(
  title title: String,
  labels labels: List(String),
  series series: List(Series),
) -> Chart {
  new(Area, title, labels, series)
}

fn new(kind: Kind, title: String, labels: List(String), series: List(Series)) {
  Chart(
    kind:,
    title:,
    labels:,
    series:,
    colours: list.index_map(series, fn(_, index) { index + 1 }),
    format: format_number,
  )
}

/// How values are written on the axis, in readouts and in the table. The
/// default writes whole numbers with thousands separators and at most two
/// decimal places.
pub fn format(chart: Chart, format: fn(Float) -> String) -> Chart {
  Chart(..chart, format:)
}

/// Which chart colour, from 1 to 5, each series takes. Use it to keep a
/// series' colour when others are filtered out.
pub fn colours(chart: Chart, colours: List(Int)) -> Chart {
  Chart(..chart, colours:)
}

// -- Geometry ----------------------------------------------------------------
//
// Text, dots, bars and hover columns are HTML placed over the plot, so they
// keep their size at any width. Lines, washes and gridlines are an SVG
// stretched across the plot: x runs from 0 to 100 as a percentage of its
// width, y is in pixels, and strokes do not scale.

const plot_height = 200.0

const top = 12.0

const bottom_band = 28.0

/// An estimate of the width of text in the chart's 12px type.
fn text_width(content: String) -> Float {
  int.to_float(string.length(content)) *. 6.8
}

type Scale {
  Scale(low: Float, high: Float, ticks: List(Float))
}

fn scale(values: List(Float)) -> Scale {
  let low = list.fold(values, 0.0, float.min)
  let high = list.fold(values, 0.0, float.max)
  let high = case high == low {
    True -> low +. 1.0
    False -> high
  }
  let step = nice_step({ high -. low } /. 5.0)
  let low = float.floor(low /. step) *. step
  let high = float.ceiling(high /. step) *. step
  let count = float.round({ high -. low } /. step)
  let ticks =
    list.repeat(Nil, count + 1)
    |> list.index_map(fn(_, index) { low +. int.to_float(index) *. step })
  Scale(low:, high:, ticks:)
}

/// 1, 2 or 5 times a power of ten.
fn nice_step(raw: Float) -> Float {
  let assert Ok(ln) = float.logarithm(raw)
  let assert Ok(ln10) = float.logarithm(10.0)
  let assert Ok(magnitude) = float.power(10.0, float.floor(ln /. ln10))
  let factor = case raw /. magnitude {
    n if n <=. 1.0 -> 1.0
    n if n <=. 2.0 -> 2.0
    n if n <=. 5.0 -> 5.0
    _ -> 10.0
  }
  factor *. magnitude
}

/// Pixels from the top of the plot.
fn y_of(scale: Scale, value: Float) -> Float {
  plot_height
  -. { value -. scale.low }
  /. { scale.high -. scale.low }
  *. plot_height
}

/// The centre of a label's column, as a percentage of the plot's width.
fn x_of(count: Int, index: Int) -> Float {
  { int.to_float(index) +. 0.5 } /. int.to_float(int.max(count, 1)) *. 100.0
}

fn n(value: Float) -> String {
  float.to_string(float.to_precision(value, 2))
}

fn px(value: Float) -> String {
  n(value) <> "px"
}

fn pct(value: Float) -> String {
  n(value) <> "%"
}

// -- View --------------------------------------------------------------------

pub fn view(chart: Chart) -> Element(msg) {
  let values = list.flat_map(chart.series, fn(series) { series.values })
  let scale = scale(values)
  let count = list.length(chart.labels)
  let tick_labels = list.map(scale.ticks, chart.format)
  let gutter =
    list.fold(tick_labels, 0.0, fn(widest, label) {
      float.max(widest, text_width(label))
    })
    +. 12.0
  let direct = direct_labels(chart, scale)
  let end_gutter = case direct {
    True ->
      list.fold(chart.series, 0.0, fn(widest, series) {
        float.max(widest, text_width(series.name))
      })
      +. 20.0
    False -> 8.0
  }

  html.figure([class(figure_class())], [
    legend(chart),
    html.div(
      [
        class(chart_class()),
        attribute.style("height", px(top +. plot_height +. bottom_band)),
        attribute.role("group"),
        attribute.aria_label(chart.title),
      ],
      [
        html.div(
          [
            class(gutter_class()),
            attribute.style("width", px(gutter)),
            attribute.aria_hidden(True),
          ],
          list.map2(scale.ticks, tick_labels, fn(tick, label) {
            html.span(
              [
                class(tick_class()),
                attribute.style("top", px(top +. y_of(scale, tick))),
              ],
              [text(label)],
            )
          }),
        ),
        html.div(
          [
            class(plot_class()),
            attribute.style("left", px(gutter)),
            attribute.style("right", px(end_gutter)),
            attribute.style("top", px(top)),
            attribute.style("height", px(plot_height)),
          ],
          list.flatten([
            [
              html.div([attribute.aria_hidden(True)], [
                drawing(chart, scale, count),
                bars(chart, scale, count),
                end_dots(chart, scale, count),
                case direct {
                  True -> end_labels(chart, scale, count)
                  False -> element.none()
                },
                x_labels(chart, count),
              ]),
            ],
            list.index_map(chart.labels, fn(label, index) {
              column_view(chart, scale, count, label, index)
            }),
          ]),
        ),
      ],
    ),
    data_view(chart),
  ])
}

fn colour(chart: Chart, index: Int) -> String {
  let slot = case list.drop(chart.colours, index) {
    [slot, ..] -> slot
    [] -> index + 1
  }
  case list.drop(tokens.chart, slot - 1) {
    [colour, ..] if slot >= 1 -> colour
    _ -> tokens.text_muted
  }
}

fn legend(chart: Chart) -> Element(msg) {
  case chart.series {
    [_, _, ..] ->
      html.ul(
        [class(legend_class())],
        list.index_map(chart.series, fn(series, index) {
          let shape = case chart.kind {
            Line -> key_line_class()
            Bar | Area -> key_box_class()
          }
          html.li([], [
            html.span(
              [
                class(shape),
                attribute.style("background", colour(chart, index)),
              ],
              [],
            ),
            text(series.name),
          ])
        }),
      )
    _ -> element.none()
  }
}

/// Gridlines, lines and washes.
fn drawing(chart: Chart, scale: Scale, count: Int) -> Element(msg) {
  let zero = y_of(scale, 0.0)
  let rules =
    list.map(scale.ticks, fn(tick) {
      let y = y_of(scale, tick)
      svg.line([
        class(case tick == 0.0 {
          True -> baseline_class()
          False -> grid_class()
        }),
        attribute.attribute("x1", "0"),
        attribute.attribute("x2", "100"),
        attribute.attribute("y1", n(y)),
        attribute.attribute("y2", n(y)),
      ])
    })
  let lines = case chart.kind {
    Bar -> []
    Line | Area ->
      list.flatten(
        list.index_map(chart.series, fn(series, s) {
          let points =
            list.index_map(series.values, fn(value, index) {
              n(x_of(count, index)) <> "," <> n(y_of(scale, value))
            })
          let path = string.join(points, " L ")
          let wash = case chart.kind, points {
            Area, [_, ..] -> [
              svg.path([
                attribute.attribute(
                  "d",
                  "M "
                    <> n(x_of(count, 0))
                    <> ","
                    <> n(zero)
                    <> " L "
                    <> path
                    <> " L "
                    <> n(x_of(count, list.length(points) - 1))
                    <> ","
                    <> n(zero)
                    <> " Z",
                ),
                attribute.style("fill", colour(chart, s)),
                attribute.attribute("fill-opacity", "0.1"),
              ]),
            ]
            _, _ -> []
          }
          list.append(wash, [
            svg.path([
              class(line_class()),
              attribute.attribute("d", "M " <> path),
              attribute.style("stroke", colour(chart, s)),
            ]),
          ])
        }),
      )
  }
  html.svg(
    [
      class(svg_class()),
      attribute.attribute("viewBox", "0 0 100 " <> n(plot_height)),
      attribute.attribute("preserveAspectRatio", "none"),
    ],
    list.append(rules, lines),
  )
}

/// Columns grow from the baseline, up to 24px wide, rounded at the data
/// end only.
fn bars(chart: Chart, scale: Scale, count: Int) -> Element(msg) {
  case chart.kind {
    Line | Area -> element.none()
    Bar -> {
      let zero = y_of(scale, 0.0)
      html.div(
        [],
        list.index_map(chart.labels, fn(_, index) {
          html.div(
            [
              class(bar_group_class()),
              attribute.style(
                "left",
                pct(x_of(count, index) -. 40.0 /. int.to_float(count)),
              ),
              attribute.style("width", pct(80.0 /. int.to_float(count))),
            ],
            list.index_map(chart.series, fn(series, s) {
              let value = case list.drop(series.values, index) {
                [value, ..] -> value
                [] -> 0.0
              }
              let y = y_of(scale, value)
              let #(top, height, shape) = case value >=. 0.0 {
                True -> #(y, zero -. y, bar_up_class())
                False -> #(zero, y -. zero, bar_down_class())
              }
              html.div([class(bar_slot_class())], [
                html.div(
                  [
                    class(shape),
                    attribute.style("top", px(top)),
                    attribute.style("height", px(height)),
                    attribute.style("background", colour(chart, s)),
                  ],
                  [],
                ),
              ])
            }),
          )
        }),
      )
    }
  }
}

fn dot(x: Float, y: Float, colour: String) -> Element(msg) {
  html.span(
    [
      class(dot_class()),
      attribute.style("left", pct(x)),
      attribute.style("top", px(y)),
      attribute.style("background", colour),
    ],
    [],
  )
}

fn end_dots(chart: Chart, scale: Scale, count: Int) -> Element(msg) {
  case chart.kind {
    Bar -> element.none()
    Line | Area ->
      html.div(
        [],
        list.index_map(chart.series, fn(series, s) {
          case list.last(series.values) {
            Ok(value) ->
              dot(
                x_of(count, list.length(series.values) - 1),
                y_of(scale, value),
                colour(chart, s),
              )
            Error(Nil) -> element.none()
          }
        }),
      )
  }
}

/// Lines and areas with two to four series name each at its end, unless
/// two ends are too close to label apart; then the legend does it alone.
fn direct_labels(chart: Chart, scale: Scale) -> Bool {
  let count = list.length(chart.series)
  case chart.kind, count >= 2 && count <= 4 {
    Line, True | Area, True -> {
      let ends =
        chart.series
        |> list.filter_map(fn(series) { list.last(series.values) })
        |> list.map(y_of(scale, _))
        |> list.sort(float.compare)
      let #(_, apart) =
        list.fold(ends, #(-100.0, True), fn(acc, y) {
          #(y, acc.1 && y -. acc.0 >=. 14.0)
        })
      apart
    }
    _, _ -> False
  }
}

/// Each name level with its line's last point, just past the end of the
/// plot.
fn end_labels(chart: Chart, scale: Scale, count: Int) -> Element(msg) {
  html.div(
    [],
    list.map(chart.series, fn(series) {
      case list.last(series.values) {
        Ok(value) ->
          html.span(
            [
              class(end_label_class()),
              attribute.style(
                "left",
                "calc("
                  <> pct(x_of(count, list.length(series.values) - 1))
                  <> " + 10px)",
              ),
              attribute.style("top", px(y_of(scale, value))),
            ],
            [text(series.name)],
          )
        Error(Nil) -> element.none()
      }
    }),
  )
}

/// Every label that fits, assuming a plot about 480px wide; when they
/// would collide, every second, third and so on.
fn x_labels(chart: Chart, count: Int) -> Element(msg) {
  let widest =
    list.fold(chart.labels, 0.0, fn(widest, label) {
      float.max(widest, text_width(label))
    })
    +. 8.0
  let room = 480.0 /. int.to_float(int.max(count, 1))
  let every = int.max(1, float.round(float.ceiling(widest /. room)))
  html.div(
    [],
    list.index_map(chart.labels, fn(label, index) {
      case index % every == 0 {
        True ->
          html.span(
            [
              class(x_label_class()),
              attribute.style("left", pct(x_of(count, index))),
              attribute.style("top", px(plot_height +. 8.0)),
            ],
            [text(label)],
          )
        False -> element.none()
      }
    }),
  )
}

/// One label's column: the hit area, and the readout shown on hover or
/// focus.
fn column_view(
  chart: Chart,
  scale: Scale,
  count: Int,
  label: String,
  index: Int,
) -> Element(msg) {
  let width = 100.0 /. int.to_float(count)
  let readings =
    list.index_map(chart.series, fn(series, s) {
      case list.drop(series.values, index) {
        [value, ..] -> Ok(#(series.name, value, colour(chart, s)))
        [] -> Error(Nil)
      }
    })
    |> list.filter_map(fn(reading) { reading })
  let spoken =
    label
    <> ": "
    <> string.join(
      list.map(readings, fn(reading) {
        reading.0 <> " " <> chart.format(reading.1)
      }),
      ", ",
    )
  let marker = case chart.kind {
    Bar -> html.span([class(highlight_class())], [])
    Line | Area ->
      html.span([], [
        html.span([class(crosshair_class())], []),
        ..list.map(readings, fn(reading) {
          dot(50.0, y_of(scale, reading.1), reading.2)
        })
      ])
  }
  // Readouts sit to the right of their column, or to the left towards the
  // end of the plot.
  let side = case x_of(count, index) >. 60.0 {
    True -> tip_left_class()
    False -> tip_right_class()
  }
  html.div(
    [
      class(column_class()),
      attribute.style("left", pct(int.to_float(index) *. width)),
      attribute.style("width", pct(width)),
      attribute.tabindex(0),
      attribute.role("img"),
      attribute.aria_label(spoken),
    ],
    [
      html.span([attribute.data("reveal", ""), attribute.aria_hidden(True)], [
        marker,
        html.span([class(tip_class()), class(side)], [
          html.span([class(tip_label_class())], [text(label)]),
          ..list.map(readings, fn(reading) {
            html.span([class(tip_row_class())], [
              html.span(
                [
                  class(key_line_class()),
                  attribute.style("background", reading.2),
                ],
                [],
              ),
              html.strong([], [text(chart.format(reading.1))]),
              html.span([class(tip_name_class())], [text(reading.0)]),
            ])
          })
        ]),
      ]),
    ],
  )
}

/// The numbers as a table, behind "Show data".
fn data_view(chart: Chart) -> Element(msg) {
  html.details([class(details_class())], [
    html.summary([class(summary_class())], [text("Show data")]),
    html.div([class(table_scroll_class())], [
      html.table([class(table_class())], [
        html.caption([class(caption_class())], [text(chart.title)]),
        html.thead([], [
          html.tr([], [
            html.th([attribute.attribute("scope", "col")], []),
            ..list.map(chart.series, fn(series) {
              html.th([attribute.attribute("scope", "col")], [text(series.name)])
            })
          ]),
        ]),
        html.tbody(
          [],
          list.index_map(chart.labels, fn(label, index) {
            html.tr([], [
              html.th([attribute.attribute("scope", "row")], [text(label)]),
              ..list.map(chart.series, fn(series) {
                html.td([], [
                  text(case list.drop(series.values, index) {
                    [value, ..] -> chart.format(value)
                    [] -> ""
                  }),
                ])
              })
            ])
          }),
        ),
      ]),
    ]),
  ])
}

// -- Numbers -----------------------------------------------------------------

/// Thousands separators and at most two decimal places: 12,500 or 3.25.
pub fn format_number(value: Float) -> String {
  let sign = case value <. 0.0 {
    True -> "-"
    False -> ""
  }
  let hundredths = float.round(float.absolute_value(value) *. 100.0)
  let whole = hundredths / 100
  let fraction = hundredths % 100
  let decimals = case fraction {
    0 -> ""
    f if f % 10 == 0 -> "." <> int.to_string(f / 10)
    f -> "." <> string.pad_start(int.to_string(f), 2, "0")
  }
  sign <> group_thousands(int.to_string(whole)) <> decimals
}

fn group_thousands(digits: String) -> String {
  case string.length(digits) > 3 {
    True ->
      group_thousands(string.drop_end(digits, 3))
      <> ","
      <> string.slice(digits, string.length(digits) - 3, 3)
    False -> digits
  }
}

// -- Styles ------------------------------------------------------------------

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    figure_class(),
    chart_class(),
    gutter_class(),
    plot_class(),
    svg_class(),
    legend_class(),
    key_box_class(),
    key_line_class(),
    grid_class(),
    baseline_class(),
    tick_class(),
    x_label_class(),
    line_class(),
    bar_group_class(),
    bar_slot_class(),
    bar_up_class(),
    bar_down_class(),
    dot_class(),
    end_label_class(),
    column_class(),
    highlight_class(),
    crosshair_class(),
    tip_class(),
    tip_right_class(),
    tip_left_class(),
    tip_label_class(),
    tip_row_class(),
    tip_name_class(),
    details_class(),
    summary_class(),
    table_scroll_class(),
    table_class(),
    caption_class(),
  ]
}

pub fn figure_class() -> Class {
  css.class([css.margin(rem(0.0)), css.color(tokens.text)])
}

pub fn chart_class() -> Class {
  css.class([
    css.position("relative"),
    css.font_family(tokens.font_body),
    css.font_size_("12px"),
    css.line_height("1"),
  ])
}

pub fn gutter_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("left", "0"),
    css.property("top", "0"),
    css.property("bottom", "0"),
  ])
}

pub fn plot_class() -> Class {
  // Its own stacking context, so a column's highlight sits behind the bars
  // but in front of the card.
  css.class([css.position("absolute"), css.property("isolation", "isolate")])
}

pub fn svg_class() -> Class {
  css.class([
    css.position("absolute"),
    css.inset("0"),
    css.width(percent(100)),
    css.height(percent(100)),
    css.overflow("visible"),
  ])
}

pub fn legend_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.gap(rem(1.0)),
    css.margin_("0 0 " <> tokens.space_2),
    css.padding(rem(0.0)),
    css.list_style("none"),
    css.font_size(rem(0.8125)),
    css.color(tokens.text_muted),
    css.selector(" > li", [
      css.display("inline-flex"),
      css.align_items("center"),
      css.gap(rem(0.375)),
    ]),
  ])
}

pub fn key_box_class() -> Class {
  css.class([
    css.display("inline-block"),
    css.property("width", "10px"),
    css.property("height", "10px"),
    css.property("border-radius", "2px"),
  ])
}

pub fn key_line_class() -> Class {
  css.class([
    css.display("inline-block"),
    css.flex_shrink(0.0),
    css.property("width", "12px"),
    css.property("height", "2px"),
    css.property("border-radius", "1px"),
  ])
}

fn rule() -> List(css.Style) {
  [
    css.property("stroke-width", "1"),
    css.property("vector-effect", "non-scaling-stroke"),
    css.property("shape-rendering", "crispEdges"),
  ]
}

pub fn grid_class() -> Class {
  css.class([css.property("stroke", tokens.border), ..rule()])
}

pub fn baseline_class() -> Class {
  css.class([
    css.property("stroke", tokens.text_muted),
    css.property("stroke-opacity", "0.6"),
    ..rule()
  ])
}

pub fn tick_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("right", "8px"),
    css.transform_("translateY(-50%)"),
    css.color(tokens.text_muted),
    css.white_space("nowrap"),
    css.property("font-variant-numeric", "tabular-nums"),
  ])
}

pub fn x_label_class() -> Class {
  css.class([
    css.position("absolute"),
    css.transform_("translateX(-50%)"),
    css.color(tokens.text_muted),
    css.white_space("nowrap"),
  ])
}

pub fn line_class() -> Class {
  css.class([
    css.property("fill", "none"),
    css.property("stroke-width", "2"),
    css.property("stroke-linejoin", "round"),
    css.property("stroke-linecap", "round"),
    css.property("vector-effect", "non-scaling-stroke"),
  ])
}

pub fn bar_group_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("top", "0"),
    css.property("bottom", "0"),
    css.display("flex"),
    css.justify_content("center"),
    css.gap_("2px"),
  ])
}

pub fn bar_slot_class() -> Class {
  css.class([
    css.position("relative"),
    css.property("flex", "1 1 0"),
    css.property("max-width", "24px"),
  ])
}

pub fn bar_up_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("left", "0"),
    css.property("right", "0"),
    css.property("border-radius", "4px 4px 0 0"),
  ])
}

pub fn bar_down_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("left", "0"),
    css.property("right", "0"),
    css.property("border-radius", "0 0 4px 4px"),
  ])
}

pub fn dot_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("width", "8px"),
    css.property("height", "8px"),
    css.property("border-radius", "50%"),
    css.box_shadow("0 0 0 2px " <> tokens.surface),
    css.transform_("translate(-50%, -50%)"),
  ])
}

pub fn end_label_class() -> Class {
  css.class([
    css.position("absolute"),
    css.transform_("translateY(-50%)"),
    css.color(tokens.text),
    css.white_space("nowrap"),
  ])
}

pub fn column_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("top", "0"),
    css.property("bottom", "-" <> n(bottom_band) <> "px"),
    css.outline("none"),
    css.selector(" [data-reveal]", [css.display("none")]),
    css.selector(":hover [data-reveal]", [css.display("block")]),
    css.selector(":focus-visible [data-reveal]", [css.display("block")]),
    css.selector(":focus-visible", [
      css.property("box-shadow", "inset 0 0 0 2px " <> tokens.focus),
      css.property("border-radius", tokens.radius_small),
    ]),
  ])
}

pub fn highlight_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("inset", "0 0 " <> n(bottom_band) <> "px"),
    css.background(tokens.muted),
    css.property("opacity", "0.5"),
    css.z_index(-1),
  ])
}

pub fn crosshair_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("left", "50%"),
    css.property("top", "0"),
    css.property("height", n(plot_height) <> "px"),
    css.property("border-left", "1px solid " <> tokens.text_muted),
  ])
}

pub fn tip_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("top", "0"),
    css.z_index(1),
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.25)),
    css.padding_("0.375rem 0.5rem"),
    css.background(tokens.surface),
    css.color(tokens.text),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", tokens.radius_small),
    css.box_shadow("0 4px 12px -4px rgb(0 0 0 / 0.25)"),
    css.line_height("1.3"),
    css.white_space("nowrap"),
    css.property("pointer-events", "none"),
  ])
}

pub fn tip_right_class() -> Class {
  css.class([css.property("left", "calc(50% + 14px)")])
}

pub fn tip_left_class() -> Class {
  css.class([css.property("right", "calc(50% + 14px)")])
}

pub fn tip_label_class() -> Class {
  css.class([css.color(tokens.text_muted)])
}

pub fn tip_row_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.gap(rem(0.375)),
  ])
}

pub fn tip_name_class() -> Class {
  css.class([css.color(tokens.text_muted)])
}

pub fn details_class() -> Class {
  css.class([css.margin_(tokens.space_2 <> " 0 0"), css.font_size(rem(0.8125))])
}

pub fn summary_class() -> Class {
  css.class([
    css.color(tokens.text_muted),
    css.cursor("pointer"),
    css.property("width", "fit-content"),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
  ])
}

pub fn table_scroll_class() -> Class {
  css.class([css.overflow_x("auto"), css.margin_(tokens.space_2 <> " 0 0")])
}

pub fn table_class() -> Class {
  css.class([
    css.border_collapse("collapse"),
    css.property("font-variant-numeric", "tabular-nums"),
    css.selector(" th", cell_styles()),
    css.selector(" td", cell_styles()),
    css.selector(" th[scope=\"row\"]", [css.text_align("left")]),
  ])
}

fn cell_styles() -> List(css.Style) {
  [
    css.padding_(tokens.space_1 <> " " <> tokens.space_3),
    css.property("border-bottom", "1px solid " <> tokens.border),
    css.text_align("right"),
  ]
}

pub fn caption_class() -> Class {
  css.class([
    css.text_align("left"),
    css.padding_("0 0 " <> tokens.space_1),
    css.color(tokens.text_muted),
  ])
}
