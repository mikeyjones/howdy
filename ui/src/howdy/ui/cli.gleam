//// The `gleam run -m howdy/ui` command line.
////
//// - `list` shows the components that can be copied.
//// - `add <name>...` copies components into the project, by default under
////   `src/<app>/ui/`, and regenerates `all.gleam` there so the export
////   picks them up.
//// - `diff <name>...` compares a copy with the version this package ships.
////
//// Options: `--to=<dir>` chooses the directory, `--force` overwrites.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// This package's version, written into every generated file.
pub const version = "0.1.0"

/// The components that can be copied, in the order `list` shows them.
pub const components = [
  "button", "heading", "typography", "input", "field", "checkbox", "layout",
  "card", "badge", "alert", "table", "loading", "dialog", "popover", "tooltip",
  "menu", "tabs", "accordion", "select", "toast", "sidebar", "pagination",
  "calendar", "command", "data_table", "chart",
]

/// Run a command and print what happened.
pub fn run(args: List(String)) -> Nil {
  case execute(args) {
    Ok(output) -> io.println(output)
    Error(message) -> {
      io.println_error(message)
      halt(1)
    }
  }
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

/// What a command wants done, before any file is touched.
pub type Options {
  Options(names: List(String), to: Option(String), force: Bool)
}

/// Run a command and return its output, or the reason it could not.
pub fn execute(args: List(String)) -> Result(String, String) {
  case args {
    ["list", ..] -> Ok(list_components())
    ["add", ..rest] -> {
      use options <- result.try(parse(rest))
      add(options)
    }
    ["diff", ..rest] -> {
      use options <- result.try(parse(rest))
      diff(options)
    }
    _ -> Error(usage)
  }
}

const usage = "usage: gleam run -m howdy/ui <command>

  list                      show the components you can copy
  add <name>... [options]   copy components into your project
  diff <name>... [options]  compare your copies with this version

options:
  --to=<dir>   where the copies live (default: src/<app>/ui)
  --force      overwrite copies that differ"

fn parse(args: List(String)) -> Result(Options, String) {
  let options = Options(names: [], to: None, force: False)
  use options <- result.try(
    list.try_fold(args, options, fn(options, arg) {
      case arg {
        "--force" -> Ok(Options(..options, force: True))
        "--to=" <> dir -> Ok(Options(..options, to: Some(dir)))
        "--" <> _ -> Error("unknown option " <> arg <> "\n\n" <> usage)
        name ->
          Ok(Options(..options, names: list.append(options.names, [name])))
      }
    }),
  )
  case options.names {
    [] -> Error("give at least one component name\n\n" <> usage)
    names ->
      case list.filter(names, fn(name) { !list.contains(components, name) }) {
        [] -> Ok(options)
        unknown ->
          Error(
            "unknown component "
            <> string.join(unknown, ", ")
            <> ". Run `gleam run -m howdy/ui list` to see what is available.",
          )
      }
  }
}

// -- list --------------------------------------------------------------------

fn list_components() -> String {
  components
  |> list.map(fn(name) {
    let summary = case template(name) {
      Ok(source) -> "  " <> first_doc_line(source)
      Error(_) -> ""
    }
    string.pad_end(name, 12, " ") <> summary
  })
  |> string.join("\n")
}

fn first_doc_line(source: String) -> String {
  source
  |> string.split("\n")
  |> list.find_map(fn(line) {
    case line {
      "//// " <> text -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> result.unwrap("")
}

// -- add ---------------------------------------------------------------------

fn add(options: Options) -> Result(String, String) {
  use dir <- result.try(target_dir(options))
  let _ = simplifile.create_directory_all(dir)
  use lines <- result.try(
    list.try_map(options.names, fn(name) { add_one(name, dir, options.force) }),
  )
  use index <- result.try(write_index(dir))
  Ok(string.join(list.flatten([lines, [index], dependency_hint()]), "\n"))
}

/// Copies import `lustre` and `sketch` directly, so they must be direct
/// dependencies of the project rather than only of howdy_ui.
fn dependency_hint() -> List(String) {
  case simplifile.read("gleam.toml") {
    Error(_) -> []
    Ok(toml) -> {
      let missing =
        ["lustre", "sketch"]
        |> list.filter(fn(package) {
          !list.any(string.split(toml, "\n"), fn(line) {
            string.starts_with(string.trim(line), package <> " ")
            || string.starts_with(string.trim(line), package <> "=")
          })
        })
      case missing {
        [] -> []
        _ -> [
          "The copies import "
          <> string.join(missing, " and ")
          <> " directly. Add them as dependencies: gleam add "
          <> string.join(missing, " "),
        ]
      }
    }
  }
}

fn add_one(name: String, dir: String, force: Bool) -> Result(String, String) {
  let path = dir <> "/" <> name <> ".gleam"
  use fresh <- result.try(generated(name))
  case simplifile.read(path), force {
    Ok(existing), False ->
      case existing == fresh {
        True -> Ok(path <> " is up to date")
        False ->
          Ok(
            path
            <> " exists and differs from howdy_ui "
            <> version
            <> "; left as is. Use --force to overwrite.\n"
            <> render_diff(path, existing, fresh),
          )
      }
    _, _ ->
      case simplifile.write(path, fresh) {
        Ok(Nil) -> Ok("wrote " <> path)
        Error(error) ->
          Error("could not write " <> path <> ": " <> string.inspect(error))
      }
  }
}

/// The `all.gleam` module: the classes of every component module in the
/// directory, for `howdy/ui/export`.
fn write_index(dir: String) -> Result(String, String) {
  use files <- result.try(
    simplifile.read_directory(dir)
    |> result.map_error(fn(error) {
      "could not read " <> dir <> ": " <> string.inspect(error)
    }),
  )
  let modules =
    files
    |> list.filter(fn(file) {
      string.ends_with(file, ".gleam") && file != "all.gleam"
    })
    |> list.filter(fn(file) {
      case simplifile.read(dir <> "/" <> file) {
        Ok(source) -> string.contains(source, "pub fn classes()")
        Error(_) -> False
      }
    })
    |> list.map(string.drop_end(_, string.length(".gleam")))
    |> list.sort(string.compare)
  let module_path = module_path(dir)
  let imports =
    modules
    |> list.map(fn(name) { "import " <> module_path <> "/" <> name })
  let calls =
    modules
    |> list.map(fn(name) { "    " <> name <> ".classes()," })
  let source =
    string.join(
      list.flatten([
        [
          "//// Generated by howdy_ui " <> version <> ". The classes of every",
          "//// component in this directory, for `howdy/ui/export`. Regenerated",
          "//// by `gleam run -m howdy/ui add`; do not edit.",
          "",
          "import gleam/list",
        ],
        imports,
        [
          "import sketch/css.{type Class}",
          "",
          "pub fn classes() -> List(Class) {",
          "  list.flatten([",
        ],
        calls,
        ["  ])", "}", ""],
      ]),
      "\n",
    )
  let path = dir <> "/all.gleam"
  case simplifile.write(path, source) {
    Ok(Nil) -> Ok("wrote " <> path)
    Error(error) ->
      Error("could not write " <> path <> ": " <> string.inspect(error))
  }
}

/// `src/my_app/ui` is the module path `my_app/ui`: everything after the
/// last `src/`.
fn module_path(dir: String) -> String {
  case string.split(strip_slash(dir), "src/") |> list.last {
    Ok(rest) -> rest
    Error(Nil) -> dir
  }
}

// -- diff --------------------------------------------------------------------

fn diff(options: Options) -> Result(String, String) {
  use dir <- result.try(target_dir(options))
  use lines <- result.try(
    list.try_map(options.names, fn(name) {
      let path = dir <> "/" <> name <> ".gleam"
      use fresh <- result.try(generated(name))
      case simplifile.read(path) {
        Error(_) ->
          Ok(path <> " does not exist; `add " <> name <> "` would create it")
        Ok(existing) ->
          case existing == fresh {
            True -> Ok(path <> " matches howdy_ui " <> version)
            False -> Ok(render_diff(path, existing, fresh))
          }
      }
    }),
  )
  Ok(string.join(lines, "\n"))
}

fn render_diff(path: String, existing: String, fresh: String) -> String {
  let from = case generated_version(existing) {
    Some(v) -> " (generated by howdy_ui " <> v <> ")"
    None -> ""
  }
  [
    "--- " <> path <> from,
    "+++ howdy_ui " <> version,
    ..hunks(string.split(existing, "\n"), string.split(fresh, "\n"))
  ]
  |> string.join("\n")
}

fn generated_version(source: String) -> Option(String) {
  case source {
    "//// Generated by howdy_ui " <> rest ->
      rest
      |> string.split_once(" ")
      |> result.map(fn(pair) { Some(pair.0) })
      |> result.unwrap(None)
    _ -> None
  }
}

// -- Templates ---------------------------------------------------------------

/// The file `add` writes: the shipped module with a header.
pub fn generated(name: String) -> Result(String, String) {
  use source <- result.try(template(name))
  Ok(
    "//// Generated by howdy_ui "
    <> version
    <> " from `howdy/ui/"
    <> name
    <> "`. This file is yours: edit it\n"
    <> "//// freely. `gleam run -m howdy/ui diff "
    <> name
    <> "` compares it with the version\n"
    <> "//// howdy_ui ships.\n"
    <> "////\n"
    <> source,
  )
}

/// The shipped source of a component: from the project's build directory
/// for a hex dependency, from the path in `manifest.toml` for a path
/// dependency, or from `src` when developing howdy_ui itself.
fn template(name: String) -> Result(String, String) {
  let file = "howdy/ui/" <> name <> ".gleam"
  [
    Some("build/packages/howdy_ui/src/" <> file),
    option.map(local_package_path(), fn(root) { root <> "/src/" <> file }),
    Some("src/" <> file),
  ]
  |> option.values
  |> list.find_map(simplifile.read)
  |> result.map_error(fn(_) {
    "could not find " <> file <> ". Is howdy_ui a dependency and built?"
  })
}

/// The `path` of howdy_ui in `manifest.toml`, when it is a path dependency.
fn local_package_path() -> Option(String) {
  use manifest <- option.then(
    option.from_result(simplifile.read("manifest.toml")),
  )
  manifest
  |> string.split("\n")
  |> list.find(fn(line) { string.contains(line, "name = \"howdy_ui\"") })
  |> option.from_result
  |> option.then(fn(line) {
    case string.split_once(line, "path = \"") {
      Ok(#(_, rest)) ->
        string.split_once(rest, "\"")
        |> option.from_result
        |> option.map(fn(pair) { pair.0 })
      Error(Nil) -> None
    }
  })
}

fn target_dir(options: Options) -> Result(String, String) {
  case options.to {
    Some(dir) -> Ok(strip_slash(dir))
    None -> {
      use name <- result.try(app_name())
      Ok("src/" <> name <> "/ui")
    }
  }
}

fn strip_slash(dir: String) -> String {
  case string.ends_with(dir, "/") {
    True -> strip_slash(string.drop_end(dir, 1))
    False -> dir
  }
}

/// `0, 1, ..., n - 1` counting down, for filling the table from the end.
fn descending(n: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, n), fn(_, i) { n - 1 - i })
}

fn app_name() -> Result(String, String) {
  use toml <- result.try(
    simplifile.read("gleam.toml")
    |> result.map_error(fn(_) {
      "could not read gleam.toml; run this from the project root or pass --to=<dir>"
    }),
  )
  toml
  |> string.split("\n")
  |> list.find_map(fn(line) {
    case string.split_once(line, "=") {
      Ok(#(key, value)) if key == "name " || key == "name" ->
        Ok(string.trim(value) |> string.replace("\"", ""))
      _ -> Error(Nil)
    }
  })
  |> result.map_error(fn(_) { "gleam.toml has no name; pass --to=<dir>" })
}

// -- Line diff ---------------------------------------------------------------

/// Changed regions with two lines of context, in unified style.
fn hunks(old: List(String), new: List(String)) -> List(String) {
  let edits = edits(old, new)
  let context = 2
  // Which edit indices are within `context` of a change.
  let changed =
    list.index_map(edits, fn(edit, i) {
      case edit {
        Keep(_) -> None
        _ -> Some(i)
      }
    })
    |> option.values
  use <- bool.guard(when: changed == [], return: ["(no differences)"])
  let near = fn(i) {
    list.any(changed, fn(c) { int.absolute_value(c - i) <= context })
  }
  edits
  |> list.index_map(fn(edit, i) { #(edit, near(i)) })
  |> list.fold(#([], False), fn(acc, pair) {
    let #(lines, was_near) = acc
    let #(edit, is_near) = pair
    case is_near, was_near {
      False, True -> #(["...", ..lines], False)
      False, False -> #(lines, False)
      True, _ -> #([render_edit(edit), ..lines], True)
    }
  })
  |> fn(acc) { acc.0 }
  |> list.reverse
}

type Edit {
  Keep(String)
  Remove(String)
  Insert(String)
}

fn render_edit(edit: Edit) -> String {
  case edit {
    Keep(line) -> " " <> line
    Remove(line) -> "-" <> line
    Insert(line) -> "+" <> line
  }
}

/// A shortest edit script by longest common subsequence. Files are small,
/// so the full table is fine.
fn edits(old: List(String), new: List(String)) -> List(Edit) {
  let n = list.length(old)
  let m = list.length(new)
  let old_at = index(old)
  let new_at = index(new)
  // lengths[#(i, j)] is the LCS length of old[i..] and new[j..].
  let lengths =
    list.fold(descending(n), dict.new(), fn(table, i) {
      list.fold(descending(m), table, fn(table, j) {
        let value = case at(old_at, i) == at(new_at, j) {
          True -> 1 + get(table, i + 1, j + 1)
          False -> int.max(get(table, i + 1, j), get(table, i, j + 1))
        }
        dict.insert(table, #(i, j), value)
      })
    })
  backtrack(lengths, old_at, new_at, n, m, 0, 0, [])
}

fn backtrack(
  lengths: Dict(#(Int, Int), Int),
  old_at: Dict(Int, String),
  new_at: Dict(Int, String),
  n: Int,
  m: Int,
  i: Int,
  j: Int,
  acc: List(Edit),
) -> List(Edit) {
  case i < n, j < m {
    False, False -> list.reverse(acc)
    True, False ->
      backtrack(lengths, old_at, new_at, n, m, i + 1, j, [
        Remove(at(old_at, i)),
        ..acc
      ])
    False, True ->
      backtrack(lengths, old_at, new_at, n, m, i, j + 1, [
        Insert(at(new_at, j)),
        ..acc
      ])
    True, True ->
      case at(old_at, i) == at(new_at, j) {
        True ->
          backtrack(lengths, old_at, new_at, n, m, i + 1, j + 1, [
            Keep(at(old_at, i)),
            ..acc
          ])
        False ->
          case get(lengths, i + 1, j) >= get(lengths, i, j + 1) {
            True ->
              backtrack(lengths, old_at, new_at, n, m, i + 1, j, [
                Remove(at(old_at, i)),
                ..acc
              ])
            False ->
              backtrack(lengths, old_at, new_at, n, m, i, j + 1, [
                Insert(at(new_at, j)),
                ..acc
              ])
          }
      }
  }
}

fn index(lines: List(String)) -> Dict(Int, String) {
  lines
  |> list.index_map(fn(line, i) { #(i, line) })
  |> dict.from_list
}

fn at(lines: Dict(Int, String), i: Int) -> String {
  dict.get(lines, i) |> result.unwrap("")
}

fn get(table: Dict(#(Int, Int), Int), i: Int, j: Int) -> Int {
  dict.get(table, #(i, j)) |> result.unwrap(0)
}
