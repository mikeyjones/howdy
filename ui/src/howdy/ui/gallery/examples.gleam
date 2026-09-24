//// The examples `howdy/ui/gallery` shows for each entry. The gallery
//// renders each one and shows its source from this file, so the code on
//// the page is the code that drew it.

import gleam/int
import gleam/option.{None, Some}
import howdy/ui
import howdy/ui/alert
import howdy/ui/badge
import howdy/ui/blocks/app_shell
import howdy/ui/blocks/sign_in
import howdy/ui/blocks/sign_up
import howdy/ui/blocks/stat_card
import howdy/ui/button.{
  Danger, Ghost, Icon, Large, Link, Outline, Primary, Secondary, Small,
}
import howdy/ui/button_group
import howdy/ui/calendar.{Date}
import howdy/ui/chart
import howdy/ui/chat.{Incoming, Outgoing}
import howdy/ui/command
import howdy/ui/data_table.{Ascending, Links, Sort}
import howdy/ui/dialog
import howdy/ui/layout
import howdy/ui/resizable
import howdy/ui/select
import howdy/ui/toast
import howdy/ui/toggle
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

/// An example: its title, the function in this module that draws it, and
/// the function itself.
pub type Example(msg) {
  Example(title: String, function: String, view: fn() -> Element(msg))
}

/// The examples for an entry, by its registry name.
pub fn for(name: String) -> List(Example(msg)) {
  case name {
    "heading" -> [Example("Headings", "headings", headings)]
    "typography" -> [Example("Text", "text_styles", text_styles)]
    "button" -> [
      Example("Variants", "button_variants", button_variants),
      Example("Sizes", "button_sizes", button_sizes),
    ]
    "input" -> [Example("Text inputs", "text_inputs", text_inputs)]
    "field" -> [
      Example("A field with a hint and an error", "field_states", field_states),
      Example("A fieldset", "fieldset", fieldset),
    ]
    "checkbox" -> [Example("Checkboxes and radios", "choices", choices)]
    "select" -> [Example("Select", "select_menu", select_menu)]
    "command" -> [
      Example("Command menu", "command_menu", command_menu),
      Example("Combobox", "combobox", combobox),
    ]
    "calendar" -> [
      Example("Calendar", "calendar_month", calendar_month),
      Example("Date picker", "date_picker", date_picker),
    ]
    "layout" -> [Example("Stacks, rows and separators", "layouts", layouts)]
    "card" -> [Example("Card", "card_parts", card_parts)]
    "sidebar" -> [Example("Sidebar", "sidebar_layout", sidebar_layout)]
    "effects" -> [
      Example("Scroll fade", "scroll_fade", scroll_fade),
      Example("Shimmer", "shimmer", shimmer),
    ]
    "dialog" -> [
      Example("Dialog", "dialog_form", dialog_form),
      Example("Alert dialog", "alert_dialog", alert_dialog),
      Example("Sheet", "sheet", sheet),
    ]
    "popover" -> [Example("Popover", "popover", popover)]
    "tooltip" -> [Example("Tooltip", "tooltip", tooltip)]
    "menu" -> [Example("Dropdown menu", "dropdown_menu", dropdown_menu)]
    "tabs" -> [Example("Tabs", "tabs", tabs)]
    "accordion" -> [
      Example("Accordion", "accordion", accordion),
      Example("Collapsible", "collapsible", collapsible),
    ]
    "pagination" -> [Example("Pagination", "pagination", pagination)]
    "table" -> [Example("Table", "table", table)]
    "data_table" -> [
      Example("Sortable data table", "data_table_example", data_table_example),
    ]
    "chart" -> [
      Example("Bar chart", "bar_chart", bar_chart),
      Example("Line chart", "line_chart", line_chart),
      Example("Area chart", "area_chart", area_chart),
    ]
    "badge" -> [Example("Badges", "badges", badges)]
    "avatar" -> [Example("Avatars", "avatars", avatars)]
    "progress" -> [Example("Progress", "progress", progress)]
    "alert" -> [Example("Alerts", "alerts", alerts)]
    "toast" -> [Example("Toasts", "toasts", toasts)]
    "loading" -> [Example("Skeletons and spinners", "loading", loading)]
    "chat" -> [Example("Conversation", "conversation", conversation)]
    "attachment" -> [Example("Attachments", "attachments", attachments)]
    "app_shell" -> [Example("Application shell", "shell", shell)]
    "stat_card" -> [Example("Stat cards", "stat_cards", stat_cards)]
    "sign_in" -> [Example("Sign in", "signing_in", signing_in)]
    "sign_up" -> [
      Example("Sign up, with errors", "signing_up", signing_up),
    ]
    "kbd" -> [Example("Keys and shortcuts", "keys", keys)]
    "button_group" -> [Example("Button group", "button_group", button_group)]
    "toggle" -> [
      Example("Toggle", "toggle", toggle),
      Example("Toggle group", "toggle_group", toggle_group),
    ]
    "switch" -> [Example("Switch", "switches", switches)]
    "slider" -> [Example("Slider", "slider", slider)]
    "input_group" -> [Example("Input group", "input_group", input_group)]
    "input_otp" -> [Example("One-time code", "one_time_code", one_time_code)]
    "aspect_ratio" -> [Example("16:9", "aspect_ratio", aspect_ratio)]
    "scroll_area" -> [Example("Scroll area", "scroll_area", scroll_area)]
    "resizable" -> [Example("Resizable panels", "resizable", resizable)]
    "context_menu" -> [Example("Context menu", "context_menu", context_menu)]
    "menubar" -> [Example("Menubar", "menubar", menubar)]
    "hover_card" -> [Example("Hover card", "hover_card", hover_card)]
    "breadcrumb" -> [Example("Breadcrumb", "breadcrumb", breadcrumb)]
    "navigation_menu" -> [
      Example("Navigation menu", "navigation_menu", navigation_menu),
    ]
    "carousel" -> [Example("Carousel", "carousel", carousel)]
    "item" -> [Example("Items", "items", items)]
    "empty" -> [Example("Empty state", "empty_state", empty_state)]
    _ -> [Example("A sample of components", "theme_sample", theme_sample)]
  }
}

pub fn headings() -> Element(msg) {
  ui.stack([], [
    ui.h1("Heading one"),
    ui.h2("Heading two"),
    ui.h3("Heading three"),
  ])
}

pub fn text_styles() -> Element(msg) {
  ui.stack([], [
    ui.p([
      text("A paragraph of body text, with "),
      ui.link("#", [text("a link")]),
      text("."),
    ]),
    ui.muted("Muted text, for captions and hints."),
  ])
}

pub fn button_variants() -> Element(msg) {
  ui.row([], [
    ui.button(Primary, [], [text("Primary")]),
    ui.button(Secondary, [], [text("Secondary")]),
    ui.button(Outline, [], [text("Outline")]),
    ui.button(Ghost, [], [text("Ghost")]),
    ui.button(Link, [], [text("Link")]),
    ui.button(Danger, [], [text("Danger")]),
    ui.button(Primary, [attribute.disabled(True)], [text("Disabled")]),
  ])
}

pub fn button_sizes() -> Element(msg) {
  ui.row([], [
    ui.sized_button(Primary, Small, [], [text("Small")]),
    ui.button(Primary, [], [text("Medium")]),
    ui.sized_button(Primary, Large, [], [text("Large")]),
    ui.sized_button(Outline, Icon, [attribute.aria_label("Add")], [text("+")]),
  ])
}

pub fn text_inputs() -> Element(msg) {
  ui.stack([], [
    ui.input([attribute.placeholder("Your name")]),
    ui.textarea([attribute.placeholder("Tell us more")], ""),
    ui.native_select([], [html.option([], "Free"), html.option([], "Pro")]),
    ui.input([attribute.value("Can't edit this"), attribute.disabled(True)]),
  ])
}

pub fn field_states() -> Element(msg) {
  ui.field([], [
    ui.label([attribute.for("example-email")], [text("Email")]),
    ui.input([
      attribute.id("example-email"),
      attribute.value("ada@"),
      attribute.aria_invalid("true"),
      attribute.aria_describedby("example-email-hint example-email-error"),
    ]),
    ui.field_description([attribute.id("example-email-hint")], [
      text("We never share it."),
    ]),
    ui.field_error([attribute.id("example-email-error")], [
      text("Enter a whole email address."),
    ]),
  ])
}

pub fn fieldset() -> Element(msg) {
  ui.fieldset([], legend: [text("Delivery address")], children: [
    ui.input([attribute.aria_label("Street"), attribute.placeholder("Street")]),
    ui.input([attribute.aria_label("Town"), attribute.placeholder("Town")]),
  ])
}

pub fn choices() -> Element(msg) {
  ui.stack([], [
    ui.choice(ui.checkbox([attribute.checked(True)]), [text("Email me updates")]),
    ui.radio_group([attribute.aria_label("Plan")], [
      ui.choice(ui.radio([attribute.name("plan"), attribute.checked(True)]), [
        text("Monthly"),
      ]),
      ui.choice(ui.radio([attribute.name("plan")]), [text("Yearly")]),
    ]),
  ])
}

pub fn select_menu() -> Element(msg) {
  ui.select(
    id: "example-plan",
    name: "plan",
    value: "",
    placeholder: "Choose a plan",
    attributes: [],
    items: [
      ui.select_item("free", "Free"),
      ui.select_item("team", "Team"),
      select.disabled_item("enterprise", "Enterprise"),
    ],
  )
}

pub fn command_menu() -> Element(msg) {
  ui.command(
    "example-command",
    placeholder: "Search…",
    attributes: [],
    children: [
      ui.command_group("Suggestions", [
        ui.command_item([], [text("New invoice")]),
        ui.command_item([command.keywords("customer client")], [
          text("Add contact"),
        ]),
      ]),
      ui.command_group("Settings", [ui.command_item([], [text("Billing")])]),
      ui.command_empty([text("No results.")]),
    ],
  )
}

pub fn combobox() -> Element(msg) {
  ui.combobox(
    id: "example-country",
    name: "country",
    value: "",
    label: "",
    placeholder: "Choose a country",
    search: "Search countries…",
    options: [
      ui.combobox_option("fr", selected: False, children: [text("France")]),
      ui.combobox_option("de", selected: False, children: [text("Germany")]),
      ui.combobox_option("gb", selected: False, children: [
        text("United Kingdom"),
      ]),
    ],
  )
}

pub fn calendar_month() -> Element(msg) {
  calendar.new("example-calendar", year: 2026, month: 9)
  |> calendar.selected(Some(Date(2026, 9, 18)))
  |> calendar.today(Date(2026, 9, 24))
  |> calendar.name("day")
  |> calendar.view
}

pub fn date_picker() -> Element(msg) {
  calendar.new("example-picker", year: 2026, month: 9)
  |> calendar.name("due")
  |> calendar.picker(placeholder: "Pick a date")
}

pub fn layouts() -> Element(msg) {
  ui.stack([], [
    ui.row([], [
      ui.badge(badge.Secondary, [], [text("One")]),
      ui.separator(layout.Vertical, []),
      ui.badge(badge.Secondary, [], [text("Two")]),
    ]),
    ui.separator(layout.Horizontal, []),
    ui.muted("A stack puts children in a column; a row lines them up."),
  ])
}

pub fn card_parts() -> Element(msg) {
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("Invoices")]),
      ui.card_description([text("Paid in the last 30 days.")]),
      ui.card_action([], [ui.button(Ghost, [], [text("Export")])]),
    ]),
    ui.card_content([], [ui.p([text("12 invoices, $4,210 in total.")])]),
    ui.card_footer([], [ui.button(Primary, [], [text("New invoice")])]),
  ])
}

pub fn sidebar_layout() -> Element(msg) {
  ui.sidebar_layout(
    collapsed: False,
    attributes: [attribute.style("min-height", "16rem")],
    sidebar: ui.sidebar("example-sidebar", [], [
      ui.sidebar_header([text("Acme")]),
      ui.sidebar_content([
        ui.sidebar_group("Workspace", [
          ui.sidebar_link("#", active: True, attributes: [], children: [
            text("Home"),
          ]),
          ui.sidebar_link("#", active: False, attributes: [], children: [
            text("Orders"),
          ]),
        ]),
      ]),
    ]),
    main: [
      ui.sized_button(
        Ghost,
        Icon,
        [
          attribute.aria_label("Toggle sidebar"),
          ..ui.sidebar_trigger("example-sidebar")
        ],
        [text("☰")],
      ),
    ],
  )
}

pub fn scroll_fade() -> Element(msg) {
  html.div([ui.scroll_fade(), attribute.style("max-height", "10rem")], [
    ui.stack([], [
      ui.p([text("Scroll this area.")]),
      ui.p([text("Content fades as it nears the edges,")]),
      ui.p([text("but not while it rests at the top")]),
      ui.p([text("or the bottom.")]),
      ui.p([text("That is the whole effect.")]),
    ]),
  ])
}

pub fn shimmer() -> Element(msg) {
  ui.shimmer([text("Writing a reply…")])
}

pub fn dialog_form() -> Element(msg) {
  html.div([], [
    ui.button(Outline, ui.dialog_trigger("example-dialog"), [text("Rename")]),
    ui.dialog("example-dialog", [], [
      ui.dialog_header([
        ui.dialog_title("example-dialog", [text("Rename project")]),
        ui.dialog_description("example-dialog", [
          text("Pick a name your team will recognise."),
        ]),
      ]),
      ui.input([attribute.aria_label("Name"), attribute.value("Apollo")]),
      ui.dialog_footer([
        ui.button(Outline, ui.dialog_close("example-dialog"), [text("Cancel")]),
        ui.button(Primary, ui.dialog_close("example-dialog"), [text("Save")]),
      ]),
    ]),
  ])
}

pub fn alert_dialog() -> Element(msg) {
  html.div([], [
    ui.button(Danger, ui.dialog_trigger("example-alert"), [text("Delete")]),
    ui.alert_dialog("example-alert", [], [
      ui.dialog_header([
        ui.dialog_title("example-alert", [text("Delete this project?")]),
        ui.dialog_description("example-alert", [text("This cannot be undone.")]),
      ]),
      ui.dialog_footer([
        ui.button(Outline, ui.dialog_close("example-alert"), [text("Keep it")]),
        ui.button(Danger, ui.dialog_close("example-alert"), [text("Delete")]),
      ]),
    ]),
  ])
}

pub fn sheet() -> Element(msg) {
  html.div([], [
    ui.button(Outline, ui.dialog_trigger("example-sheet"), [
      text("Open settings"),
    ]),
    ui.sheet("example-sheet", dialog.Right, [], [
      ui.dialog_header([ui.dialog_title("example-sheet", [text("Settings")])]),
      ui.choice(ui.checkbox([]), [text("Compact view")]),
    ]),
  ])
}

pub fn popover() -> Element(msg) {
  html.div([], [
    ui.button(Outline, ui.popover_trigger("example-popover"), [text("Filters")]),
    ui.popover("example-popover", [], [
      ui.stack([], [
        ui.label([attribute.for("example-min")], [text("Minimum amount")]),
        ui.input([attribute.id("example-min"), attribute.type_("number")]),
      ]),
    ]),
  ])
}

pub fn tooltip() -> Element(msg) {
  html.div([], [
    ui.sized_button(
      Outline,
      Icon,
      [attribute.aria_label("Archive"), ..ui.tooltip_trigger("example-tip")],
      [text("⌂")],
    ),
    ui.tooltip("example-tip", [text("Archive this thread")]),
  ])
}

pub fn dropdown_menu() -> Element(msg) {
  html.div([], [
    ui.button(Outline, ui.menu_trigger("example-menu"), [text("Account")]),
    ui.menu("example-menu", [], [
      ui.menu_label([text("Signed in as ada")]),
      ui.menu_item([], [text("Profile")]),
      ui.menu_checkbox_item(True, [], [text("Compact view")]),
      ui.menu_separator(),
      ui.menu_link("#", [], [text("Sign out")]),
    ]),
  ])
}

pub fn tabs() -> Element(msg) {
  ui.tabs("example-tabs", selected: "account", attributes: [], tabs: [
    ui.tab("account", [], label: [text("Account")], panel: [
      ui.p([text("Change your name and email.")]),
    ]),
    ui.tab("password", [], label: [text("Password")], panel: [
      ui.p([text("Change your password.")]),
    ]),
  ])
}

pub fn accordion() -> Element(msg) {
  ui.accordion([], [
    ui.accordion_item(
      "example-faq",
      open: True,
      summary: [text("Is it accessible?")],
      content: [
        text("Yes. Each section is a native details element."),
      ],
    ),
    ui.accordion_item(
      "example-faq",
      open: False,
      summary: [text("Is it styled?")],
      content: [
        text("Yes, from the theme."),
      ],
    ),
  ])
}

pub fn collapsible() -> Element(msg) {
  ui.collapsible([], open: False, summary: [text("Show two more")], content: [
    ui.p([text("Hidden until opened.")]),
  ])
}

pub fn pagination() -> Element(msg) {
  ui.pagination(current: 6, total: 12, href: fn(_) { "#" })
}

pub fn table() -> Element(msg) {
  ui.table([], [
    ui.table_header([], [
      ui.table_row([], [
        ui.table_head([], [text("Invoice")]),
        ui.table_head([], [text("Amount")]),
      ]),
    ]),
    ui.table_body([], [
      ui.table_row([], [
        ui.table_cell([], [text("INV001")]),
        ui.table_cell([], [text("$250.00")]),
      ]),
      ui.table_row([], [
        ui.table_cell([], [text("INV002")]),
        ui.table_cell([], [text("$150.00")]),
      ]),
    ]),
  ])
}

pub fn data_table_example() -> Element(msg) {
  data_table.new(
    [
      data_table.column("name", "Customer", fn(row: #(String, Int)) {
        text(row.0)
      }),
      data_table.column("seats", "Seats", fn(row: #(String, Int)) {
        text(int.to_string(row.1))
      })
        |> data_table.numeric,
    ],
    [#("Acme", 12), #("Globex", 48), #("Initech", 7)],
  )
  |> data_table.sort(Some(Sort("name", Ascending)), by: Links(fn(_) { "#" }))
  |> data_table.view
}

pub fn bar_chart() -> Element(msg) {
  chart.bar(
    title: "Orders by day",
    labels: ["Mon", "Tue", "Wed", "Thu", "Fri"],
    series: [
      chart.Series("Online", [42.0, 51.0, 47.0, 60.0, 72.0]),
      chart.Series("In store", [31.0, 29.0, 35.0, 33.0, 40.0]),
    ],
  )
  |> chart.view
}

pub fn line_chart() -> Element(msg) {
  chart.line(
    title: "Response time, ms",
    labels: ["Mon", "Tue", "Wed", "Thu", "Fri"],
    series: [
      chart.Series("Europe", [120.0, 132.0, 101.0, 134.0, 90.0]),
      chart.Series("Americas", [220.0, 182.0, 191.0, 234.0, 290.0]),
    ],
  )
  |> chart.view
}

pub fn area_chart() -> Element(msg) {
  chart.area(
    title: "Visitors, thousands",
    labels: ["Apr", "May", "Jun", "Jul"],
    series: [
      chart.Series("Visitors", [18.2, 21.5, 19.8, 24.1]),
    ],
  )
  |> chart.view
}

pub fn badges() -> Element(msg) {
  ui.row([], [
    ui.badge(badge.Primary, [], [text("New")]),
    ui.badge(badge.Secondary, [], [text("Paid")]),
    ui.badge(badge.Outline, [], [text("Pending")]),
    ui.badge(badge.Danger, [], [text("Refunded")]),
  ])
}

pub fn avatars() -> Element(msg) {
  ui.row([], [
    ui.avatar(src: "/missing.png", alt: "Ada Lovelace", initials: "AL"),
    ui.avatar_initials("GH"),
  ])
}

pub fn progress() -> Element(msg) {
  ui.progress(label: "Uploading report.pdf", value: 64, max: 100)
}

pub fn alerts() -> Element(msg) {
  ui.stack([], [
    ui.alert(alert.Info, [], [
      ui.alert_title([text("Heads up")]),
      ui.alert_description([text("Copy components with the command line.")]),
    ]),
    ui.alert(alert.Danger, [], [
      ui.alert_title([text("Payment failed")]),
      ui.alert_description([text("Your card was declined.")]),
    ]),
  ])
}

pub fn toasts() -> Element(msg) {
  ui.toast_region([attribute.style("position", "static")], [
    ui.toast(toast.Info, [toast.persistent()], [
      ui.toast_title([text("Saved")]),
      ui.toast_description([text("Your changes are live.")]),
      ui.toast_close([attribute.aria_label("Dismiss")]),
    ]),
    ui.toast(toast.Danger, [toast.persistent()], [
      ui.toast_title([text("Could not send")]),
      ui.toast_close([attribute.aria_label("Dismiss")]),
    ]),
  ])
}

pub fn loading() -> Element(msg) {
  ui.row([], [
    ui.spinner("Loading", []),
    ui.stack([attribute.style("flex", "1")], [
      ui.skeleton([attribute.style("width", "60%")]),
      ui.skeleton([attribute.style("width", "40%")]),
    ]),
  ])
}

pub fn conversation() -> Element(msg) {
  ui.chat_conversation(
    [attribute.aria_label("Messages"), attribute.style("height", "18rem")],
    [
      ui.chat_note([text("Today")]),
      ui.chat_message(
        Incoming,
        avatar: ui.avatar_initials("GH"),
        header: [text("Grace · 09:41")],
        content: [
          ui.chat_bubble(Incoming, [text("Did the deploy go out?")]),
        ],
      ),
      ui.chat_message(Outgoing, avatar: element.none(), header: [], content: [
        ui.chat_bubble(Outgoing, [text("Ten minutes ago. All green.")]),
        chat.reactions([chat.reaction("🎉", 2, [attribute.aria_pressed("true")])]),
      ]),
      ui.chat_message(
        Incoming,
        avatar: ui.avatar_initials("GH"),
        header: [],
        content: [
          ui.chat_bubble(Incoming, [ui.shimmer([text("Grace is typing…")])]),
        ],
      ),
    ],
  )
}

pub fn attachments() -> Element(msg) {
  ui.stack([], [
    ui.attachment(
      name: "report.pdf",
      detail: "PDF · 2.4 MB",
      uploaded: Some(64),
      actions: [],
    ),
    ui.attachment(
      name: "photo.jpeg",
      detail: "JPEG · 820 KB",
      uploaded: None,
      actions: [
        ui.sized_button(
          Ghost,
          Icon,
          [attribute.aria_label("Remove photo.jpeg")],
          [text("×")],
        ),
      ],
    ),
  ])
}

pub fn shell() -> Element(msg) {
  app_shell.app_shell(
    app: "Acme",
    collapsed: False,
    current: "/",
    navigation: [
      app_shell.Group("Workspace", [
        app_shell.Link("/", "Dashboard"),
        app_shell.Link("/orders", "Orders"),
      ]),
    ],
    footer: [ui.muted("ada@example.com")],
    heading: "Dashboard",
    actions: [ui.button(Outline, [], [text("Share")])],
    content: [stat_cards()],
  )
}

pub fn stat_cards() -> Element(msg) {
  ui.row([], [
    stat_card.stat_card(
      label: "Revenue",
      value: "$48,210",
      change: "+12% on last month",
    ),
    stat_card.stat_card(
      label: "Orders",
      value: "1,284",
      change: "+4% on last month",
    ),
  ])
}

pub fn signing_in() -> Element(msg) {
  sign_in.screen(sign_in.sign_in(
    action: "#",
    email: "",
    error: None,
    sign_up: "#",
    forgot: "#",
  ))
}

pub fn signing_up() -> Element(msg) {
  sign_up.screen(sign_up.sign_up(
    action: "#",
    form: sign_up.Form(..sign_up.empty(), name: "Ada", email: "ada@"),
    errors: [#("email", "Enter a whole email address.")],
    sign_in: "#",
  ))
}

pub fn theme_sample() -> Element(msg) {
  ui.card([], [
    ui.stack([], [
      ui.h3("Invoices"),
      ui.row([], [
        ui.button(Primary, [], [text("Primary")]),
        ui.button(Secondary, [], [text("Secondary")]),
        ui.button(Outline, [], [text("Outline")]),
        ui.badge(badge.Secondary, [], [text("Paid")]),
      ]),
      ui.input([
        attribute.aria_label("Search"),
        attribute.placeholder("Search…"),
      ]),
      ui.alert(alert.Danger, [], [ui.alert_title([text("Payment failed")])]),
      ui.progress(label: "Progress", value: 60, max: 100),
    ]),
  ])
}

pub fn keys() -> Element(msg) {
  ui.row([], [
    ui.p([text("Search with "), ui.shortcut(["⌘", "K"])]),
    ui.p([text("Close with "), ui.kbd("Esc")]),
  ])
}

pub fn button_group() -> Element(msg) {
  ui.button_group(button_group.Horizontal, [attribute.aria_label("Pages")], [
    ui.button(Outline, [], [text("Previous")]),
    ui.button(Outline, [], [text("Today")]),
    ui.button(Outline, [], [text("Next")]),
  ])
}

pub fn toggle() -> Element(msg) {
  ui.toggle(False, [attribute.aria_label("Bold")], [
    html.strong([], [text("B")]),
  ])
}

pub fn toggle_group() -> Element(msg) {
  ui.toggle_group(toggle.Single, [attribute.aria_label("Alignment")], [
    ui.toggle(True, [], [text("Left")]),
    ui.toggle(False, [], [text("Centre")]),
    ui.toggle(False, [], [text("Right")]),
  ])
}

pub fn switches() -> Element(msg) {
  ui.stack([], [
    ui.choice(ui.switch([attribute.checked(True)]), [text("Email alerts")]),
    ui.choice(ui.switch([]), [text("Weekly summary")]),
  ])
}

pub fn slider() -> Element(msg) {
  ui.stack([], [
    ui.label([attribute.for("example-volume")], [text("Volume")]),
    ui.slider([
      attribute.id("example-volume"),
      attribute.min("0"),
      attribute.max("100"),
      attribute.value("40"),
    ]),
  ])
}

pub fn input_group() -> Element(msg) {
  ui.input_group([], [
    ui.input_group_addon([text("https://")]),
    ui.input_group_input([
      attribute.aria_label("Website"),
      attribute.placeholder("example.com"),
    ]),
    ui.input_group_addon([ui.sized_button(Ghost, Small, [], [text("Check")])]),
  ])
}

pub fn one_time_code() -> Element(msg) {
  ui.stack([], [
    ui.label([attribute.for("example-code")], [text("Verification code")]),
    ui.input_otp(6, [attribute.id("example-code"), attribute.name("code")]),
  ])
}

pub fn aspect_ratio() -> Element(msg) {
  ui.aspect_ratio(16, 9, [], [
    html.div([attribute.style("padding", "1rem")], [ui.muted("16 : 9")]),
  ])
}

pub fn scroll_area() -> Element(msg) {
  ui.scroll_area("Release notes", [attribute.style("height", "9rem")], [
    ui.stack([attribute.style("padding", "0.75rem")], [
      ui.p([text("2.0: live links between pages.")]),
      ui.p([text("1.9: shared live runtimes.")]),
      ui.p([text("1.8: themes as records.")]),
      ui.p([text("1.7: static CSS export.")]),
      ui.p([text("1.6: the first components.")]),
    ]),
  ])
}

pub fn resizable() -> Element(msg) {
  ui.resizable_group(
    resizable.Horizontal,
    [attribute.style("height", "10rem")],
    [
      ui.resizable_panel(30, [attribute.style("padding", "1rem")], [
        text("Folders"),
      ]),
      ui.resizable_handle("Resize folders"),
      ui.resizable_panel(70, [attribute.style("padding", "1rem")], [
        text("Messages"),
      ]),
    ],
  )
}

pub fn context_menu() -> Element(msg) {
  html.div([], [
    ui.context_menu_area(
      "example-context",
      [
        attribute.tabindex(0),
        attribute.style("padding", "2rem"),
        attribute.style("border", "1px dashed var(--howdy-border)"),
        attribute.style("border-radius", "var(--howdy-radius-medium)"),
      ],
      [ui.muted("Right-click here, or focus it and press the menu key.")],
    ),
    ui.context_menu("example-context", [], [
      ui.menu_item([], [text("Rename")]),
      ui.menu_item([], [text("Duplicate")]),
      ui.menu_separator(),
      ui.menu_item([], [text("Delete")]),
    ]),
  ])
}

pub fn menubar() -> Element(msg) {
  html.div([], [
    ui.menubar([attribute.aria_label("Editor")], [
      ui.menubar_button("example-file", [text("File")]),
      ui.menubar_button("example-edit", [text("Edit")]),
      ui.menubar_button("example-view", [text("View")]),
    ]),
    ui.menu("example-file", [], [
      ui.menu_item([], [text("New")]),
      ui.menu_item([], [text("Open…")]),
      ui.menu_separator(),
      ui.menu_item([], [text("Print")]),
    ]),
    ui.menu("example-edit", [], [
      ui.menu_item([], [text("Undo")]),
      ui.menu_item([], [text("Redo")]),
    ]),
    ui.menu("example-view", [], [
      ui.menu_checkbox_item(True, [], [text("Show ruler")]),
    ]),
  ])
}

pub fn hover_card() -> Element(msg) {
  html.p([], [
    text("Written by "),
    html.a([attribute.href("#"), ..ui.hover_card_trigger("example-card")], [
      text("@ada"),
    ]),
    text("."),
    ui.hover_card("example-card", [], [
      ui.row([], [
        ui.avatar_initials("AL"),
        ui.stack([attribute.style("gap", "0.125rem")], [
          html.strong([], [text("Ada Lovelace")]),
          ui.muted("Writes the notes on the engine."),
        ]),
      ]),
    ]),
  ])
}

pub fn breadcrumb() -> Element(msg) {
  ui.breadcrumb([], [
    ui.breadcrumb_link("#", [text("Home")]),
    ui.breadcrumb_ellipsis(),
    ui.breadcrumb_link("#", [text("Orders")]),
    ui.breadcrumb_page([text("#1042")]),
  ])
}

pub fn navigation_menu() -> Element(msg) {
  ui.navigation_menu([attribute.aria_label("Example")], [
    ui.navigation_link("#", active: True, children: [text("Home")]),
    ui.navigation_panel("example-products", label: [text("Products")], links: [
      ui.navigation_panel_link(
        "#",
        title: "Analytics",
        description: "See what your customers do.",
      ),
      ui.navigation_panel_link(
        "#",
        title: "Billing",
        description: "Invoices and payments.",
      ),
    ]),
    ui.navigation_link("#", active: False, children: [text("Pricing")]),
  ])
}

pub fn carousel() -> Element(msg) {
  ui.carousel("example-carousel", label: "Highlights", attributes: [], slides: [
    ui.carousel_slide([
      ui.card([], [ui.h3("Live views"), ui.muted("State on the server.")]),
    ]),
    ui.carousel_slide([
      ui.card([], [ui.h3("Themes"), ui.muted("Records, not class names.")]),
    ]),
    ui.carousel_slide([
      ui.card([], [ui.h3("Copies"), ui.muted("Components you own.")]),
    ]),
  ])
}

pub fn items() -> Element(msg) {
  ui.item_group([
    ui.item(
      media: ui.avatar_initials("AL"),
      title: [text("Ada Lovelace")],
      description: [text("ada@example.com")],
      actions: [ui.button(Outline, [], [text("Invite")])],
    ),
    ui.item_link(
      "#",
      media: ui.avatar_initials("GH"),
      title: [text("Grace Hopper")],
      description: [text("Joined last week")],
    ),
  ])
}

pub fn empty_state() -> Element(msg) {
  ui.empty(
    icon: text("📭"),
    title: "No invoices yet",
    description: "Invoices you send appear here, with who has paid.",
    actions: [ui.button(Primary, [], [text("New invoice")])],
  )
}
