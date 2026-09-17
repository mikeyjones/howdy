//// Serve files from a directory.
////
//// ```gleam
//// import howdy/static
////
//// howdy.new()
//// |> howdy.controller(static.serve("/", from: "priv/public"))
//// ```
////
//// Every file under `priv/public` is now answered at the site root, with
//// `index.html` standing in for directories. For more control build the
//// controller step by step:
////
//// ```gleam
//// static.new(from: "priv/public")
//// |> static.at("/assets")
//// |> static.max_age(seconds: 86_400)
//// |> static.build
//// ```
////
//// The result is an ordinary controller, so middleware, guards, logging
//// and CORS apply to it like any other. Only `GET` and `HEAD` are answered.
//// Requests that would escape the root directory get a `404`, and
//// directories are never listed.
////
//// A controller mounted at `"/"` matches every path, so mount it last.
//// It also stops `howdy.versions` from ever seeing a request, since the
//// group only answers paths no controller matched. Mount under a prefix
//// such as `"/assets"` when the app has a version group.

import ewe
import filepath
import gleam/bytes_tree
import gleam/http
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri
import howdy/context
import howdy/controller.{type Controller, type GuardedContext}
import howdy/service
import marceau
import simplifile

/// A directory of files under construction. Build with `new`, adjust, then
/// turn into a controller with `build`.
pub opaque type Files {
  Files(
    root: String,
    prefix: String,
    index: String,
    max_age: Option(Int),
    fallback: Option(String),
  )
}

/// Serve the files in `root` under `prefix` with the default options. The
/// same as `new(from: root) |> at(prefix) |> build`.
pub fn serve(at prefix: String, from root: String) -> Controller {
  new(from: root) |> at(prefix) |> build
}

/// Start describing a directory to serve. `root` is relative to the
/// working directory unless absolute. The files are mounted at `"/"` with
/// `index.html` as the directory index, no caching header and no fallback.
pub fn new(from root: String) -> Files {
  Files(root:, prefix: "/", index: "index.html", max_age: None, fallback: None)
}

/// Mount the files under `prefix` instead of `"/"`.
pub fn at(files: Files, prefix: String) -> Files {
  Files(..files, prefix:)
}

/// The file served for a request naming a directory. Defaults to
/// `"index.html"`. A directory without one answers `404`.
pub fn index(files: Files, name: String) -> Files {
  Files(..files, index: name)
}

/// Send `cache-control: public, max-age=N` with every file.
pub fn max_age(files: Files, seconds seconds: Int) -> Files {
  Files(..files, max_age: Some(seconds))
}

/// Serve this file, relative to the root, with a `200` for any path that
/// does not name a file. Single-page apps use this so a deep link such as
/// `/users/42` loads the app and lets its router take over.
pub fn fallback(files: Files, name: String) -> Files {
  Files(..files, fallback: Some(name))
}

/// Turn the description into a controller answering `GET` and `HEAD`.
pub fn build(files: Files) -> Controller {
  let assert Ok(root) = simplifile.resolve(files.root)
    as "howdy/static: invalid root"
  let assert True = valid_relative_name(files.index)
    as "howdy/static: index must be a relative path inside the root"
  let assert True = case files.fallback {
    None -> True
    Some(name) -> valid_relative_name(name)
  }
    as "howdy/static: fallback must be a relative path inside the root"
  let files = Files(..files, root:)
  let handler = fn(ctx: controller.Context) {
    case controller.param(ctx, "path") {
      Ok(path) -> respond(ctx, files, path)
      Error(Nil) -> not_found(ctx)
    }
  }
  controller.new(files.prefix)
  |> controller.get("/*path", handler)
  |> controller.route(http.Head, "/*path", handler)
}

/// A `200` response with the contents of the file at `path` and a content
/// type from its extension, or a `404` if there is no such file. The path
/// is used as given, so build it from trusted values only; the controller
/// from `build` is the safe way to serve user-chosen paths.
pub fn file(ctx: GuardedContext(guarded), path: String) -> Response(ewe.Body) {
  case simplifile.is_file(path) {
    Ok(True) -> send(ctx, path)
    _ -> not_found(ctx)
  }
}

fn respond(
  ctx: controller.Context,
  files: Files,
  path: String,
) -> Response(ewe.Body) {
  let response = case safe_segments(path) {
    Ok(segments) -> {
      case resolve(files.root, segments, files.index) {
        Found(path) -> send(ctx, path)
        Rejected -> not_found(ctx)
        Missing | Directory ->
          case files.fallback {
            Some(name) ->
              case walk(files.root, string.split(name, "/")) {
                Found(path) -> send(ctx, path)
                _ -> not_found(ctx)
              }
            None -> not_found(ctx)
          }
      }
    }
    Error(Nil) -> not_found(ctx)
  }
  case files.max_age, response.status {
    Some(seconds), 200 ->
      response.set_header(
        response,
        "cache-control",
        "public, max-age=" <> int.to_string(seconds),
      )
    _, _ -> response
  }
}

/// The decoded segments of a request path, or `Error` if any of them could
/// move outside the root directory or fail to decode.
fn safe_segments(path: String) -> Result(List(String), Nil) {
  path
  |> string.split("/")
  |> list.filter(fn(segment) { segment != "" && segment != "." })
  |> list.try_map(fn(segment) {
    case uri.percent_decode(segment) {
      Ok(decoded) ->
        case
          decoded == ".."
          || decoded == ""
          || string.contains(decoded, "/")
          || string.contains(decoded, "\\")
          || string.contains(decoded, "\u{0}")
          || string.contains(decoded, ":")
        {
          True -> Error(Nil)
          False -> Ok(decoded)
        }
      Error(Nil) -> Error(Nil)
    }
  })
}

// The root and its contents are trusted deployment assets: callers must not
// allow untrusted processes to mutate the tree while requests are served.
// lstat each component so file links, directory links and linked indexes all
// fail closed. ewe retains its normal streaming path on both HTTP versions.
type Resolution {
  Found(String)
  Directory
  Missing
  Rejected
}

fn walk(path: String, segments: List(String)) -> Resolution {
  case simplifile.link_info(path) {
    Error(_) -> Missing
    Ok(info) ->
      case simplifile.file_info_type(info), segments {
        simplifile.Directory, [] -> Directory
        simplifile.Directory, [segment, ..rest] ->
          walk(filepath.join(path, segment), rest)
        simplifile.File, [] -> Found(path)
        simplifile.Symlink, _ | simplifile.Other, _ -> Rejected
        _, _ -> Missing
      }
  }
}

fn resolve(root: String, segments: List(String), index: String) -> Resolution {
  case walk(root, segments) {
    Directory -> walk(root, list.append(segments, string.split(index, "/")))
    other -> other
  }
}

fn valid_relative_name(name: String) -> Bool {
  name != ""
  && !string.contains(name, "\\")
  && !string.contains(name, ":")
  && !string.contains(name, "\u{0}")
  && list.all(string.split(name, "/"), fn(part) {
    part != "" && part != "." && part != ".."
  })
}

fn send(ctx: GuardedContext(guarded), path: String) -> Response(ewe.Body) {
  let body = case context.connection(ctx.request.body) {
    Some(connection) -> ewe.file(connection, path, offset: None, limit: None)
    None ->
      case simplifile.read_bits(path) {
        Ok(bits) -> Ok(ewe.Bytes(bytes_tree.from_bit_array(bits)))
        Error(_) -> Error(ewe.UnknownError)
      }
  }
  case body {
    Ok(body) ->
      response.new(200)
      |> response.set_header("content-type", content_type(path))
      |> response.set_body(body)
    Error(ewe.NotFound) | Error(ewe.IsDirectory) -> not_found(ctx)
    Error(_) ->
      service.error_response(
        ctx,
        service.Internal("howdy/static: could not read " <> path),
      )
  }
}

fn not_found(ctx: GuardedContext(guarded)) -> Response(ewe.Body) {
  service.error_response(ctx, service.NotFound("file not found"))
}

/// The content type for a file, from its extension. Text types carry a
/// UTF-8 charset. Unknown extensions are `application/octet-stream`.
pub fn content_type(path: String) -> String {
  let mime = case filepath.extension(path) {
    Ok(extension) -> marceau.extension_to_mime_type(extension)
    Error(Nil) -> "application/octet-stream"
  }
  case string.starts_with(mime, "text/") || mime == "application/json" {
    True -> mime <> "; charset=utf-8"
    False -> mime
  }
}
