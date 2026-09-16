//// Where classes are registered and their CSS collected.
////
//// Sketch class names are content hashes, so a name can be computed in the
//// calling process with a throwaway stylesheet. The CSS for each distinct
//// class is rendered once and kept in an ETS table owned by a supervised
//// process in the howdy_ui application. After startup, cache access is
//// direct, so rendering does not queue on the owner process.

import gleam/int
import gleam/list
import gleam/set
import gleam/string
import howdy/ui/theme.{type Themes}
import howdy/ui/theme/tokens
import sketch
import sketch/css.{type Class}

@external(erlang, "howdy_ui_ffi", "known")
fn known(name: String) -> Bool

@external(erlang, "howdy_ui_ffi", "register")
fn register(name: String, css: String) -> Nil

@external(erlang, "howdy_ui_ffi", "all_css")
fn all_css() -> String

@external(erlang, "howdy_ui_ffi", "css_for")
fn css_for(names: List(String)) -> String

@external(erlang, "howdy_ui_ffi", "scope_begin")
fn scope_begin() -> Nil

@external(erlang, "howdy_ui_ffi", "scope_end")
fn scope_end() -> List(String)

@external(erlang, "howdy_ui_ffi", "note")
fn note(name: String) -> Nil

@external(erlang, "erlang", "phash2")
fn phash2(term: String, range: Int) -> Int

/// Register a class and return its generated name. If a render scope is
/// open in this process, the name is recorded in it.
pub fn class_name(class: Class) -> String {
  let assert Ok(sheet) = sketch.stylesheet(strategy: sketch.Ephemeral)
  let #(sheet, name) = sketch.class_name(class, sheet)
  case name == "" || known(name) {
    True -> Nil
    False -> register(name, sketch.render(sheet))
  }
  note(name)
  name
}

/// Run `render` and return its result with the CSS for exactly the classes
/// it used.
pub fn scoped(render: fn() -> a) -> #(a, String) {
  scope_begin()
  let result = render()
  let names = scope_end()
  #(result, css_for(names))
}

/// The CSS for every class registered so far, in the order first seen.
pub fn css() -> String {
  all_css()
}

/// Render an explicit class list independently of the runtime registry.
/// First occurrence wins, preserving the caller's deliberate cascade order.
pub fn css_of(classes: List(Class)) -> String {
  let #(_, parts) =
    list.fold(classes, #(set.new(), []), fn(acc, class) {
      let #(seen, parts) = acc
      let assert Ok(sheet) = sketch.stylesheet(strategy: sketch.Ephemeral)
      let #(sheet, name) = sketch.class_name(class, sheet)
      case name == "" || set.contains(seen, name) {
        True -> acc
        False -> #(set.insert(seen, name), [sketch.render(sheet), ..parts])
      }
    })
  parts |> list.reverse |> string.join("\n\n")
}

/// Everything a document needs: theme variables, base styles and the
/// component CSS registered so far.
pub fn document_css(themes: Themes) -> String {
  theme.to_css(themes) <> "\n" <> base <> "\n" <> css()
}

/// A short hash of some CSS, used as an ETag.
pub fn etag(css: String) -> String {
  "\"" <> int.to_base16(phash2(css, 4_294_967_296)) <> "\""
}

/// Styles for the elements a page does not create through `howdy/ui`,
/// such as `<body>` and raw text.
pub const base = "*, *::before, *::after { box-sizing: border-box; }
body { margin: 0; background: "
  <> tokens.background
  <> "; color: "
  <> tokens.text
  <> "; font-family: "
  <> tokens.font_body
  <> "; line-height: 1.5; -webkit-font-smoothing: antialiased; }
h1, h2, h3, h4, h5, h6 { font-family: "
  <> tokens.font_heading
  <> "; line-height: 1.2; }
code, pre, kbd { font-family: "
  <> tokens.font_mono
  <> "; }
a { color: "
  <> tokens.primary
  <> "; }"
