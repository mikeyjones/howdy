//// A single JWKS response per provider runtime, never a cache of identities.

import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import howdy/auth/internal/token
import howdy/service

pub type Cache

@external(erlang, "howdy_auth_oidc_ffi", "keys_new")
pub fn new() -> Cache

@external(erlang, "howdy_auth_oidc_ffi", "keys_read")
fn read(cache: Cache) -> Option(#(String, Int))

@external(erlang, "howdy_auth_oidc_ffi", "keys_write")
fn write(cache: Cache, body: String, until: Int) -> Nil

@external(erlang, "howdy_auth_ffi", "with_repo_lock")
fn locked(
  cache: Cache,
  run: fn() -> service.Result(String),
) -> service.Result(String)

pub fn get(
  cache: Cache,
  refresh: Bool,
  fetch: fn() -> service.Result(Response(String)),
) -> service.Result(String) {
  use <- locked(cache)
  let now = token.now()
  case read(cache), refresh {
    Some(#(body, until)), False if until > now -> Ok(body)
    _, _ -> {
      use res <- result.try(fetch())
      case res.status == 200 && string.byte_size(res.body) <= 1_048_576 {
        True -> {
          write(cache, res.body, now + lifetime(res))
          Ok(res.body)
        }
        False -> Error(service.Internal("Google signing keys unavailable"))
      }
    }
  }
}

fn lifetime(res: Response(String)) -> Int {
  let directives =
    response.get_header(res, "cache-control")
    |> result.unwrap("")
    |> string.lowercase
    |> string.split(",")
    |> list.map(string.trim)
  case
    list.contains(directives, "no-store")
    || list.contains(directives, "no-cache")
  {
    True -> 0
    False -> {
      let seconds =
        list.find_map(directives, fn(value) {
          case value {
            "max-age=" <> n -> int.parse(n)
            _ -> Error(Nil)
          }
        })
        |> result.unwrap(0)
      let age =
        response.get_header(res, "age")
        |> result.try(int.parse)
        |> result.unwrap(0)
      int.max(0, int.min(seconds - int.max(age, 0), 3600))
    }
  }
}
