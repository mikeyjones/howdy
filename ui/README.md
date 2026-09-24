# howdy_ui

Pages, themes and live server components for [howdy](../README.md), built
on [Lustre](https://hexdocs.pm/lustre) and [Sketch](https://hexdocs.pm/sketch).

```sh
gleam add howdy_ui
```

It is a separate package so that howdy itself stays free of Lustre and
Sketch. Apps that only serve JSON never pull them in.

## Pages

`howdy/ui/page` renders a Lustre element as a full HTML document. The head
carries the theme variables, base styles and the CSS for every component
in the body.

```gleam
import howdy/cookie
import howdy/ui
import howdy/ui/page
import lustre/element.{text}

controller.new("/")
|> controller.get("/", fn(ctx) {
  use theme <- cookie.string_or(ctx, "theme", default: "system")

  page.new("Orders")
  |> page.theme(theme)
  |> page.body([
    ui.container([], [
      ui.h1("Orders"),
      ui.p([text("Nothing yet.")]),
    ]),
  ])
  |> page.respond(ctx)
})
```

`page.theme` sets the `data-theme` attribute on the root element. A name
the page does not offer, such as the `"system"` default above, is ignored
and the browser's colour scheme preference decides. That means the first
paint is already in the right theme; no flash.

Use `page.render` or `page.to_string` to get the document without a
response, and `page.head` to add your own elements to the head.

### Serving the CSS as a file

Embedding needs no extra route and is fine for development. To serve the
CSS as one file instead, mount the development route and link it:

```gleam
howdy.new()
|> howdy.controller(pages())
|> howdy.controller(ui.stylesheet(at: "/assets/ui.css", themes: theme.default_themes()))
```

```gleam
page.new("Orders")
|> page.stylesheet(at: "/assets/ui.css")
```

The route serves every class registered so far with an ETag and
`cache-control: no-cache`, so browsers revalidate once per page load and
see new classes as soon as they exist. It is meant for development: it only
knows classes that have been rendered on that node.

To publish, write a static file from a known list of classes. See
[Publishing](#publishing).

## Themes

A theme is a record in `howdy/ui/theme`. Every component reads its colours,
fonts and radii through CSS variables defined by the theme, so changing a
theme changes every element.

```gleam
import howdy/ui/theme.{Colors}

pub fn brand() -> theme.Theme {
  theme.light()
  |> theme.named("brand")
  |> theme.colors(fn(c) { Colors(..c, primary: "#0f766e", on_primary: "#fff") })
}

page.new("Orders")
|> page.themes(theme.themes(default: brand(), alternatives: [theme.dark()]))
```

- The default theme goes on `:root`.
- Every theme is also written under `[data-theme="name"]`.
- With no attribute set, the first alternative whose scheme differs from the
  default is applied through `prefers-color-scheme`.
- Each theme sets `color-scheme`, so form controls and scrollbars follow.

Adding a field to `Colors`, `Font` or `Radius` is a compile error until every
theme supplies it. A test in this package checks every token in
`howdy/ui/theme/tokens` is defined by every built-in theme.

`ui.theme_toggle` renders a button that switches the document between two
named themes in place and stores the choice in a `theme` cookie:

```gleam
ui.theme_toggle([text("Toggle theme")], from: "light", to: "dark")
```

## Components

`howdy/ui` has a small set to start: `h1`, `h2`, `h3`, `p`, `muted`, `link`,
`button` with `Primary`, `Secondary` and `Danger` variants from
`howdy/ui/button`, `input`, `label`, `container`, `card`, `stack` and `row`.
Each component lives in its own module under `howdy/ui`, and `howdy/ui`
re-exports them. Every one is a Sketch class built from tokens.

### Making a component your own

Copy a component into your project and edit it, the way shadcn does:

```sh
gleam run -m howdy/ui list
gleam run -m howdy/ui add button layout
```

`add` writes `src/<app>/ui/button.gleam` and `layout.gleam`: the same
source the package ships, with a header noting the version it came from.
They depend only on the package's core modules, so you can change anything
in them. Use `--to=<dir>` to put them elsewhere and `--force` to overwrite a
copy you have edited.

Alongside them, `add` regenerates `all.gleam`, which lists the classes of
every module in that directory that has a `classes` function. Hand that
list to the export when publishing:

```gleam
export.new(theme.default_themes())
|> export.classes(my_app/ui/all.classes())
```

To see how a copy has drifted from the version the package ships, or what
a newer package version changed:

```sh
gleam run -m howdy/ui diff button
```

`add` also shows this diff instead of overwriting when a copy differs.

### Writing one from scratch

Keep the classes in a module with a `classes` function, build each from
`howdy/ui/theme/tokens`, and attach it with `ui.class`. Never name a colour
directly; use a token so the element follows the theme.

```gleam
// src/my_app/ui/badge.gleam
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}

pub fn badge(content: String) -> Element(msg) {
  html.span([class(badge_class())], [text(content)])
}

pub fn classes() -> List(Class) {
  [badge_class()]
}

pub fn badge_class() -> Class {
  css.class([
    css.background(tokens.primary),
    css.color(tokens.on_primary),
    css.property("border-radius", tokens.radius_small),
  ])
}
```

Put it in the same directory as your copied components and the next `add`
includes it in `all.gleam`.

Class names are content hashes, computed in the calling process. The CSS
for each distinct class is rendered once and kept in an ETS table owned by
a supervised process in the `howdy_ui` application. Gleam starts it before
running your entry point; direct Erlang callers also start it automatically
on first cache access. After startup, rendering reads and writes ETS directly
without waiting on the owner process. Pages and
live views include the CSS for you. Anywhere else, put `ui.styles()` in the
document after the elements it styles.

Stopping the application clears the cache. If the owner crashes, its supervisor
restarts it with an empty cache and subsequent renders register their classes
again. A render in progress during that crash can fail; recovery does not replay
it automatically. Startup failures are reported rather than leaving callers
waiting for an owner that never started.

## Live components

A Lustre server component keeps its `init`, `update` and `view` on the
server. The browser runs a thin client that sends events up a WebSocket and
applies DOM patches that come back. `howdy/ui/live` turns one into a howdy
route:

```gleam
import howdy/ui/live

controller.new("/counter")
|> controller.get("/", fn(ctx) { live.serve(ctx, counter.app(), with: 0) })
```

and mounts it in a page:

```gleam
page.new("Counter")
|> page.live
|> page.body([live.mount("/counter")])
|> page.respond(ctx)
```

`page.live` includes the Lustre client runtime. The socket route goes through
guards and middleware like any other, so authentication works the same as for
`howdy/websocket`: read a cookie or query parameter, since browsers cannot set
handshake headers.

- `live.serve` starts one runtime per connection and shuts it down when the
  socket closes.
- `live.start` at boot returns a runtime that outlives connections, and
  `live.serve_shared` attaches sockets to it. Every client sees the same
  model. `live.dispatch` sends it a message from anywhere.
- `live.socket` and `live.socket_shared` return the plain `howdy/websocket`
  builder so you can add an `on_close` of your own before upgrading.

The component renders into a shadow root, so its view is wrapped to carry
a `<style>` node with the CSS for exactly the classes it used. It is styled
whether the page embeds, links the development route, or links a published
file, and it needs no setup. Theme variables are inherited from the page,
so a live view switches theme with the rest of the document.

### Live links

A live link moves between live pages without reloading. Mount one
`live.outlet` in place of a `live.mount`, and link with `live.link`:

```gleam
fn layout(ctx, mount mount: String) {
  page.new("Shop")
  |> page.live
  |> page.body([
    live.link(to: "/", mount: "/live/home", children: [text("Home")]),
    live.link(to: "/orders", mount: "/live/orders", children: [text("Orders")]),
    live.outlet(mount),
  ])
  |> page.respond(ctx)
}

controller.new("/")
|> controller.get("/", fn(ctx) { layout(ctx, mount: "/live/home") })
|> controller.get("/orders", fn(ctx) { layout(ctx, mount: "/live/orders") })
```

A click connects the outlet to the link's socket route and puts `href` in
the address bar. The old view stays on screen until the new one arrives, and
everything outside the outlet, including other live components, is left
alone. Back and forward swap the outlet too.

- `href` is what a reload, a bookmark, a new tab or a browser without
  JavaScript loads, so it must serve the page with that view in the outlet.
- Modified clicks, middle clicks, `target` links and links to other origins
  behave as plain links, as does every live link on a page with no outlet.
- Links work inside live views as well as in the page. `live.navigate`
  returns the attributes for an `<a>` you style yourself.
- Put `live.title("Orders")` in a view to rename the document when the view
  mounts.
- After a click the page scrolls to the top and focus moves to the outlet.
- Each swap starts a fresh runtime, so view state does not carry across.

`page.live` includes the script. If you render the document yourself, add
`live.script()` after `server_component.script()`.

In `howdy/testing` there is no socket to upgrade, so a live route answers
`426`. Test the app's `init`, `update` and `view` directly, or start a
runtime with `live.start` and register your own subject as the client, as
`test/live_test.gleam` does.

See `examples/live` for a page with a private and a shared counter, and
live links between two views.

## Publishing

For a published site, write the CSS once as a static file, minified, from
the built-in components and the classes in your own `all.gleam`. Add a script module and
run it whenever the styles change:

```gleam
// src/tasks/css.gleam
import howdy/ui/export
import howdy/ui/theme
import my_app/ui/all

pub fn main() {
  let assert Ok(Nil) =
    export.new(theme.default_themes())
    |> export.classes(all.classes())
    |> export.write(to: "priv/static/ui.css")
}
```

```sh
gleam run -m tasks/css
```

The output is deterministic for the same ordered class list, independent of
which pages were rendered beforehand. Built-in classes come first, followed by
classes in the order passed to `export.classes`; duplicate classes keep their
first position. Choose this order deliberately because equally specific rules
later in the stylesheet win. Export uses an isolated stylesheet and does not
populate the runtime registry.

Minification preserves descendant selectors such as `div :hover`. CSS containing
escapes, comments or URLs is left unchanged rather than risking a tokenization
change; such exports may retain whitespace.

Serve the file with `howdy/static` and a long cache lifetime, and link it with whatever
cache-busting you use for other assets:

```gleam
howdy.controller(
  static.new(from: "priv/static")
  |> static.at("/assets")
  |> static.max_age(seconds: 31_536_000)
  |> static.build,
)
```

```gleam
page.stylesheet(page, at: "/assets/ui.css?v=" <> my_app.version)
```

Live components carry their own CSS, so they are unaffected by what the
file contains.

## Developing

This package lives in the howdy repository and depends on howdy by path, so
a change to both lands in one commit. Before publishing, replace the path
dependency in `gleam.toml` with a version range, since `gleam publish`
rejects path dependencies.

```sh
cd ui
gleam test
```
