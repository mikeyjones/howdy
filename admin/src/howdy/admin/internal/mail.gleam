//// The mail pages: the outbox as messages arrive, each message rendered,
//// and email previews built from sample data.

import ewe
import gleam/bit_array
import gleam/bytes_tree
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import gleam/uri
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/layout
import howdy/controller.{type Context, type Controller}
import howdy/mail.{type Address, type Mailer, type Outgoing}
import howdy/mail/mime
import howdy/mail/outbox.{type Outbox}
import howdy/mail/preview.{type Preview}
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

pub fn controller(config: Config) -> Controller {
  controller.new(config.prefix)
  |> controller.get("/mail", fn(ctx) { outbox_page(config, ctx) })
  |> controller.post("/mail/clear", fn(_) { clear(config) })
  |> controller.get("/mail/message/:id", fn(ctx) { message_page(config, ctx) })
  |> controller.get("/mail/message/:id/html", fn(ctx) {
    use outgoing <- with_message(config, ctx)
    html_response(outgoing)
  })
  |> controller.get("/mail/message/:id/source", fn(ctx) {
    use outgoing <- with_message(config, ctx)
    source_response(outgoing)
  })
  |> controller.get("/mail/message/:id/attachment/:index", fn(ctx) {
    use outgoing <- with_message(config, ctx)
    attachment_response(outgoing, ctx)
  })
  |> controller.get("/mail/previews", fn(ctx) { previews_page(config, ctx) })
  |> controller.get("/mail/previews/html", fn(ctx) {
    use outgoing <- with_preview(config, ctx)
    html_response(outgoing)
  })
  |> controller.post("/mail/previews/send", fn(ctx) {
    send_preview(config, ctx)
  })
  |> controller.get("/live/mail", fn(ctx) { socket(config, ctx) })
}

// -- The outbox --------------------------------------------------------------

fn outbox_page(config: Config, ctx: Context) -> Response(ewe.Body) {
  case config.outbox {
    None -> layout.redirect(config.path(config, "/mail/previews"))
    Some(box) ->
      layout.page(
        config,
        ctx,
        current: "/mail",
        heading: "Outbox",
        live: True,
        content: [
          ui.p([
            ui.muted(case outbox.directory(box) {
              Some(directory) ->
                "Mail sent through the outbox adapter, also written to "
                <> directory
                <> ". The newest "
                <> int.to_string(outbox.capacity)
                <> " are kept."
              None ->
                "Mail sent through the outbox adapter, kept in memory until the app stops. The newest "
                <> int.to_string(outbox.capacity)
                <> " are kept."
            }),
          ]),
          live.mount(config.path(config, "/live/mail")),
        ],
      )
  }
}

fn clear(config: Config) -> Response(ewe.Body) {
  case config.outbox {
    Some(box) -> outbox.clear(box)
    None -> Nil
  }
  layout.redirect(config.path(config, "/mail"))
}

fn socket(config: Config, ctx: Context) -> Response(ewe.Body) {
  case config.outbox {
    Some(box) -> live.serve(ctx, list_app(), with: Args(config, box))
    None -> layout.redirect(config.path(config, "/mail/previews"))
  }
}

pub type Args {
  Args(config: Config, box: Outbox)
}

pub type Model {
  Model(config: Config, box: Outbox, messages: List(Outgoing))
}

pub type Msg {
  /// A message arrived or the outbox was cleared.
  Changed
  Clear
}

fn list_app() -> lustre.App(Args, Model, Msg) {
  lustre.application(
    init: fn(args: Args) {
      #(
        Model(args.config, args.box, outbox.messages(args.box)),
        subscribe(args.box),
      )
    },
    update: fn(model: Model, msg) {
      case msg {
        Changed -> #(
          Model(..model, messages: outbox.messages(model.box)),
          effect.none(),
        )
        Clear -> {
          outbox.clear(model.box)
          #(Model(..model, messages: []), effect.none())
        }
      }
    },
    view: list_view,
  )
}

/// The effect runs in the runtime's process, so the outbox drops the
/// subscription when the page goes away.
fn subscribe(box: Outbox) -> Effect(Msg) {
  use dispatch <- effect.from
  outbox.subscribe(box, fn() { dispatch(Changed) })
}

fn list_view(model: Model) -> Element(Msg) {
  let config = model.config
  case model.messages {
    [] ->
      ui.empty(
        icon: text("✉"),
        title: "No mail yet",
        description: "Messages your app sends appear here as they are sent.",
        actions: case config.mailer {
          Some(_) -> [
            ui.link(config.path(config, "/mail/previews"), [
              text("Send a preview"),
            ]),
          ]
          None -> []
        },
      )
    messages ->
      ui.stack([], [
        ui.row([], [
          ui.muted(describe(list.length(messages), "message")),
          ui.button(button.Outline, [event.on_click(Clear)], [
            text("Clear all"),
          ]),
        ]),
        ui.table([], [
          ui.table_header([], [
            ui.table_row([], [
              ui.table_head([], [text("Sent")]),
              ui.table_head([], [text("To")]),
              ui.table_head([], [text("Subject")]),
              ui.table_head([], [text("Tags")]),
            ]),
          ]),
          ui.table_body(
            [],
            list.map(messages, fn(outgoing) {
              let href = config.path(config, "/mail/message/" <> outgoing.id)
              ui.table_row([], [
                ui.table_cell([], [text(when(outgoing))]),
                ui.table_cell([], [
                  text(layout.clip(addresses(mail.recipients(outgoing)))),
                ]),
                ui.table_cell([], [
                  ui.link(href, [text(layout.clip(outgoing.subject))]),
                ]),
                ui.table_cell([], [tags(outgoing.tags)]),
              ])
            }),
          ),
        ]),
      ])
  }
}

// -- One message -------------------------------------------------------------

fn message_page(config: Config, ctx: Context) -> Response(ewe.Body) {
  use outgoing <- with_message(config, ctx)
  let base = config.path(config, "/mail/message/" <> outgoing.id)
  let width = width_of(ctx)
  layout.page(
    config,
    ctx,
    current: "/mail",
    heading: outgoing.subject,
    live: False,
    content: [
      ui.row([], [ui.link(config.path(config, "/mail"), [text("Outbox")])]),
      ..message_view(
        outgoing,
        html_src: base <> "/html",
        source: Some(base <> "/source"),
        attachment: fn(index) {
          Some(base <> "/attachment/" <> int.to_string(index))
        },
        width:,
        width_href: fn(width) { base <> "?width=" <> width },
      )
    ],
  )
}

fn with_message(
  config: Config,
  ctx: Context,
  next: fn(Outgoing) -> Response(ewe.Body),
) -> Response(ewe.Body) {
  let id = controller.param(ctx, "id") |> result.unwrap("")
  let found = case config.outbox {
    Some(box) -> outbox.get(box, id)
    None -> Error(Nil)
  }
  case found {
    Ok(outgoing) -> next(outgoing)
    Error(Nil) ->
      layout.page(
        config,
        ctx,
        current: "/mail",
        heading: "Not found",
        live: False,
        content: [
          notice(
            alert.Danger,
            "No such message",
            "The outbox no longer has it: it was cleared, or pushed out by newer mail.",
          ),
          ui.p([ui.link(config.path(config, "/mail"), [text("Outbox")])]),
        ],
      )
  }
}

/// The envelope, attachments, and the body as HTML, text and source.
fn message_view(
  outgoing: Outgoing,
  html_src html_src: String,
  source source: Option(String),
  attachment attachment: fn(Int) -> Option(String),
  width width: String,
  width_href width_href: fn(String) -> String,
) -> List(Element(msg)) {
  let field = fn(name, value) {
    ui.table_row([], [
      ui.table_head([attribute.attribute("scope", "row")], [text(name)]),
      ui.table_cell([], [value]),
    ])
  }
  let optional = fn(name, list: List(Address)) {
    case list {
      [] -> element.none()
      list -> field(name, text(addresses(list)))
    }
  }
  [
    ui.card([], [
      ui.card_content([], [
        ui.table([], [
          ui.table_body([], [
            field("From", text(mail.address_to_string(outgoing.from))),
            optional("To", outgoing.to),
            optional("Cc", outgoing.cc),
            optional("Bcc", outgoing.bcc),
            case outgoing.reply_to {
              Some(address) ->
                field("Reply-To", text(mail.address_to_string(address)))
              None -> element.none()
            },
            field("Date", text(when(outgoing))),
            field("Subject", text(outgoing.subject)),
            case outgoing.tags {
              [] -> element.none()
              list -> field("Tags", tags(list))
            },
            ..list.map(outgoing.headers, fn(header) {
              field(header.0, text(header.1))
            })
          ]),
        ]),
      ]),
    ]),
    case outgoing.attachments {
      [] -> element.none()
      attachments ->
        ui.card([], [
          ui.card_header([], [ui.card_title([text("Attachments")])]),
          ui.card_content([], [
            html.ul(
              [],
              list.index_map(attachments, fn(file: mail.Attachment, index) {
                let label =
                  file.filename
                  <> " · "
                  <> file.content_type
                  <> " · "
                  <> size(bit_array.byte_size(file.content))
                  <> case file.content_id {
                    Some(id) -> " · inline as cid:" <> id
                    None -> ""
                  }
                html.li([], [
                  case attachment(index) {
                    Some(href) -> ui.link(href, [text(label)])
                    None -> text(label)
                  },
                ])
              }),
            ),
          ]),
        ])
    },
    ui.tabs(
      "message",
      selected: case outgoing.html {
        Some(_) -> "html"
        None -> "text"
      },
      attributes: [],
      tabs: list.flatten([
        case outgoing.html {
          Some(_) -> [
            ui.tab("html", [], label: [text("HTML")], panel: [
              ui.stack([], [
                ui.row([], [
                  width_link("Desktop", "desktop", width, width_href),
                  width_link("Mobile", "mobile", width, width_href),
                  ui.link(html_src, [text("Open alone")]),
                ]),
                html.iframe([
                  attribute.src(html_src),
                  attribute.title("The message's HTML"),
                  // No scripts, no forms, no same-origin access; links open
                  // in a new tab.
                  attribute.attribute(
                    "sandbox",
                    "allow-popups allow-popups-to-escape-sandbox",
                  ),
                  attribute.attribute("referrerpolicy", "no-referrer"),
                  attribute.style("width", case width {
                    "mobile" -> "375px"
                    _ -> "100%"
                  }),
                  attribute.style("height", "70vh"),
                  attribute.style(
                    "border",
                    "1px solid var(--howdy-border, #ddd)",
                  ),
                  attribute.style("border-radius", "0.5rem"),
                  attribute.style("background", "white"),
                ]),
              ]),
            ]),
          ]
          None -> []
        },
        case outgoing.text {
          Some(body) -> [
            ui.tab("text", [], label: [text("Text")], panel: [
              monospace(linkify(body)),
            ]),
          ]
          None -> []
        },
        [
          ui.tab("source", [], label: [text("Source")], panel: [
            ui.stack([], [
              case source {
                Some(href) ->
                  ui.row([], [ui.link(href, [text("Download .eml")])])
                None -> element.none()
              },
              monospace([text(string.slice(mime.encode(outgoing), 0, 200_000))]),
            ]),
          ]),
        ],
      ]),
    ),
  ]
}

fn width_link(
  label: String,
  value: String,
  current: String,
  href: fn(String) -> String,
) -> Element(msg) {
  case value == current {
    True -> html.strong([], [text(label)])
    False -> ui.link(href(value), [text(label)])
  }
}

fn width_of(ctx: Context) -> String {
  case query(ctx, "width") {
    Ok("mobile") -> "mobile"
    _ -> "desktop"
  }
}

fn monospace(children: List(Element(msg))) -> Element(msg) {
  html.pre(
    [
      attribute.style("white-space", "pre-wrap"),
      attribute.style("overflow-wrap", "anywhere"),
      attribute.style("font-family", "ui-monospace, monospace"),
      attribute.style("font-size", "0.8125rem"),
      attribute.style("margin", "0"),
    ],
    children,
  )
}

/// Plain text with its `http` and `https` URLs as links, so a sign-in link
/// can be followed from here.
fn linkify(body: String) -> List(Element(msg)) {
  string.split(body, "\n")
  |> list.map(fn(line) {
    string.split(line, " ")
    |> list.map(fn(word) {
      case
        string.starts_with(word, "https://")
        || string.starts_with(word, "http://")
      {
        True ->
          html.a(
            [
              attribute.href(word),
              attribute.target("_blank"),
              attribute.rel("noreferrer"),
            ],
            [text(word)],
          )
        False -> text(word)
      }
    })
    |> list.intersperse(text(" "))
  })
  |> list.intersperse([text("\n")])
  |> list.flatten
}

/// The message's HTML on its own, for the frame. Inline attachments become
/// `data:` URLs so `cid:` images show, and links open in a new tab. The
/// content security policy repeats the frame's sandbox, so opening this URL
/// directly runs no script either.
fn html_response(outgoing: Outgoing) -> Response(ewe.Body) {
  let body =
    option.unwrap(outgoing.html, "")
    |> inline_images(outgoing.attachments)
    |> with_base
  response.new(200)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_header(
    "content-security-policy",
    "sandbox allow-popups allow-popups-to-escape-sandbox; default-src 'none'; img-src * data:; style-src * 'unsafe-inline'; font-src * data:",
  )
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_header("referrer-policy", "no-referrer")
  |> response.set_body(ewe.Text(body))
}

fn inline_images(html: String, attachments: List(mail.Attachment)) -> String {
  list.fold(attachments, html, fn(html, file) {
    case file.content_id {
      Some(id) ->
        string.replace(
          html,
          "cid:" <> id,
          "data:"
            <> file.content_type
            <> ";base64,"
            <> bit_array.base64_encode(file.content, True),
        )
      None -> html
    }
  })
}

fn with_base(html: String) -> String {
  let base = "<base target=\"_blank\">"
  case string.split_once(html, "<head>") {
    Ok(#(before, after)) -> before <> "<head>" <> base <> after
    Error(Nil) -> base <> html
  }
}

fn source_response(outgoing: Outgoing) -> Response(ewe.Body) {
  response.new(200)
  |> response.set_header("content-type", "message/rfc822")
  |> response.set_header(
    "content-disposition",
    "attachment; filename=\"" <> outgoing.id <> ".eml\"",
  )
  |> response.set_body(ewe.Text(mime.encode(outgoing)))
}

fn attachment_response(outgoing: Outgoing, ctx: Context) -> Response(ewe.Body) {
  let found = {
    use index <- result.try(
      controller.param(ctx, "index") |> result.try(int.parse),
    )
    list.drop(outgoing.attachments, index) |> list.first
  }
  case found {
    Ok(file) ->
      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_header(
        "content-disposition",
        "attachment; filename=\""
          <> string.replace(file.filename, "\"", "")
          <> "\"",
      )
      |> response.set_header("x-content-type-options", "nosniff")
      |> response.set_body(ewe.Bytes(bytes_tree.from_bit_array(file.content)))
    Error(Nil) ->
      response.new(404) |> response.set_body(ewe.Text("No such attachment"))
  }
}

// -- Previews ----------------------------------------------------------------

fn previews_page(config: Config, ctx: Context) -> Response(ewe.Body) {
  let page = fn(heading, content) {
    layout.page(
      config,
      ctx,
      current: "/mail/previews",
      heading:,
      live: False,
      content:,
    )
  }
  case config.mailer, config.previews {
    None, _ ->
      page("Previews", [
        notice(
          alert.Info,
          "No previews registered",
          "Pass your previews and a mailer to admin.mail_previews.",
        ),
      ])
    Some(_), [] ->
      page("Previews", [
        notice(
          alert.Info,
          "No previews registered",
          "admin.mail_previews was given an empty list. Build previews with howdy/mail/preview.",
        ),
      ])
    Some(mailer), [first, ..] as previews -> {
      let selected =
        query(ctx, "p")
        |> result.try(preview.find(previews, _))
        |> result.unwrap(first)
      let key = preview.key(selected)
      let base = config.path(config, "/mail/previews")
      let width = width_of(ctx)
      page(preview.group(selected) <> " · " <> preview.name(selected), [
        html.div(
          [
            attribute.style("display", "grid"),
            attribute.style("grid-template-columns", "minmax(12rem, 16rem) 1fr"),
            attribute.style("gap", "1.5rem"),
            attribute.style("align-items", "start"),
          ],
          [
            index(previews, selected, base, width),
            ui.stack([], [
              case query(ctx, "sent") {
                Ok(adapter) ->
                  notice(alert.Info, "Sent", "Delivered by " <> adapter <> ".")
                Error(Nil) -> element.none()
              },
              ..case render(mailer, selected) {
                Error(problem) -> [problem]
                Ok(outgoing) -> [
                  html.form(
                    [
                      attribute.method("post"),
                      attribute.action(
                        base <> "/send?p=" <> uri.percent_encode(key),
                      ),
                    ],
                    [
                      ui.row([], [
                        ui.submit_button(button.Primary, [], [
                          text(case config.outbox {
                            Some(_) -> "Send to outbox"
                            None -> "Send"
                          }),
                        ]),
                        ui.muted(
                          "Through "
                          <> mail.adapter_name(mail.mailer_adapter(mailer)),
                        ),
                      ]),
                    ],
                  ),
                  ..message_view(
                    outgoing,
                    html_src: base <> "/html?p=" <> uri.percent_encode(key),
                    source: None,
                    attachment: fn(_) { None },
                    width:,
                    width_href: fn(width) {
                      base
                      <> "?p="
                      <> uri.percent_encode(key)
                      <> "&width="
                      <> width
                    },
                  )
                ]
              }
            ]),
          ],
        ),
      ])
    }
  }
}

/// The previews by group, the selected one marked.
fn index(
  previews: List(Preview),
  selected: Preview,
  base: String,
  width: String,
) -> Element(msg) {
  let groups =
    list.fold(previews, [], fn(groups, preview) {
      case list.contains(groups, preview.group(preview)) {
        True -> groups
        False -> list.append(groups, [preview.group(preview)])
      }
    })
  ui.card([], [
    ui.card_content(
      [],
      list.map(groups, fn(group) {
        html.nav([attribute.attribute("aria-label", group)], [
          html.h3([attribute.style("margin", "0.5rem 0 0.25rem")], [text(group)]),
          html.ul(
            [
              attribute.style("margin", "0"),
              attribute.style("padding-left", "1rem"),
            ],
            list.filter(previews, fn(p) { preview.group(p) == group })
              |> list.map(fn(p) {
                let href =
                  base
                  <> "?p="
                  <> uri.percent_encode(preview.key(p))
                  <> "&width="
                  <> width
                html.li([], [
                  case preview.key(p) == preview.key(selected) {
                    True ->
                      html.strong(
                        [attribute.attribute("aria-current", "page")],
                        [
                          text(preview.name(p)),
                        ],
                      )
                    False -> ui.link(href, [text(preview.name(p))])
                  },
                ])
              }),
          ),
        ])
      }),
    ),
  ])
}

/// The preview as it would be sent, or why it cannot be.
fn render(mailer: Mailer, selected: Preview) -> Result(Outgoing, Element(msg)) {
  use message <- result.try(
    preview.build(selected)
    |> result.map_error(fn(reason) {
      notice(alert.Danger, "The template crashed", reason)
    }),
  )
  mail.prepare(mailer, message)
  |> result.map_error(fn(error) {
    notice(
      alert.Danger,
      "This message would not be sent",
      mail.error_to_string(error),
    )
  })
}

fn with_preview(
  config: Config,
  ctx: Context,
  next: fn(Outgoing) -> Response(ewe.Body),
) -> Response(ewe.Body) {
  let found = {
    use mailer <- result.try(option.to_result(config.mailer, Nil))
    use key <- result.try(query(ctx, "p"))
    use selected <- result.try(preview.find(config.previews, key))
    render(mailer, selected) |> result.replace_error(Nil)
  }
  case found {
    Ok(outgoing) -> next(outgoing)
    Error(Nil) ->
      response.new(404) |> response.set_body(ewe.Text("No such preview"))
  }
}

fn send_preview(config: Config, ctx: Context) -> Response(ewe.Body) {
  let base = config.path(config, "/mail/previews")
  let sent = {
    use mailer <- result.try(option.to_result(
      config.mailer,
      "No mailer was registered.",
    ))
    use key <- result.try(
      query(ctx, "p") |> result.replace_error("No preview was chosen."),
    )
    use selected <- result.try(
      preview.find(config.previews, key)
      |> result.replace_error("There is no preview " <> key <> "."),
    )
    use message <- result.try(preview.build(selected))
    use receipt <- result.try(
      mail.send(mailer, message) |> result.map_error(mail.error_to_string),
    )
    Ok(#(key, mailer, receipt))
  }
  case sent {
    Ok(#(key, mailer, receipt)) ->
      case config.outbox {
        Some(box) ->
          case outbox.get(box, receipt.id) {
            Ok(_) ->
              layout.redirect(config.path(
                config,
                "/mail/message/" <> receipt.id,
              ))
            Error(Nil) -> back_to(base, key, mailer)
          }
        None -> back_to(base, key, mailer)
      }
    Error(reason) ->
      layout.page(
        config,
        ctx,
        current: "/mail/previews",
        heading: "Not sent",
        live: False,
        content: [
          notice(alert.Danger, "The preview was not sent", reason),
          ui.p([ui.link(base, [text("Previews")])]),
        ],
      )
  }
}

fn back_to(base: String, key: String, mailer: Mailer) -> Response(ewe.Body) {
  layout.redirect(
    base
    <> "?p="
    <> uri.percent_encode(key)
    <> "&sent="
    <> uri.percent_encode(mail.adapter_name(mail.mailer_adapter(mailer))),
  )
}

// -- Helpers -----------------------------------------------------------------

fn query(ctx: Context, name: String) -> Result(String, Nil) {
  request.get_query(ctx.request)
  |> result.unwrap([])
  |> list.key_find(name)
}

fn notice(
  variant: alert.Variant,
  title: String,
  description: String,
) -> Element(msg) {
  ui.alert(variant, [], [
    ui.alert_title([text(title)]),
    ui.alert_description([text(description)]),
  ])
}

fn addresses(list: List(Address)) -> String {
  list.map(list, mail.address_to_string) |> string.join(", ")
}

fn tags(list: List(String)) -> Element(msg) {
  ui.row(
    [],
    list.map(list, fn(tag) { ui.badge(badge.Secondary, [], [text(tag)]) }),
  )
}

/// `2026-09-25 14:03:07`, in UTC.
fn when(outgoing: Outgoing) -> String {
  timestamp.to_rfc3339(outgoing.date, calendar.utc_offset)
  |> string.slice(0, 19)
  |> string.replace("T", " ")
}

fn size(bytes: Int) -> String {
  case bytes {
    _ if bytes < 1024 -> int.to_string(bytes) <> " B"
    _ if bytes < 1_048_576 -> int.to_string(bytes / 1024) <> " KB"
    _ -> int.to_string(bytes / 1_048_576) <> " MB"
  }
}

fn describe(count: Int, noun: String) -> String {
  int.to_string(count)
  <> " "
  <> case count {
    1 -> noun
    _ -> noun <> "s"
  }
}
