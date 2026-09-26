//// The database pages: the list of tables, a live grid of each table's
//// rows, and forms to insert, edit and delete a row.

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gleam/uri
import gloo/repo.{type Repo}
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/layout
import howdy/admin/internal/notify
import howdy/admin/internal/schema.{type Row, type Table, Row}
import howdy/content.{type Content}
import howdy/controller.{type Context, type Controller}
import howdy/database.{Postgres, Sqlite}
import howdy/form
import howdy/service
import howdy/ui
import howdy/ui/badge
import howdy/ui/button
import howdy/ui/live
import howdy/ui/pagination
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event

/// How often the grid checks the table for changes, in milliseconds.
const refresh_ms = 1000

/// With notifications, how often the grid still checks, in case one was
/// missed while the listener reconnected.
const fallback_ms = 15_000

/// How long a changed row stays marked, in milliseconds.
const highlight_ms = 4000

pub fn controller(config: Config, repo: Repo) -> Controller {
  controller.new(config.prefix)
  |> controller.get("/data", fn(ctx) { index(config, repo, ctx) })
  |> controller.get("/data/:table", fn(ctx) { show(config, repo, ctx) })
  |> controller.get("/data/:table/new", fn(ctx) { new(config, repo, ctx) })
  |> controller.post("/data/:table", fn(ctx) { create(config, repo, ctx) })
  |> controller.get("/data/:table/row", fn(ctx) { edit(config, repo, ctx) })
  |> controller.post("/data/:table/row", fn(ctx) { save(config, repo, ctx) })
  |> controller.post("/data/:table/row/delete", fn(ctx) {
    remove(config, repo, ctx)
  })
  |> controller.get("/live/data/:table", fn(ctx) { socket(config, repo, ctx) })
}

// -- Pages -------------------------------------------------------------------

/// Howdy's own packages keep their tables under this prefix. They are
/// hidden by default so the application's own stand out; `?all=1` shows
/// them.
const framework_prefix = "howdy_"

fn index(config: Config, repo: Repo, ctx: Context) -> Response(Content) {
  let all =
    request.get_query(ctx.request) |> result.unwrap([]) |> list.key_find("all")
    == Ok("1")
  let listed = {
    use names <- result.try(schema.tables(repo))
    let hidden =
      list.count(names, fn(name) { string.starts_with(name, framework_prefix) })
    let names = case all {
      True -> names
      False ->
        list.filter(names, fn(name) {
          !string.starts_with(name, framework_prefix)
        })
    }
    use backend <- result.try(database.backend(repo))
    use counted <- result.try(
      list.try_map(names, fn(name) {
        use table <- result.try(schema.table(repo, name))
        use count <- result.try(schema.count(repo, table, schema.query()))
        Ok(#(table, count))
      }),
    )
    Ok(#(backend, counted, hidden))
  }
  case listed {
    Error(error) ->
      layout.failure(
        config,
        ctx,
        current: "/data",
        heading: "Tables",
        error:,
        back: config.path(config, ""),
      )
    Ok(#(backend, tables, hidden)) ->
      layout.page(
        config,
        ctx,
        current: "/data",
        heading: "Tables",
        live: False,
        content: [
          ui.p([
            text(case backend {
              Postgres -> "PostgreSQL"
              Sqlite -> "SQLite"
            }),
            text(" · "),
            text(int.to_string(list.length(tables)) <> " tables"),
            case all, hidden {
              _, 0 -> element.none()
              True, _ ->
                element.fragment([
                  text(" · "),
                  ui.link(config.path(config, "/data"), [
                    text("Hide Howdy's own tables"),
                  ]),
                ])
              False, _ ->
                element.fragment([
                  text(" · "),
                  ui.link(config.path(config, "/data?all=1"), [
                    text(
                      "Show " <> int.to_string(hidden) <> " Howdy tables too",
                    ),
                  ]),
                ])
            },
          ]),
          ui.table([], [
            ui.table_header([], [
              ui.table_row([], [
                ui.table_head([], [text("Table")]),
                ui.table_head([], [text("Columns")]),
                ui.table_head([], [text("Rows")]),
              ]),
            ]),
            ui.table_body(
              [],
              list.map(tables, fn(entry) {
                let #(table, count) = entry
                ui.table_row([], [
                  ui.table_cell([], [
                    ui.link(table_path(config, table.name), [text(table.name)]),
                  ]),
                  ui.table_cell([], [
                    text(int.to_string(list.length(table.columns))),
                  ]),
                  ui.table_cell([], [text(int.to_string(count))]),
                ])
              }),
            ),
          ]),
        ],
      )
  }
}

fn show(config: Config, repo: Repo, ctx: Context) -> Response(Content) {
  use table <- with_table(config, repo, ctx)
  layout.page(
    config,
    ctx,
    current: "/data",
    heading: table.name,
    live: True,
    content: [
      ui.row([], [
        ui.link(config.path(config, "/data"), [text("All tables")]),
        ui.link(table_path(config, table.name) <> "/new", [text("Insert row")]),
      ]),
      live.mount(config.path(
        config,
        "/live/data/" <> uri.percent_encode(table.name),
      )),
      ui.card([], [
        ui.card_header([], [ui.card_title([text("Columns")])]),
        ui.card_content([], [
          ui.table([], [
            ui.table_header([], [
              ui.table_row([], [
                ui.table_head([], [text("Name")]),
                ui.table_head([], [text("Type")]),
                ui.table_head([], [text("Nullable")]),
                ui.table_head([], [text("Key")]),
              ]),
            ]),
            ui.table_body(
              [],
              list.map(table.columns, fn(column) {
                ui.table_row([], [
                  ui.table_cell([], [text(column.name)]),
                  ui.table_cell([], [text(column.kind)]),
                  ui.table_cell([], [text(yes_no(column.nullable))]),
                  ui.table_cell([], [text(yes_no(column.key))]),
                ])
              }),
            ),
          ]),
        ]),
      ]),
    ],
  )
}

fn new(config: Config, repo: Repo, ctx: Context) -> Response(Content) {
  use table <- with_table(config, repo, ctx)
  layout.page(
    config,
    ctx,
    current: "/data",
    heading: "Insert into " <> table.name,
    live: False,
    content: [
      ui.p([
        ui.muted(
          "Columns left empty take their default. Tick NULL to store a null.",
        ),
      ]),
      row_form(
        action: table_path(config, table.name),
        table:,
        row: None,
        submit: "Insert",
        cancel: table_path(config, table.name),
      ),
    ],
  )
}

fn create(config: Config, repo: Repo, ctx: Context) -> Response(Content) {
  use table <- with_table(config, repo, ctx)
  use form <- form.read(ctx)
  let values =
    list.filter_map(table.columns, fn(column) {
      case submitted(form, column) {
        Some(value) -> Ok(#(column, value))
        None -> Error(Nil)
      }
    })
  case schema.insert(repo, table, values) {
    Ok(Nil) -> layout.redirect(table_path(config, table.name))
    Error(error) ->
      layout.page(
        config,
        ctx,
        current: "/data",
        heading: "Insert into " <> table.name,
        live: False,
        content: [
          layout.problem(error),
          row_form(
            action: table_path(config, table.name),
            table:,
            row: Some(Row(
              key: [],
              cells: list.map(table.columns, fn(column) {
                option.flatten(submitted(form, column))
              }),
            )),
            submit: "Insert",
            cancel: table_path(config, table.name),
          ),
        ],
      )
  }
}

fn edit(config: Config, repo: Repo, ctx: Context) -> Response(Content) {
  use table <- with_table(config, repo, ctx)
  let key = key_from(ctx)
  case schema.row(repo, table, key) {
    Error(error) ->
      layout.failure(
        config,
        ctx,
        current: "/data",
        heading: table.name,
        error:,
        back: table_path(config, table.name),
      )
    Ok(row) ->
      layout.page(
        config,
        ctx,
        current: "/data",
        heading: "Edit " <> table.name <> " " <> string.join(row.key, ", "),
        live: False,
        content: [
          row_form(
            action: row_path(config, table.name, row.key),
            table:,
            row: Some(row),
            submit: "Save",
            cancel: table_path(config, table.name),
          ),
          html.form(
            [
              attribute.method("post"),
              attribute.action(
                row_path(config, table.name, row.key) <> "/delete",
              ),
            ],
            [ui.submit_button(button.Danger, [], [text("Delete row")])],
          ),
        ],
      )
  }
}

fn save(config: Config, repo: Repo, ctx: Context) -> Response(Content) {
  use table <- with_table(config, repo, ctx)
  let key = key_from(ctx)
  use form <- form.read(ctx)
  // Key columns are shown but not written; the key names the row.
  let editable = list.filter(table.columns, fn(column) { !column.key })
  let values =
    list.map(editable, fn(column) {
      #(column, case submitted(form, column) {
        Some(value) -> value
        None -> Some("")
      })
    })
  case schema.update(repo, table, key, values) {
    Ok(Nil) -> layout.redirect(table_path(config, table.name))
    Error(error) ->
      layout.page(
        config,
        ctx,
        current: "/data",
        heading: "Edit " <> table.name,
        live: False,
        content: [
          layout.problem(error),
          row_form(
            action: row_path(config, table.name, key),
            table:,
            row: Some(Row(
              key:,
              cells: list.map(table.columns, fn(column) {
                option.flatten(submitted(form, column))
              }),
            )),
            submit: "Save",
            cancel: table_path(config, table.name),
          ),
        ],
      )
  }
}

fn remove(config: Config, repo: Repo, ctx: Context) -> Response(Content) {
  use table <- with_table(config, repo, ctx)
  case schema.delete(repo, table, key_from(ctx)) {
    Ok(Nil) -> layout.redirect(table_path(config, table.name))
    Error(error) ->
      layout.failure(
        config,
        ctx,
        current: "/data",
        heading: table.name,
        error:,
        back: table_path(config, table.name),
      )
  }
}

fn socket(config: Config, repo: Repo, ctx: Context) -> Response(Content) {
  use table <- with_table(config, repo, ctx)
  live.serve(ctx, grid(), with: Args(config, repo, table))
}

// -- Forms -------------------------------------------------------------------

/// One input per column, with a NULL checkbox for nullable ones. Key
/// columns of an existing row are read-only.
fn row_form(
  action action: String,
  table table: Table,
  row row: Option(Row),
  submit submit: String,
  cancel cancel: String,
) -> Element(msg) {
  let cells = case row {
    Some(row) -> row.cells
    None -> list.map(table.columns, fn(_) { None })
  }
  let existing = case row {
    Some(Row(key: [_, ..], ..)) -> True
    _ -> False
  }
  html.form([attribute.method("post"), attribute.action(action)], [
    ui.stack(
      [],
      list.append(
        list.map2(table.columns, cells, fn(column, value) {
          let id = "column-" <> column.name
          let locked = existing && column.key
          ui.field([], [
            ui.label([attribute.for(id)], [
              text(column.name),
              text(" "),
              ui.muted(column.kind),
            ]),
            ui.input([
              attribute.id(id),
              attribute.name("value-" <> column.name),
              attribute.value(option.unwrap(value, "")),
              attribute.readonly(locked),
            ]),
            case column.nullable && !locked {
              True ->
                ui.choice(
                  ui.checkbox([
                    attribute.name("null-" <> column.name),
                    attribute.value("1"),
                    attribute.checked(value == None && row != None),
                  ]),
                  [text("NULL")],
                )
              False -> element.none()
            },
          ])
        }),
        [
          ui.row([], [
            ui.submit_button(button.Primary, [], [text(submit)]),
            ui.link(cancel, [text("Cancel")]),
          ]),
        ],
      ),
    ),
  ])
}

/// What the form said about a column: `None` when it was left empty and
/// should take its default, `Some(None)` for an explicit NULL.
fn submitted(form: form.Form, column: schema.Column) -> Option(Option(String)) {
  case
    form.get(form, "null-" <> column.name),
    form.get(form, "value-" <> column.name)
  {
    Ok(_), _ -> Some(None)
    _, Ok("") -> None
    _, Ok(value) -> Some(Some(value))
    _, Error(_) -> None
  }
}

fn with_table(
  config: Config,
  repo: Repo,
  ctx: Context,
  next: fn(Table) -> Response(Content),
) -> Response(Content) {
  let name = result.unwrap(controller.param(ctx, "table"), "")
  case schema.table(repo, name) {
    Ok(table) -> next(table)
    Error(error) ->
      layout.failure(
        config,
        ctx,
        current: "/data",
        heading: "Tables",
        error:,
        back: config.path(config, "/data"),
      )
  }
}

/// The row key from the `k` query parameters, one per key column.
fn key_from(ctx: Context) -> List(String) {
  request.get_query(ctx.request)
  |> result.unwrap([])
  |> list.filter_map(fn(pair) {
    case pair {
      #("k", value) -> Ok(value)
      _ -> Error(Nil)
    }
  })
}

fn table_path(config: Config, table: String) -> String {
  config.path(config, "/data/" <> uri.percent_encode(table))
}

fn row_path(config: Config, table: String, key: List(String)) -> String {
  table_path(config, table)
  <> "/row?"
  <> uri.query_to_string(list.map(key, fn(value) { #("k", value) }))
}

fn yes_no(flag: Bool) -> String {
  case flag {
    True -> "yes"
    False -> "no"
  }
}

// -- The live grid -----------------------------------------------------------

pub type Args {
  Args(config: Config, repo: Repo, table: Table)
}

pub type Model {
  Model(
    config: Config,
    repo: Repo,
    table: Table,
    query: schema.Query,
    total: Int,
    rows: List(Row),
    /// Keys of rows that changed recently, with when, in milliseconds.
    changed: Dict(List(String), Int),
    /// Whether anything has been loaded yet; the first load is not a change.
    loaded: Bool,
    /// Whether the database announces changes, so polling is only a backstop.
    notified: Bool,
    error: Option(service.Error),
  )
}

pub type Msg {
  /// Time to look again.
  Tick
  /// The database said the table changed.
  Changed
  /// Time to drop old change marks.
  Expire
  Go(Int)
  PerPage(String)
  Search(List(#(String, String)))
  ClearSearch
  SortBy(String)
  AddFilter(List(#(String, String)))
  RemoveFilter(Int)
  Delete(List(String))
}

pub fn grid() -> lustre.App(Args, Model, Msg) {
  lustre.application(init:, update:, view:)
}

fn init(args: Args) -> #(Model, Effect(Msg)) {
  let model =
    Model(
      config: args.config,
      repo: args.repo,
      table: args.table,
      query: schema.query(),
      total: 0,
      rows: [],
      changed: dict.new(),
      loaded: False,
      notified: False,
      error: None,
    )
  let notified =
    notify.available(args.repo)
    && notify.install(args.repo, args.table) == Ok(Nil)
  let model = load(Model(..model, notified:))
  #(model, case notified {
    True -> effect.batch([subscribe(args.repo, args.table), schedule(model)])
    False -> schedule(model)
  })
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  let query = model.query
  case msg {
    Tick -> #(load(model), schedule(model))
    Changed -> #(load(model), after(highlight_ms + 500, Expire))
    Expire -> #(prune(model), effect.none())
    Go(page) -> #(
      load(requery(
        model,
        schema.Query(..query, offset: { page - 1 } * query.limit),
      )),
      effect.none(),
    )
    PerPage(size) -> {
      let limit =
        int.parse(size) |> result.unwrap(query.limit) |> int.clamp(10, 500)
      #(
        load(requery(model, schema.Query(..query, limit:, offset: 0))),
        effect.none(),
      )
    }
    Search(fields) -> {
      let term = list.key_find(fields, "q") |> result.unwrap("")
      #(
        load(requery(model, schema.Query(..query, search: term, offset: 0))),
        effect.none(),
      )
    }
    ClearSearch -> #(
      load(requery(model, schema.Query(..query, search: "", offset: 0))),
      effect.none(),
    )
    SortBy(column) -> {
      let sort = case query.sort {
        Some(#(current, schema.Ascending)) if current == column ->
          Some(#(column, schema.Descending))
        Some(#(current, schema.Descending)) if current == column -> None
        _ -> Some(#(column, schema.Ascending))
      }
      #(load(requery(model, schema.Query(..query, sort:))), effect.none())
    }
    AddFilter(fields) -> {
      let filter = {
        let field = fn(name) {
          list.key_find(fields, name) |> result.unwrap("")
        }
        use operator <- result.try(schema.operator_from(field("operator")))
        use _ <- result.try(
          list.find(model.table.columns, fn(c) { c.name == field("column") }),
        )
        Ok(schema.Filter(field("column"), operator, field("value")))
      }
      case filter {
        Ok(filter) -> #(
          load(requery(
            model,
            schema.Query(
              ..query,
              filters: list.append(query.filters, [filter]),
              offset: 0,
            ),
          )),
          effect.none(),
        )
        Error(Nil) -> #(model, effect.none())
      }
    }
    RemoveFilter(index) -> {
      let filters =
        list.index_map(query.filters, fn(filter, at) { #(at, filter) })
        |> list.filter(fn(pair) { pair.0 != index })
        |> list.map(fn(pair) { pair.1 })
      #(
        load(requery(model, schema.Query(..query, filters:, offset: 0))),
        effect.none(),
      )
    }
    Delete(key) -> {
      let model = case schema.delete(model.repo, model.table, key) {
        Ok(Nil) -> model
        Error(error) -> Model(..model, error: Some(error))
      }
      #(load(model), effect.none())
    }
  }
}

/// A new query is a new view: nothing in it counts as changed.
fn requery(model: Model, query: schema.Query) -> Model {
  Model(..model, query:, loaded: False, changed: dict.new())
}

fn schedule(model: Model) -> Effect(Msg) {
  after(
    case model.notified {
      True -> fallback_ms
      False -> refresh_ms
    },
    Tick,
  )
}

fn after(milliseconds: Int, msg: Msg) -> Effect(Msg) {
  use dispatch <- effect.from
  process.spawn(fn() {
    process.sleep(milliseconds)
    dispatch(msg)
  })
  Nil
}

/// Hear the database name this table. The effect runs in the runtime's
/// process, so the listener follows the runtime's life.
fn subscribe(repo: Repo, table: Table) -> Effect(Msg) {
  use dispatch <- effect.from
  let name = table.name
  let _ =
    notify.subscribe(repo, process.self(), fn(changed) {
      case changed == name {
        True -> dispatch(Changed)
        False -> Nil
      }
    })
  Nil
}

fn now() -> Int {
  timestamp.system_time()
  |> timestamp.to_unix_seconds_and_nanoseconds
  |> fn(parts) { parts.0 * 1000 + parts.1 / 1_000_000 }
}

/// Forget marks older than `highlight_ms`.
fn prune(model: Model) -> Model {
  let now = now()
  Model(
    ..model,
    changed: dict.filter(model.changed, fn(_, since) {
      now - since < highlight_ms
    }),
  )
}

/// Read the current page again and note which rows differ from last time.
fn load(model: Model) -> Model {
  let loaded = {
    use total <- result.try(schema.count(model.repo, model.table, model.query))
    // A page past the end, after deletions or a narrower query, becomes the
    // last page.
    let pages = pages(total, model.query.limit)
    let offset = int.min(model.query.offset, { pages - 1 } * model.query.limit)
    let query = schema.Query(..model.query, offset:)
    use rows <- result.try(schema.rows(model.repo, model.table, query))
    Ok(#(total, rows, query))
  }
  case loaded {
    Error(error) -> Model(..model, error: Some(error))
    Ok(#(total, rows, query)) -> {
      let now = now()
      let changed = prune(model).changed
      let changed = case model.loaded {
        False -> changed
        True ->
          list.fold(rows, changed, fn(changed, row) {
            case list.contains(model.rows, row) {
              True -> changed
              False -> dict.insert(changed, row.key, now)
            }
          })
      }
      Model(..model, query:, total:, rows:, changed:, loaded: True, error: None)
    }
  }
}

fn pages(total: Int, per: Int) -> Int {
  int.max(1, { total + per - 1 } / per)
}

fn page(model: Model) -> Int {
  model.query.offset / model.query.limit + 1
}

fn view(model: Model) -> Element(Msg) {
  let table = model.table
  let pages = pages(model.total, model.query.limit)
  ui.stack([], [
    case model.error {
      Some(error) -> layout.problem(error)
      None -> element.none()
    },
    toolbar(model),
    ui.row([], [
      ui.muted(
        int.to_string(model.total)
        <> case model.query.search, model.query.filters {
          "", [] -> " rows"
          _, _ -> " matching rows"
        }
        <> " · page "
        <> int.to_string(page(model))
        <> " of "
        <> int.to_string(pages)
        <> case model.notified {
          True -> " · follows PostgreSQL NOTIFY"
          False -> " · refreshes every second"
        },
      ),
    ]),
    case model.rows {
      [] ->
        ui.empty(
          icon: text("∅"),
          title: case model.query.search, model.query.filters {
            "", [] -> "No rows"
            _, _ -> "Nothing matches"
          },
          description: case model.query.search, model.query.filters {
            "", [] ->
              "This table is empty. Insert a row, or watch here as your application writes one."
            _, _ -> "Clear the search or a filter to see more."
          },
          actions: [],
        )
      rows ->
        ui.table([], [
          ui.table_header([], [
            ui.table_row(
              [],
              list.append(
                list.map(table.columns, fn(column) {
                  ui.table_head([], [sort_button(model, column.name)])
                }),
                [ui.table_head([], [text("")])],
              ),
            ),
          ]),
          ui.table_body([], list.map(rows, row_view(model, _))),
        ])
    },
    case pages > 1 {
      True ->
        pagination.live_pagination(
          current: page(model),
          total: pages,
          attributes: fn(page) {
            [
              event.on_click(Go(page)) |> event.prevent_default,
              attribute.href("#"),
            ]
          },
        )
      False -> element.none()
    },
  ])
}

/// Search, filters and page size.
fn toolbar(model: Model) -> Element(Msg) {
  let query = model.query
  ui.stack([], [
    ui.row([], [
      html.form([event.on_submit(Search)], [
        ui.row([], [
          ui.input([
            attribute.type_("search"),
            attribute.name("q"),
            attribute.value(query.search),
            attribute.placeholder("search every column"),
            attribute.style("width", "20rem"),
          ]),
          ui.submit_button(button.Secondary, [], [text("Search")]),
          case query.search {
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
        [attribute.name("per"), live.on_value("per", PerPage)],
        list.map([10, 25, 50, 100, 250], fn(size) {
          html.option(
            [
              attribute.value(int.to_string(size)),
              attribute.selected(size == query.limit),
            ],
            int.to_string(size) <> " per page",
          )
        }),
      ),
    ]),
    html.form([event.on_submit(AddFilter)], [
      ui.row([], [
        ui.native_select(
          [attribute.name("column")],
          list.map(model.table.columns, fn(column) {
            html.option([attribute.value(column.name)], column.name)
          }),
        ),
        ui.native_select(
          [attribute.name("operator")],
          list.map(schema.operators(), fn(operator) {
            html.option(
              [attribute.value(schema.operator_name(operator))],
              schema.operator_label(operator),
            )
          }),
        ),
        ui.input([
          attribute.name("value"),
          attribute.placeholder("value"),
          attribute.style("width", "14rem"),
        ]),
        ui.submit_button(button.Outline, [], [text("Add filter")]),
      ]),
    ]),
    case query.filters {
      [] -> element.none()
      filters ->
        ui.row(
          [],
          list.index_map(filters, fn(filter, index) {
            ui.badge(badge.Secondary, [], [
              text(
                filter.column
                <> " "
                <> schema.operator_label(filter.operator)
                <> case filter.operator {
                  schema.IsNull | schema.NotNull -> ""
                  _ -> " " <> filter.value
                },
              ),
              text(" "),
              html.button(
                [
                  attribute.type_("button"),
                  attribute.aria_label("Remove filter"),
                  event.on_click(RemoveFilter(index)),
                ],
                [text("×")],
              ),
            ])
          }),
        )
    },
  ])
}

/// A column heading that sorts by the column: ascending, then descending,
/// then back to key order.
fn sort_button(model: Model, column: String) -> Element(Msg) {
  let indicator = case model.query.sort {
    Some(#(current, schema.Ascending)) if current == column -> " ▲"
    Some(#(current, schema.Descending)) if current == column -> " ▼"
    _ -> ""
  }
  ui.sized_button(
    button.Ghost,
    button.ExtraSmall,
    [event.on_click(SortBy(column))],
    [text(column <> indicator)],
  )
}

fn row_view(model: Model, row: Row) -> Element(Msg) {
  let recent = dict.has_key(model.changed, row.key)
  ui.table_row(
    [],
    list.append(
      list.map(row.cells, fn(cell) {
        ui.table_cell([], [
          case cell {
            Some(value) -> text(layout.clip(value))
            None -> ui.muted("NULL")
          },
        ])
      }),
      [
        ui.table_cell([], [
          ui.row([], [
            case recent {
              True -> ui.badge(badge.Primary, [], [text("changed")])
              False -> element.none()
            },
            ui.link(row_path(model.config, model.table.name, row.key), [
              text("Edit"),
            ]),
            ui.sized_button(
              button.Ghost,
              button.Small,
              [event.on_click(Delete(row.key))],
              [text("Delete")],
            ),
          ]),
        ]),
      ],
    ),
  )
}
