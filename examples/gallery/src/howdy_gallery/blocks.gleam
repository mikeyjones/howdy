//// Blocks: whole screens and cards composed from howdy_ui components.
//// Copy one into your app and change it; nothing here is special.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import howdy/ui
import howdy/ui/alert
import howdy/ui/button.{Ghost, Icon, Outline, Primary}
import howdy/ui/command
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html

// -- Application shell -------------------------------------------------------

/// A page in the app: the sidebar, a top bar with the page title, and the
/// content. `active` is the path of the page, to mark its link.
pub fn app_shell(
  collapsed collapsed: Bool,
  active active: String,
  title title: String,
  content content: List(Element(msg)),
) -> Element(msg) {
  ui.sidebar_layout(
    collapsed:,
    attributes: [],
    sidebar: ui.sidebar("app-nav", [attribute.aria_label("Main")], [
      ui.sidebar_header([text("Howdy gallery")]),
      ui.sidebar_content([
        ui.sidebar_group("App", [
          nav_link("/", "Dashboard", active),
          nav_link("/components", "Components", active),
        ]),
        ui.sidebar_group("Account", [
          nav_link("/sign-in", "Sign in", active),
          nav_link("/sign-up", "Sign up", active),
        ]),
      ]),
      ui.sidebar_footer([ui.muted("ada@example.com")]),
    ]),
    main: [
      html.header([attribute.class("gallery-topbar")], [
        ui.row([], [
          ui.sized_button(
            Ghost,
            Icon,
            [
              attribute.aria_label("Toggle sidebar"),
              ..ui.sidebar_trigger("app-nav")
            ],
            [text("☰")],
          ),
          html.h1([attribute.class("gallery-title")], [text(title)]),
        ]),
        ui.row([], [
          ui.button(
            Outline,
            [
              attribute.aria_keyshortcuts("Meta+K Control+K"),
              ..ui.dialog_trigger("search")
            ],
            [text("Search"), html.kbd([], [text("⌘K")])],
          ),
          ui.theme_toggle([text("Theme")], from: "light", to: "dark"),
        ]),
      ]),
      html.div([attribute.class("gallery-content")], content),
      search(),
    ],
  )
}

fn nav_link(href: String, label: String, active: String) -> Element(msg) {
  ui.sidebar_link(href, active: href == active, attributes: [], children: [
    text(label),
  ])
}

/// The ⌘K command menu: every page, searchable.
fn search() -> Element(msg) {
  ui.command_dialog(
    "search",
    shortcut: "k",
    attributes: [],
    command: ui.command(
      "search-input",
      placeholder: "Search pages…",
      attributes: [],
      children: [
        ui.command_group("Pages", [
          ui.command_link("/", [], [text("Dashboard")]),
          ui.command_link(
            "/components",
            [command.keywords("calendar table chart")],
            [
              text("Components"),
            ],
          ),
        ]),
        ui.command_group("Account", [
          ui.command_link("/sign-in", [command.keywords("log in login")], [
            text("Sign in"),
          ]),
          ui.command_link(
            "/sign-up",
            [command.keywords("register create account")],
            [
              text("Sign up"),
            ],
          ),
        ]),
        ui.command_empty([text("No pages match.")]),
      ],
    ),
  )
}

// -- Stat cards --------------------------------------------------------------

/// A headline number with its change against a named period.
pub fn stat_card(
  label label: String,
  value value: String,
  change change: String,
) -> Element(msg) {
  ui.card([], [
    ui.stack([attribute.style("gap", "0.25rem")], [
      ui.muted(label),
      html.div([attribute.class("gallery-stat")], [text(value)]),
      ui.muted(change),
    ]),
  ])
}

// -- Authentication ----------------------------------------------------------

/// A centred card on an otherwise empty screen, for sign-in and sign-up.
pub fn auth_screen(card: Element(msg)) -> Element(msg) {
  html.main([attribute.class("gallery-auth")], [card])
}

pub fn sign_in_card(email email: String) -> Element(msg) {
  ui.card([attribute.class("gallery-auth-card")], [
    ui.card_header([], [
      ui.card_title([html.h1([], [text("Sign in")])]),
      ui.card_description([text("Welcome back. Enter your email to continue.")]),
    ]),
    html.form([attribute.method("post"), attribute.action("/sign-in")], [
      ui.field([], [
        ui.label([attribute.for("email")], [text("Email")]),
        ui.input([
          attribute.id("email"),
          attribute.type_("email"),
          attribute.name("email"),
          attribute.value(email),
          attribute.autocomplete("email"),
          attribute.required(True),
        ]),
      ]),
      ui.field([], [
        ui.row([attribute.style("justify-content", "space-between")], [
          ui.label([attribute.for("password")], [text("Password")]),
          ui.link("/sign-in", [text("Forgot password?")]),
        ]),
        ui.input([
          attribute.id("password"),
          attribute.type_("password"),
          attribute.name("password"),
          attribute.autocomplete("current-password"),
          attribute.required(True),
        ]),
      ]),
      ui.field([], [
        ui.choice(ui.checkbox([attribute.name("remember")]), [
          text("Keep me signed in"),
        ]),
      ]),
      ui.button(
        Primary,
        [attribute.type_("submit"), attribute.style("width", "100%")],
        [text("Sign in")],
      ),
    ]),
    ui.card_footer([], [
      ui.muted("No account yet?"),
      ui.link("/sign-up", [text("Sign up")]),
    ]),
  ])
}

/// What the sign-up form was given, and what was wrong with it.
pub type SignUp {
  SignUp(
    name: String,
    email: String,
    plan: String,
    terms: Bool,
    errors: List(#(String, String)),
  )
}

pub fn blank_sign_up() -> SignUp {
  SignUp(name: "", email: "", plan: "", terms: False, errors: [])
}

pub fn sign_up_card(form: SignUp) -> Element(msg) {
  let error = fn(name) {
    list.key_find(form.errors, name) |> option.from_result
  }
  ui.card([attribute.class("gallery-auth-card")], [
    ui.card_header([], [
      ui.card_title([html.h1([], [text("Create an account")])]),
      ui.card_description([text("It takes a minute. No card needed.")]),
    ]),
    case form.errors {
      [] -> element.none()
      _ ->
        ui.alert(alert.Danger, [attribute.role("alert")], [
          ui.alert_title([text("Check the highlighted fields")]),
          ui.alert_description([
            text("Some of what you entered needs another look."),
          ]),
        ])
    },
    html.form(
      [
        attribute.method("post"),
        attribute.action("/sign-up"),
        attribute.novalidate(True),
      ],
      [
        text_field(
          "name",
          "Name",
          form.name,
          "name",
          "text",
          error("name"),
          None,
        ),
        text_field(
          "email",
          "Email",
          form.email,
          "email",
          "email",
          error("email"),
          Some("We send a link to confirm it."),
        ),
        text_field(
          "password",
          "Password",
          "",
          "new-password",
          "password",
          error("password"),
          Some("At least 8 characters."),
        ),
        ui.field([], [
          ui.label([attribute.for("plan")], [text("Plan")]),
          ui.select(
            id: "plan",
            name: "plan",
            value: form.plan,
            placeholder: "Choose a plan",
            attributes: [],
            items: [
              ui.select_item("free", "Free"),
              ui.select_item("team", "Team"),
              ui.select_item("business", "Business"),
            ],
          ),
          case error("plan") {
            Some(message) -> ui.field_error([], [text(message)])
            None -> element.none()
          },
        ]),
        ui.field([], [
          ui.choice(
            ui.checkbox([
              attribute.name("terms"),
              attribute.checked(form.terms),
              ..invalid(error("terms"), "terms-error")
            ]),
            [text("I accept the terms")],
          ),
          case error("terms") {
            Some(message) ->
              ui.field_error([attribute.id("terms-error")], [text(message)])
            None -> element.none()
          },
        ]),
        ui.button(
          Primary,
          [attribute.type_("submit"), attribute.style("width", "100%")],
          [text("Create account")],
        ),
      ],
    ),
  ])
}

fn text_field(
  name: String,
  label: String,
  value: String,
  autocomplete: String,
  kind: String,
  error: Option(String),
  hint: Option(String),
) -> Element(msg) {
  let hint_id = name <> "-hint"
  let error_id = name <> "-error"
  let described =
    [
      option.map(hint, fn(_) { hint_id }),
      option.map(error, fn(_) { error_id }),
    ]
    |> option.values
  ui.field([], [
    ui.label([attribute.for(name)], [text(label)]),
    ui.input([
      attribute.id(name),
      attribute.name(name),
      attribute.type_(kind),
      attribute.value(value),
      attribute.autocomplete(autocomplete),
      ..list.append(
        case error {
          Some(_) -> [attribute.aria_invalid("true")]
          None -> []
        },
        case described {
          [] -> []
          ids -> [attribute.aria_describedby(string.join(ids, " "))]
        },
      )
    ]),
    case hint {
      Some(hint) -> ui.field_description([attribute.id(hint_id)], [text(hint)])
      None -> element.none()
    },
    case error {
      Some(message) -> ui.field_error([attribute.id(error_id)], [text(message)])
      None -> element.none()
    },
  ])
}

fn invalid(error: Option(String), id: String) -> List(Attribute(msg)) {
  case error {
    Some(_) -> [attribute.aria_invalid("true"), attribute.aria_describedby(id)]
    None -> []
  }
}
