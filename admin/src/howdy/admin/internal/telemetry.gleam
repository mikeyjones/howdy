//// The telemetry pages: requests and other traces as they finish, each
//// trace as a waterfall with its queries, events and logs, and the recent
//// log lines. They read the recorder `howdy_telemetry` fills, so they show
//// whatever the app traced: the spans Howdy opens and the app's own.

import ewe
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/float
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/layout
import howdy/controller.{type Context, type Controller}
import howdy/telemetry/recorder.{type Log, type Recorder, type Span, type Trace}
import howdy/trace
import howdy/ui
import howdy/ui/alert
import howdy/ui/badge
import howdy/ui/button
import howdy/ui/live
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event

/// How many times the same statement may run in one trace before it looks
/// like a query in a loop, one per row, that a join would replace.
pub const repeated_query_threshold = 5

/// A query slower than this, in microseconds, is pointed out.
pub const slow_query_us = 100_000

/// A trace slower than this, in microseconds, counts as slow in the list.
const slow_trace_us = 500_000

/// How many traces the list shows.
const shown = 100

pub fn controller(config: Config, recorder: Recorder) -> Controller {
  controller.new(config.prefix)
  |> controller.get("/telemetry", fn(ctx) { traces_page(config, ctx) })
  |> controller.get("/telemetry/trace/:id", fn(ctx) {
    trace_page(config, recorder, ctx)
  })
  |> controller.get("/telemetry/logs", fn(ctx) { logs_page(config, ctx) })
  |> controller.post("/telemetry/clear", fn(_) {
    recorder.clear(recorder)
    layout.redirect(config.path(config, "/telemetry"))
  })
  |> controller.get("/live/telemetry", fn(ctx) {
    live.serve(ctx, list_app(), with: #(config, recorder))
  })
  |> controller.get("/live/telemetry/logs", fn(ctx) {
    live.serve(ctx, logs_app(), with: #(config, recorder))
  })
}

// -- What a trace says --------------------------------------------------------

/// A trace with what the list and the overview point out about it.
pub type Summary {
  Summary(
    trace: Trace,
    /// The response status, for a request.
    status: Option(Int),
    queries: Int,
    /// Statements run at least `repeated_query_threshold` times, with how
    /// many times, most first.
    repeated: List(#(String, Int)),
  )
}

pub fn summarise(recorder: Recorder, trace: Trace) -> Summary {
  let spans = recorder.trace(recorder, trace.root.trace_id) |> result.unwrap([])
  Summary(
    trace:,
    status: status(trace.root),
    queries: list.count(spans, is_query),
    repeated: repeated_queries(spans),
  )
}

fn status(span: Span) -> Option(Int) {
  case recorder.attribute(span, "http.response.status_code") {
    Some(recorder.Integer(code)) -> Some(code)
    _ -> None
  }
}

fn is_query(span: Span) -> Bool {
  option.is_some(recorder.attribute(span, "db.query.text"))
}

fn query_text(span: Span) -> Option(String) {
  case recorder.attribute(span, "db.query.text") {
    Some(recorder.Text(sql)) -> Some(sql)
    _ -> None
  }
}

/// The statements a trace ran often enough to look like a query per row.
pub fn repeated_queries(spans: List(Span)) -> List(#(String, Int)) {
  spans
  |> list.filter_map(fn(span) { option.to_result(query_text(span), Nil) })
  |> list.fold(dict.new(), fn(counts, sql) {
    dict.upsert(counts, sql, fn(count) { option.unwrap(count, 0) + 1 })
  })
  |> dict.to_list
  |> list.filter(fn(pair) { pair.1 >= repeated_query_threshold })
  |> list.sort(fn(a, b) { int.compare(b.1, a.1) })
}

fn failed(span: Span) -> Bool {
  case span.status {
    recorder.Failed(_) -> True
    _ -> False
  }
}

/// The admin's own pages and the dev server's reload socket are traced like
/// any request, but they are rarely what you came to look at.
fn is_tooling(config: Config, trace: Trace) -> Bool {
  case recorder.attribute(trace.root, "url.path") {
    Some(recorder.Text(path)) ->
      path == config.prefix
      || string.starts_with(path, config.prefix <> "/")
      || string.starts_with(path, "/_howdy/")
    _ -> False
  }
}

// -- The list ------------------------------------------------------------------

fn traces_page(config: Config, ctx: Context) -> Response(ewe.Body) {
  layout.page(
    config,
    ctx,
    current: "/telemetry",
    heading: "Traces",
    live: True,
    content: [
      ui.p([
        ui.muted(
          "Requests and other traces your app recorded, newest first, as they finish. Open one for its timeline, queries and logs.",
        ),
      ]),
      live.mount(config.path(config, "/live/telemetry")),
    ],
  )
}

pub type Show {
  Everything
  Failures
  Slow
}

pub type ListModel {
  ListModel(
    config: Config,
    recorder: Recorder,
    /// The recorder's version when the list was last read.
    version: Int,
    summaries: List(Summary),
    search: String,
    show: Show,
    tooling: Bool,
  )
}

pub type ListMsg {
  Tick
  Search(List(#(String, String)))
  ClearSearch
  ShowOnly(String)
  Tooling(String)
  ClearAll
}

fn list_app() -> lustre.App(#(Config, Recorder), ListModel, ListMsg) {
  lustre.application(
    init: fn(args: #(Config, Recorder)) {
      let model =
        ListModel(
          config: args.0,
          recorder: args.1,
          version: -1,
          summaries: [],
          search: "",
          show: Everything,
          tooling: False,
        )
      #(load(model), tick())
    },
    update: list_update,
    view: list_view,
  )
}

fn list_update(
  model: ListModel,
  msg: ListMsg,
) -> #(ListModel, Effect(ListMsg)) {
  case msg {
    Tick ->
      case recorder.version(model.recorder) == model.version {
        True -> #(model, tick())
        False -> #(load(model), tick())
      }
    Search(fields) -> #(
      load(
        ListModel(
          ..model,
          search: list.key_find(fields, "q") |> result.unwrap("") |> string.trim,
        ),
      ),
      effect.none(),
    )
    ClearSearch -> #(load(ListModel(..model, search: "")), effect.none())
    ShowOnly(value) -> {
      let show = case value {
        "failures" -> Failures
        "slow" -> Slow
        _ -> Everything
      }
      #(load(ListModel(..model, show:)), effect.none())
    }
    Tooling(value) -> #(
      load(ListModel(..model, tooling: value == "yes")),
      effect.none(),
    )
    ClearAll -> {
      recorder.clear(model.recorder)
      #(load(model), effect.none())
    }
  }
}

/// Look again in a second. The recorder is in memory, so this is cheap, and
/// the list is only rebuilt when a trace has arrived since.
fn tick() -> Effect(ListMsg) {
  use dispatch <- effect.from
  process.spawn(fn() {
    process.sleep(1000)
    dispatch(Tick)
  })
  Nil
}

fn load(model: ListModel) -> ListModel {
  let version = recorder.version(model.recorder)
  let search = string.lowercase(model.search)
  let summaries =
    recorder.traces(model.recorder, limit: 1000)
    |> list.filter(fn(trace) {
      model.tooling || !is_tooling(model.config, trace)
    })
    |> list.filter(fn(trace) {
      search == ""
      || string.contains(string.lowercase(label(trace.root)), search)
    })
    |> list.filter(fn(trace) {
      case model.show {
        Everything -> True
        Failures -> trace.failed > 0
        Slow -> trace.root.duration >= slow_trace_us
      }
    })
    |> list.take(shown)
    |> list.map(summarise(model.recorder, _))
  ListModel(..model, version:, summaries:)
}

/// A root's name, with the path for a request so a search can find it.
fn label(span: Span) -> String {
  case recorder.attribute(span, "url.path") {
    Some(recorder.Text(path)) -> span.name <> " " <> path
    _ -> span.name
  }
}

fn list_view(model: ListModel) -> Element(ListMsg) {
  let config = model.config
  ui.stack([], [
    ui.row([], [
      html.form([event.on_submit(Search)], [
        ui.row([], [
          ui.input([
            attribute.type_("search"),
            attribute.name("q"),
            attribute.value(model.search),
            attribute.placeholder("search names and paths"),
            attribute.style("width", "18rem"),
          ]),
          ui.submit_button(button.Secondary, [], [text("Search")]),
          case model.search {
            "" -> element.none()
            _ ->
              ui.sized_button(
                button.Ghost,
                button.Small,
                [event.on_click(ClearSearch)],
                [text("Clear")],
              )
          },
        ]),
      ]),
      ui.native_select(
        [attribute.name("show"), live.on_value("show", ShowOnly)],
        [
          option("all", "All traces", model.show == Everything),
          option("failures", "With failures", model.show == Failures),
          option(
            "slow",
            "Slower than " <> duration(slow_trace_us),
            model.show == Slow,
          ),
        ],
      ),
      ui.native_select(
        [attribute.name("tooling"), live.on_value("tooling", Tooling)],
        [
          option("no", "Hide admin requests", !model.tooling),
          option("yes", "Show admin requests", model.tooling),
        ],
      ),
      ui.button(button.Outline, [event.on_click(ClearAll)], [text("Clear all")]),
    ]),
    case model.summaries {
      [] ->
        ui.empty(
          icon: text("◷"),
          title: case model.search, model.show {
            "", Everything -> "No traces yet"
            _, _ -> "Nothing matches"
          },
          description: case model.search, model.show {
            "", Everything ->
              "Use your app and its requests appear here as they finish."
            _, _ -> "Clear the search or show all traces."
          },
          actions: [],
        )
      summaries ->
        ui.table([], [
          ui.table_header([], [
            ui.table_row([], [
              ui.table_head([], [text("Finished")]),
              ui.table_head([], [text("Trace")]),
              ui.table_head([], [text("Status")]),
              ui.table_head([], [text("Duration")]),
              ui.table_head([], [text("Spans")]),
              ui.table_head([], [text("Queries")]),
            ]),
          ]),
          ui.table_body([], list.map(summaries, summary_row(config, _))),
        ])
    },
  ])
}

fn option(value: String, label: String, selected: Bool) -> Element(msg) {
  html.option([attribute.value(value), attribute.selected(selected)], label)
}

fn summary_row(config: Config, summary: Summary) -> Element(msg) {
  let root = summary.trace.root
  ui.table_row([], [
    ui.table_cell([], [text(clock(root.start + root.duration))]),
    ui.table_cell([], [
      ui.link(trace_href(config, root.trace_id), [text(root.name)]),
      case recorder.attribute(root, "url.path") {
        Some(recorder.Text(path)) if path != "" ->
          html.div([], [ui.muted(layout.clip(path))])
        _ -> element.none()
      },
    ]),
    ui.table_cell([], [status_badge(summary.status, summary.trace)]),
    ui.table_cell([], [mono(duration(root.duration))]),
    ui.table_cell([], [text(int.to_string(summary.trace.spans))]),
    ui.table_cell([], [
      text(int.to_string(summary.queries)),
      case summary.repeated {
        [] -> element.none()
        _ ->
          html.span([], [
            text(" "),
            ui.badge(badge.Outline, [], [text("repeated")]),
          ])
      },
    ]),
  ])
}

fn status_badge(status: Option(Int), trace: Trace) -> Element(msg) {
  case status, trace.failed {
    Some(code), _ if code >= 500 ->
      ui.badge(badge.Danger, [], [text(int.to_string(code))])
    Some(code), _ if code >= 400 ->
      ui.badge(badge.Outline, [], [text(int.to_string(code))])
    Some(code), 0 -> ui.badge(badge.Secondary, [], [text(int.to_string(code))])
    Some(code), _ -> ui.badge(badge.Danger, [], [text(int.to_string(code))])
    None, 0 -> ui.badge(badge.Secondary, [], [text("ok")])
    None, _ -> ui.badge(badge.Danger, [], [text("failed")])
  }
}

fn trace_href(config: Config, trace_id: String) -> String {
  config.path(config, "/telemetry/trace/" <> trace_id)
}

// -- One trace -------------------------------------------------------------------

fn trace_page(
  config: Config,
  recorder: Recorder,
  ctx: Context,
) -> Response(ewe.Body) {
  let assert Ok(id) = controller.param(ctx, "id")
  case recorder.trace(recorder, id) {
    Error(Nil) ->
      layout.page(
        config,
        ctx,
        current: "/telemetry",
        heading: "Trace not found",
        live: False,
        content: [
          ui.p([
            ui.muted(
              "The recorder no longer holds this trace: it keeps the newest ones and drops the rest.",
            ),
          ]),
          ui.p([
            ui.link(config.path(config, "/telemetry"), [text("All traces")]),
          ]),
        ],
      )
    Ok(spans) -> {
      let tree = tree(spans)
      let assert [#(first, _), ..] = tree
      let root =
        list.find(spans, fn(span) { span.parent_id == None })
        |> result.unwrap(first)
      layout.page(
        config,
        ctx,
        current: "/telemetry",
        heading: root.name,
        live: False,
        content: [
          ui.stack([], [
            facts(root, spans),
            warnings(spans),
            waterfall(config, tree, spans),
            logs_card(config, recorder.logs(recorder, id), False),
            ui.p([
              ui.link(config.path(config, "/telemetry"), [text("All traces")]),
            ]),
          ]),
        ],
      )
    }
  }
}

fn facts(root: Span, spans: List(Span)) -> Element(msg) {
  let failures = list.count(spans, failed)
  ui.row([], [
    status_badge(
      status(root),
      recorder.Trace(root, list.length(spans), failures),
    ),
    ui.badge(badge.Secondary, [], [text(duration(root.duration))]),
    ui.badge(badge.Outline, [], [text(describe(list.length(spans), "span"))]),
    ui.muted("started " <> clock(root.start) <> " UTC · trace "),
    mono(root.trace_id),
  ])
}

/// What deserves a look: failures, statements run once per row, and slow
/// statements.
fn warnings(spans: List(Span)) -> Element(msg) {
  let failures = list.filter(spans, failed)
  let slow =
    list.filter(spans, fn(span) {
      is_query(span) && span.duration >= slow_query_us
    })
  ui.stack([], [
    case failures {
      [] -> element.none()
      failures ->
        ui.alert(alert.Danger, [], [
          ui.alert_title([
            text(describe(list.length(failures), "span") <> " failed"),
          ]),
          ui.alert_description(
            list.map(failures, fn(span) {
              html.div([], [
                text(span.name <> ": "),
                text(case span.status {
                  recorder.Failed(message) -> message
                  _ -> ""
                }),
              ])
            }),
          ),
        ])
    },
    case repeated_queries(spans) {
      [] -> element.none()
      repeated ->
        ui.alert(alert.Info, [], [
          ui.alert_title([text("The same statement ran many times")]),
          ui.alert_description([
            html.p([], [
              text(
                "Usually a query inside a loop, one per row. A join, or one query with IN, fetches them all at once.",
              ),
            ]),
            ..list.map(repeated, fn(pair) {
              html.div([], [
                text(int.to_string(pair.1) <> " × "),
                mono(layout.clip(pair.0)),
              ])
            })
          ]),
        ])
    },
    case slow {
      [] -> element.none()
      slow ->
        ui.alert(alert.Info, [], [
          ui.alert_title([
            text("Statements slower than " <> duration(slow_query_us)),
          ]),
          ui.alert_description(
            list.map(slow, fn(span) {
              html.div([], [
                text(duration(span.duration) <> " "),
                mono(layout.clip(option.unwrap(query_text(span), span.name))),
              ])
            }),
          ),
        ])
    },
  ])
}

/// Spans in the order to draw them, each with its depth: every span after
/// its parent, siblings by start time. A span whose parent is not here,
/// the root or a child of a span in another service, starts at depth 0.
pub fn tree(spans: List(Span)) -> List(#(Span, Int)) {
  let ids = list.map(spans, fn(span) { span.span_id })
  let children: Dict(String, List(Span)) =
    list.fold(spans, dict.new(), fn(children, span) {
      case span.parent_id {
        Some(parent) ->
          case list.contains(ids, parent) {
            True ->
              dict.upsert(children, parent, fn(existing) {
                [span, ..option.unwrap(existing, [])]
              })
            False -> children
          }
        None -> children
      }
    })
  spans
  |> list.filter(fn(span) {
    case span.parent_id {
      Some(parent) -> !list.contains(ids, parent)
      None -> True
    }
  })
  |> by_start
  |> list.flat_map(descend(_, 0, children))
}

fn descend(
  span: Span,
  depth: Int,
  children: Dict(String, List(Span)),
) -> List(#(Span, Int)) {
  let below =
    dict.get(children, span.span_id)
    |> result.unwrap([])
    |> by_start
    |> list.flat_map(descend(_, depth + 1, children))
  [#(span, depth), ..below]
}

fn by_start(spans: List(Span)) -> List(Span) {
  list.sort(spans, fn(a, b) { int.compare(a.start, b.start) })
}

fn waterfall(
  config: Config,
  tree: List(#(Span, Int)),
  spans: List(Span),
) -> Element(msg) {
  let start =
    list.fold(spans, 0, fn(earliest, span) {
      case earliest == 0 || span.start < earliest {
        True -> span.start
        False -> earliest
      }
    })
  let end =
    list.fold(spans, 0, fn(latest, span) {
      int.max(latest, span.start + span.duration)
    })
  let window = int.max(end - start, 1)
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("Timeline")]),
      ui.card_description([
        text("Open a span for its attributes and events."),
      ]),
    ]),
    ui.card_content(
      [],
      list.map(tree, fn(pair) {
        span_row(config, pair.0, pair.1, start, window)
      }),
    ),
  ])
}

fn span_row(
  config: Config,
  span: Span,
  depth: Int,
  start: Int,
  window: Int,
) -> Element(msg) {
  let left = percent(span.start - start, window)
  let width = float.max(percent(span.duration, window), 0.4)
  let colour = case failed(span), is_query(span), span.kind {
    True, _, _ -> "var(--howdy-danger)"
    False, True, _ -> "var(--howdy-chart-2, var(--howdy-primary))"
    False, False, trace.Client -> "var(--howdy-chart-3, var(--howdy-primary))"
    False, False, _ -> "var(--howdy-primary)"
  }
  ui.collapsible(
    [attribute.attribute("data-span", span.span_id)],
    open: False,
    summary: [
      html.div(
        [
          attribute.style("display", "grid"),
          attribute.style(
            "grid-template-columns",
            "minmax(14rem, 2fr) 3fr 6rem",
          ),
          attribute.style("gap", "0.75rem"),
          attribute.style("align-items", "center"),
          attribute.style("width", "100%"),
        ],
        [
          html.span(
            [
              attribute.style(
                "padding-left",
                float.to_string(int.to_float(depth) *. 1.25) <> "rem",
              ),
              attribute.style("overflow", "hidden"),
              attribute.style("text-overflow", "ellipsis"),
              attribute.style("white-space", "nowrap"),
            ],
            [text(span.name)],
          ),
          html.div(
            [
              attribute.style("position", "relative"),
              attribute.style("height", "0.75rem"),
              attribute.style("border-radius", "0.25rem"),
              attribute.style("background", "var(--howdy-muted)"),
            ],
            [
              html.div(
                [
                  attribute.style("position", "absolute"),
                  attribute.style("top", "0"),
                  attribute.style("bottom", "0"),
                  attribute.style("left", float.to_string(left) <> "%"),
                  attribute.style("width", float.to_string(width) <> "%"),
                  attribute.style("border-radius", "0.25rem"),
                  attribute.style("background", colour),
                ],
                [],
              ),
            ],
          ),
          html.span(
            [
              attribute.style("text-align", "right"),
              attribute.style("font-family", "var(--howdy-font-mono)"),
            ],
            [text(duration(span.duration))],
          ),
        ],
      ),
    ],
    content: [span_details(config, span, start)],
  )
}

fn percent(part: Int, whole: Int) -> Float {
  int.to_float(part) *. 100.0 /. int.to_float(whole)
  |> float.to_precision(3)
}

fn span_details(config: Config, span: Span, start: Int) -> Element(msg) {
  ui.stack([], [
    ui.muted(
      kind_name(span.kind)
      <> " span"
      <> case span.scope {
        "" -> ""
        scope -> " from " <> scope
      }
      <> ", starting "
      <> duration(span.start - start)
      <> " in",
    ),
    case span.status {
      recorder.Failed(message) ->
        ui.alert(alert.Danger, [], [ui.alert_description([text(message)])])
      _ -> element.none()
    },
    case span.attributes {
      [] -> element.none()
      attributes ->
        ui.table([], [
          ui.table_body(
            [],
            list.map(attributes, fn(pair) {
              ui.table_row([], [
                ui.table_cell([], [mono(pair.0)]),
                ui.table_cell([], [value(pair.1)]),
              ])
            }),
          ),
        ])
    },
    case span.events {
      [] -> element.none()
      events ->
        ui.table([], [
          ui.table_header([], [
            ui.table_row([], [
              ui.table_head([], [text("At")]),
              ui.table_head([], [text("Event")]),
            ]),
          ]),
          ui.table_body(
            [],
            list.map(events, fn(event) {
              ui.table_row([], [
                ui.table_cell([], [mono("+" <> duration(event.at - span.start))]),
                ui.table_cell([], [
                  html.div([], [text(event.name)]),
                  ..list.map(event.attributes, fn(pair) {
                    html.div([], [ui.muted(pair.0 <> ": "), value(pair.1)])
                  })
                ]),
              ])
            }),
          ),
        ])
    },
    case span.links {
      [] -> element.none()
      links ->
        html.div(
          [],
          list.map(links, fn(link) {
            html.div([], [
              ui.muted("Linked to "),
              ui.link(trace_href(config, link.0), [text("trace " <> link.0)]),
            ])
          }),
        )
    },
  ])
}

/// Long values, such as SQL and stack traces, keep their line breaks.
fn value(value: recorder.Value) -> Element(msg) {
  html.code(
    [
      attribute.style("white-space", "pre-wrap"),
      attribute.style("word-break", "break-word"),
    ],
    [text(recorder.value_to_string(value))],
  )
}

fn kind_name(kind: trace.Kind) -> String {
  case kind {
    trace.Internal -> "Internal"
    trace.Server -> "Server"
    trace.Client -> "Client"
    trace.Producer -> "Producer"
    trace.Consumer -> "Consumer"
  }
}

// -- Logs ------------------------------------------------------------------------

fn logs_page(config: Config, ctx: Context) -> Response(ewe.Body) {
  layout.page(
    config,
    ctx,
    current: "/telemetry/logs",
    heading: "Logs",
    live: True,
    content: [
      ui.p([
        ui.muted(
          "The newest log lines, with the trace each was written in. The last 2,000 are kept.",
        ),
      ]),
      live.mount(config.path(config, "/live/telemetry/logs")),
    ],
  )
}

pub type LogsModel {
  LogsModel(config: Config, recorder: Recorder, logs: List(Log), level: String)
}

pub type LogsMsg {
  LogsTick
  Level(String)
}

fn logs_app() -> lustre.App(#(Config, Recorder), LogsModel, LogsMsg) {
  lustre.application(
    init: fn(args: #(Config, Recorder)) {
      #(load_logs(LogsModel(args.0, args.1, [], "all")), logs_tick())
    },
    update: fn(model: LogsModel, msg) {
      case msg {
        LogsTick -> #(load_logs(model), logs_tick())
        Level(level) -> #(load_logs(LogsModel(..model, level:)), effect.none())
      }
    },
    view: fn(model: LogsModel) {
      ui.stack([], [
        ui.row([], [
          ui.native_select(
            [attribute.name("level"), live.on_value("level", Level)],
            [
              option("all", "Every level", model.level == "all"),
              option("warning", "Warnings and worse", model.level == "warning"),
              option("error", "Errors and worse", model.level == "error"),
            ],
          ),
        ]),
        logs_card(model.config, model.logs, True),
      ])
    },
  )
}

fn logs_tick() -> Effect(LogsMsg) {
  use dispatch <- effect.from
  process.spawn(fn() {
    process.sleep(1000)
    dispatch(LogsTick)
  })
  Nil
}

fn load_logs(model: LogsModel) -> LogsModel {
  let logs =
    recorder.recent_logs(model.recorder, limit: 2000)
    |> list.filter(fn(log) { at_least(log.level, model.level) })
    |> list.reverse
    |> list.take(200)
  LogsModel(..model, logs:)
}

fn at_least(level: String, threshold: String) -> Bool {
  severity(level) >= severity(threshold)
}

fn severity(level: String) -> Int {
  case level {
    "emergency" -> 7
    "alert" -> 6
    "critical" -> 5
    "error" -> 4
    "warning" -> 3
    "notice" -> 2
    "info" -> 1
    _ -> 0
  }
}

/// Log lines, newest first. `link` adds a column linking each line's trace.
fn logs_card(config: Config, logs: List(Log), link: Bool) -> Element(msg) {
  case logs, link {
    [], False -> element.none()
    [], True ->
      ui.empty(
        icon: text("≡"),
        title: "No log lines",
        description: "Lines your app logs appear here as they are written.",
        actions: [],
      )
    logs, _ ->
      ui.card([], [
        ui.card_header([], [ui.card_title([text("Logs")])]),
        ui.card_content([], [
          ui.table([], [
            ui.table_header([], [
              ui.table_row(
                [],
                list.flatten([
                  [
                    ui.table_head([], [text("At")]),
                    ui.table_head([], [text("Level")]),
                    ui.table_head([], [text("Message")]),
                  ],
                  case link {
                    True -> [ui.table_head([], [text("Trace")])]
                    False -> []
                  },
                ]),
              ),
            ]),
            ui.table_body(
              [],
              list.map(logs, fn(log) {
                ui.table_row(
                  [],
                  list.flatten([
                    [
                      ui.table_cell([], [mono(clock(log.at))]),
                      ui.table_cell([], [level_badge(log.level)]),
                      ui.table_cell([], [value(recorder.Text(log.message))]),
                    ],
                    case link {
                      True -> [
                        ui.table_cell([], [
                          case log.trace_id {
                            Some(id) ->
                              ui.link(trace_href(config, id), [text("open")])
                            None -> element.none()
                          },
                        ]),
                      ]
                      False -> []
                    },
                  ]),
                )
              }),
            ),
          ]),
        ]),
      ])
  }
}

fn level_badge(level: String) -> Element(msg) {
  let variant = case severity(level) {
    s if s >= 4 -> badge.Danger
    3 -> badge.Outline
    _ -> badge.Secondary
  }
  ui.badge(variant, [], [text(level)])
}

// -- Formatting ------------------------------------------------------------------

/// A duration in microseconds, in the unit that reads best.
pub fn duration(microseconds: Int) -> String {
  case microseconds {
    us if us < 1000 -> int.to_string(us) <> " µs"
    us if us < 10_000 ->
      float.to_string(float.to_precision(int.to_float(us) /. 1000.0, 1))
      <> " ms"
    us if us < 1_000_000 -> int.to_string(us / 1000) <> " ms"
    us ->
      float.to_string(float.to_precision(int.to_float(us) /. 1_000_000.0, 2))
      <> " s"
  }
}

/// The time of day of a moment in microseconds since the epoch, in UTC, to
/// the millisecond.
fn clock(microseconds: Int) -> String {
  let seconds =
    timestamp.from_unix_seconds(microseconds / 1_000_000)
    |> timestamp.to_rfc3339(calendar.utc_offset)
    |> string.slice(11, 8)
  let milliseconds = { microseconds % 1_000_000 } / 1000
  seconds <> "." <> string.pad_start(int.to_string(milliseconds), 3, "0")
}

fn mono(content: String) -> Element(msg) {
  html.code([attribute.style("font-family", "var(--howdy-font-mono)")], [
    text(content),
  ])
}

fn describe(count: Int, noun: String) -> String {
  int.to_string(count)
  <> " "
  <> case count {
    1 -> noun
    _ -> noun <> "s"
  }
}
