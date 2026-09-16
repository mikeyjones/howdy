//// Matches an incoming method and path against a set of controllers.

import gleam/dict.{type Dict}
import gleam/http.{type Method}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import howdy/controller.{
  type Controller, type Handler, type Middleware, type Route,
}

pub type Match {
  /// A route matched. Params are the values captured by `:name` segments
  /// and by a trailing `*name` segment, which holds the rest of the path.
  Found(handler: Handler, params: Dict(String, String))
  /// The path matched at least one route but none with this method. An
  /// `OPTIONS` request never produces this: it is answered by
  /// `controller.options_handler` instead.
  MethodNotAllowed(allowed: List(Method))
  /// Nothing matched the path.
  NotFound
}

/// A routing snapshot with middleware composed once, at handler construction.
///
/// Exact routes are indexed by segment count and first literal segment, so a
/// request only scans routes that could match it. Declaration order is kept
/// by numbering entries and merging the literal and parameter-first buckets
/// by that number, so which overlapping route wins is unchanged.
@internal
pub opaque type Table {
  Table(
    exact: Dict(Int, Bucket),
    wildcards: Bucket,
    middleware: List(Middleware),
  )
}

type Entry {
  Entry(index: Int, controller: Controller, route: Route)
}

/// Routes that share a shape, split by how their first segment matches.
/// `open` holds patterns whose first segment is a parameter or a wildcard,
/// or that have no segments at all; they can match any first segment.
type Bucket {
  Bucket(literal: Dict(String, List(Entry)), open: List(Entry))
}

@internal
pub fn compile(
  controllers: List(Controller),
  middleware: List(Middleware),
) -> Table {
  let entries =
    list.flat_map(controllers, fn(ctrl) {
      list.map(controller.routes(ctrl), fn(route) {
        Entry(
          0,
          ctrl,
          controller.Route(
            ..route,
            handler: controller.wrap_all(route.handler, middleware),
          ),
        )
      })
    })
    |> list.index_map(fn(entry, index) { Entry(..entry, index:) })
  let #(exact, wildcards) =
    list.partition(entries, fn(entry) { !is_wildcard(entry.route) })
  let exact =
    list.group(exact, fn(entry) { list.length(entry.route.segments) })
    |> dict.map_values(fn(_, entries) { bucket(list.reverse(entries)) })
  Table(exact:, wildcards: bucket(wildcards), middleware:)
}

/// Entries must be in declaration order; the bucket's lists keep it.
fn bucket(entries: List(Entry)) -> Bucket {
  let #(open, literal) =
    list.partition(entries, fn(entry) {
      case entry.route.segments {
        [":" <> _, ..] | ["*" <> _, ..] | [] -> True
        _ -> False
      }
    })
  let literal =
    list.group(literal, fn(entry) {
      let assert [first, ..] = entry.route.segments
      first
    })
    |> dict.map_values(fn(_, entries) { list.reverse(entries) })
  Bucket(literal:, open:)
}

/// The routes in a bucket that could match a path starting with `first`,
/// in declaration order.
fn candidates(bucket: Bucket, first: Option(String)) -> List(Entry) {
  let literal = case first {
    Some(first) -> dict.get(bucket.literal, first) |> result.unwrap([])
    None -> []
  }
  case literal, bucket.open {
    [], open -> open
    literal, [] -> literal
    literal, open -> merge(literal, open)
  }
}

fn merge(a: List(Entry), b: List(Entry)) -> List(Entry) {
  case a, b {
    [], rest | rest, [] -> rest
    [x, ..xs], [y, ..ys] ->
      case x.index < y.index {
        True -> [x, ..merge(xs, b)]
        False -> [y, ..merge(a, ys)]
      }
  }
}

/// Find the first route, in declaration order, matching `method` and `path`.
/// For repeated dispatch, `howdy.handler` compiles the table once.
pub fn match(
  controllers: List(Controller),
  method: Method,
  path: String,
) -> Match {
  match_table(compile(controllers, []), method, path)
}

@internal
pub fn match_table(table: Table, method: Method, path: String) -> Match {
  let segments = controller.segments(path)
  let first = option.from_result(list.first(segments))
  let exact =
    dict.get(table.exact, list.length(segments))
    |> result.map(candidates(_, first))
    |> result.unwrap([])
  case scan(exact, segments, method, [], None, table.middleware) {
    NotFound ->
      scan(
        candidates(table.wildcards, first),
        segments,
        method,
        [],
        None,
        table.middleware,
      )
    found -> found
  }
}

// Exact patterns always take precedence over wildcards, even if their methods
// do not match. Stop as soon as the first handler for the requested method wins.
// Only 405/implicit OPTIONS need the full list of matching methods.
fn scan(
  entries: List(Entry),
  path: List(String),
  method: Method,
  allowed: List(Method),
  first: Option(Candidate),
  middleware: List(Middleware),
) -> Match {
  case entries {
    [] ->
      case first {
        None -> NotFound
        Some(Candidate(controller: ctrl, params:, ..)) -> {
          let allowed = allowed |> list.reverse |> list.unique
          case method {
            http.Options ->
              Found(
                handler: controller.options_handler(ctrl, allowed)
                  |> controller.wrap_all(middleware),
                params:,
              )
            _ -> MethodNotAllowed(allowed:)
          }
        }
      }
    [Entry(controller: ctrl, route:, ..), ..rest] ->
      case match_segments(route.segments, path, dict.new()) {
        Error(Nil) -> scan(rest, path, method, allowed, first, middleware)
        Ok(params) ->
          case route.method == method {
            True -> Found(handler: route.handler, params:)
            False -> {
              let first = case first {
                None -> Some(Candidate(ctrl, route, params))
                Some(_) -> first
              }
              scan(
                rest,
                path,
                method,
                [route.method, ..allowed],
                first,
                middleware,
              )
            }
          }
      }
  }
}

fn is_wildcard(route: Route) -> Bool {
  case list.last(route.segments) {
    Ok("*" <> _) -> True
    _ -> False
  }
}

type Candidate {
  Candidate(controller: Controller, route: Route, params: Dict(String, String))
}

fn match_segments(
  pattern: List(String),
  path: List(String),
  params: Dict(String, String),
) -> Result(Dict(String, String), Nil) {
  case pattern, path {
    [], [] -> Ok(params)
    ["*" <> name], rest -> Ok(dict.insert(params, name, string.join(rest, "/")))
    [":" <> name, ..pattern], [value, ..path] ->
      match_segments(pattern, path, dict.insert(params, name, value))
    [expected, ..pattern], [actual, ..path] if expected == actual ->
      match_segments(pattern, path, params)
    _, _ -> Error(Nil)
  }
}
