//// Request context shared by handlers and guards.

import ewe
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/http/request.{type Request}
import gleam/option.{type Option, None, Some}

/// The body of an incoming request. Under ewe it wraps the live connection
/// and is read from the socket on demand. In tests it holds the bytes
/// directly, so handlers that read bodies run unchanged. Build test bodies
/// with `howdy/testing`.
pub opaque type Body {
  Live(connection: ewe.Connection)
  Fake(bits: BitArray, ip: Option(String))
}

/// `guard` holds the successful controller guard value, or `Nil` for an
/// ordinary controller. `version` is the API version resolved by
/// `howdy/version`, or `None` for routes outside a version group.
pub type Context(guarded) {
  Context(
    request: Request(Body),
    params: Dict(String, String),
    guard: guarded,
    version: Option(String),
  )
}

/// Wrap the connection of a request ewe handed us.
@internal
pub fn live(connection: ewe.Connection) -> Body {
  Live(connection:)
}

/// A body made of `bits`, appearing to come from `ip` if given.
@internal
pub fn fake(bits: BitArray, ip: Option(String)) -> Body {
  Fake(bits:, ip:)
}

/// Replace the bytes of a fake body. Live bodies are returned unchanged.
@internal
pub fn with_bits(body: Body, bits: BitArray) -> Body {
  case body {
    Fake(ip:, ..) -> Fake(bits:, ip:)
    Live(..) -> body
  }
}

/// Set the client address of a fake body. Live bodies are returned unchanged.
@internal
pub fn with_ip(body: Body, ip: String) -> Body {
  case body {
    Fake(bits:, ..) -> Fake(bits:, ip: Some(ip))
    Live(..) -> body
  }
}

/// The live connection behind a request, or `None` for a fake body.
@internal
pub fn connection(body: Body) -> Option(ewe.Connection) {
  case body {
    Live(connection:) -> Some(connection)
    Fake(..) -> None
  }
}

/// Read the whole request body, up to `limit` bytes.
pub fn read_body(
  request: Request(Body),
  limit limit: Int,
) -> Result(BitArray, ewe.BodyError) {
  case request.body {
    Live(connection:) ->
      case ewe.read_body(request.set_body(request, connection), limit:) {
        Ok(request) -> Ok(request.body)
        Error(error) -> Error(error)
      }
    Fake(bits:, ..) ->
      case bit_array.byte_size(bits) > limit {
        True -> Error(ewe.BodyTooLarge)
        False -> Ok(bits)
      }
  }
}

/// The address the request came from: an IP for TCP connections, the socket
/// path for Unix sockets, or `None` when it cannot be determined.
pub fn client_ip(request: Request(Body)) -> Option(String) {
  case request.body {
    Live(connection:) ->
      case ewe.get_client_info(connection) {
        Ok(ewe.TcpSocketAddress(ip_address:, ..)) ->
          Some(ewe.ip_address_to_string(ip_address))
        Ok(ewe.UnixSocketAddress(path)) -> Some(path)
        Error(Nil) -> None
      }
    Fake(ip:, ..) -> ip
  }
}
