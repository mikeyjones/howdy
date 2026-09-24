//// The database pages: the list of tables, a live grid of each table's
//// rows, and forms to insert, edit and delete a row.

import ewe
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import gloo/repo.{type Repo}
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/layout
import howdy/admin/internal/schema.{type Row, type Table, Row}
import howdy/controller.{type Context, type Controller}
import howdy/database.{Postgres, Sqlite}
import howdy/form
import howdy/service
import howdy/ui
import howdy/ui/badge
import howdy/ui/button
import howdy/ui/live
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event

const per_page = 50

/// How often the grid checks the table for changes, in milliseconds.
const refresh_ms = 1000

/// How many refreshes a changed row stays marked for.
const highlight_ticks = 4

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

fn index(config: Config, repo: Repo, ctx: Context) -> Response(ewe.Body) {
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
        use count <- result.try(schema.count(repo, table))
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

fn show(config: Config, repo: Repo, ctx: Context) -> Response(ewe.Body) {
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

fn new(config: Config, repo: Repo, ctx: Context) -> Response(ewe.Body) {
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

fn create(config: Config, repo: Repo, ctx: Context) -> Response(ewe.Body) {
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

fn edit(config: Config, repo: Repo, ctx: Context) -> Response(ewe.Body) {
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

fn save(config: Config, repo: Repo, ctx: Context) -> Response(ewe.Body) {
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

fn remove(config: Config, repo: Repo, ctx: Context) -> Response(ewe.Body) {
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

fn socket(config: Config, repo: Repo, ctx: Context) -> Response(ewe.Body) {
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
  next: fn(Table) -> Response(ewe.Body),
) -> Response(ewe.Body) {
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
    page: Int,
    total: Int,
    rows: List(Row),
    /// Keys of rows that changed recently, with the tick they changed on.
    changed: Dict(List(String), Int),
    tick: Int,
    error: Option(service.Error),
  )
}

pub type Msg {
  Tick
  Go(Int)
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
      page: 1,
      total: 0,
      rows: [],
      changed: dict.new(),
      tick: 0,
      error: None,
    )
  #(load(model), schedule())
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Tick -> #(load(Model(..model, tick: model.tick + 1)), schedule())
    Go(page) -> #(load(Model(..model, page: page)), effect.none())
    Delete(key) -> {
      let model = case schema.delete(model.repo, model.table, key) {
        Ok(Nil) -> model
        Error(error) -> Model(..model, error: Some(error))
      }
      #(load(model), effect.none())
    }
  }
}

fn schedule() -> Effect(Msg) {
  use dispatch <- effect.from
  process.spawn(fn() {
    process.sleep(refresh_ms)
    dispatch(Tick)
  })
  Nil
}

/// Read the current page again and note which rows differ from last time.
fn load(model: Model) -> Model {
  let pages = pages(model.total)
  let page = int.clamp(model.page, 1, pages)
  let loaded = {
    use total <- result.try(schema.count(model.repo, model.table))
    use rows <- result.try(schema.rows(
      model.repo,
      model.table,
      limit: per_page,
      offset: { page - 1 } * per_page,
    ))
    Ok(#(total, rows))
  }
  case loaded {
    Error(error) -> Model(..model, error: Some(error))
    Ok(#(total, rows)) -> {
      let changed =
        model.changed
        |> dict.filter(fn(_, since) { model.tick - since < highlight_ticks })
      let changed = case model.tick {
        // The first load is not a change.
        0 -> changed
        _ ->
          list.fold(rows, changed, fn(changed, row) {
            case list.contains(model.rows, row) {
              True -> changed
              False -> dict.insert(changed, row.key, model.tick)
            }
          })
      }
      Model(..model, page:, total:, rows:, changed:, error: None)
    }
  }
}

fn pages(total: Int) -> Int {
  int.max(1, { total + per_page - 1 } / per_page)
}

fn view(model: Model) -> Element(Msg) {
  let table = model.table
  let pages = pages(model.total)
  ui.stack([], [
    case model.error {
      Some(error) -> layout.problem(error)
      None -> element.none()
    },
    ui.row([], [
      ui.muted(
        int.to_string(model.total)
        <> " rows · page "
        <> int.to_string(model.page)
        <> " of "
        <> int.to_string(pages)
        <> " · refreshes every second",
      ),
      ui.sized_button(
        button.Outline,
        button.Small,
        [
          event.on_click(Go(model.page - 1)),
          attribute.disabled(model.page <= 1),
        ],
        [text("Previous")],
      ),
      ui.sized_button(
        button.Outline,
        button.Small,
        [
          event.on_click(Go(model.page + 1)),
          attribute.disabled(model.page >= pages),
        ],
        [text("Next")],
      ),
    ]),
    case model.rows {
      [] ->
        ui.empty(
          icon: text("∅"),
          title: "No rows",
          description: "This table is empty. Insert a row, or watch here as your application writes one.",
          actions: [],
        )
      rows ->
        ui.table([], [
          ui.table_header([], [
            ui.table_row(
              [],
              list.append(
                list.map(table.columns, fn(column) {
                  ui.table_head([], [text(column.name)])
                }),
                [ui.table_head([], [text("")])],
              ),
            ),
          ]),
          ui.table_body([], list.map(rows, row_view(model, _))),
        ])
    },
  ])
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
