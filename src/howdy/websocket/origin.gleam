//// Internal browser-origin validation shared by every socket upgrade.

import gleam/http
import gleam/http/request.{type Request}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri

pub opaque type Origin {
  Origin(scheme: String, host: String, port: Int)
}

pub type Policy {
  SameOrigin
  Allowlist(List(Origin))
}

pub fn allowlist(values: List(String)) -> Policy {
  Allowlist(
    list.map(values, fn(value) {
      let assert Ok(origin) = parse(value)
        as "howdy/websocket: expected an HTTP(S) origin without path, credentials or wildcard"
      origin
    }),
  )
}

pub fn allowed(req: Request(body), policy: Policy, required: Bool) -> Bool {
  let origins = list.filter(req.headers, fn(header) { header.0 == "origin" })
  case origins {
    [] -> !required
    [#(_, value)] ->
      case parse(value) {
        Error(Nil) -> False
        Ok(origin) ->
          case policy {
            Allowlist(origins) -> list.contains(origins, origin)
            SameOrigin ->
              origin
              == Origin(
                http.scheme_to_string(req.scheme),
                normalize_host(req.host),
                effective_port(http.scheme_to_string(req.scheme), req.port),
              )
          }
      }
    _ -> False
  }
}

fn parse(value: String) -> Result(Origin, Nil) {
  case uri.parse(value) {
    Ok(uri.Uri(
      scheme: Some(scheme),
      host: Some(host),
      userinfo: None,
      path: "",
      query: None,
      fragment: None,
      port:,
    )) -> {
      let scheme = string.lowercase(scheme)
      let port = effective_port(scheme, port)
      case
        { scheme == "http" || scheme == "https" }
        && host != ""
        && port >= 1
        && port <= 65_535
        && list.all(string.to_graphemes(host), fn(char) {
          string.contains(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:[]",
            char,
          )
        })
      {
        True -> Ok(Origin(scheme, normalize_host(host), port))
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn effective_port(scheme: String, port: option.Option(Int)) -> Int {
  case port, scheme {
    Some(port), _ -> port
    None, "https" -> 443
    None, _ -> 80
  }
}

// uri.parse removes IPv6 brackets; HTTP request authorities retain them.
fn normalize_host(host: String) -> String {
  let host = string.lowercase(host)
  case host {
    "[" <> rest ->
      case string.ends_with(rest, "]") {
        True -> string.drop_end(rest, 1)
        False -> host
      }
    _ -> host
  }
}
