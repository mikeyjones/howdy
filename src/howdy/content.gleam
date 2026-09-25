//// What a response carries. Handlers return `Response(Content)`, usually
//// built with `controller.text`, `controller.json` and friends.
////
//// ```gleam
//// response.new(200)
//// |> response.set_header("content-type", "text/csv")
//// |> response.set_body(content.Text(csv))
//// ```

import ewe
import gleam/bytes_tree.{type BytesTree}

/// The body of a response.
pub type Content {
  /// Text, sent as UTF-8.
  Text(String)
  /// Raw bytes.
  Bytes(BytesTree)
  /// No body at all.
  Empty
  /// A body only the server can send, such as a file from
  /// `howdy/static` or a socket upgrade from `howdy/websocket`. It cannot be
  /// built or read directly; middleware should pass it through unchanged.
  Native(Native)
}

/// See `Native` on `Content`.
pub opaque type Native {
  Wrapped(body: ewe.Body)
}

/// Wrap a body ewe built, such as a file or socket upgrade.
@internal
pub fn native(body: ewe.Body) -> Content {
  Native(Wrapped(body:))
}

/// The ewe body to send for `content`.
@internal
pub fn to_ewe(content: Content) -> ewe.Body {
  case content {
    Text(text) -> ewe.Text(text)
    Bytes(bytes) -> ewe.Bytes(bytes)
    Empty -> ewe.Empty
    Native(Wrapped(body:)) -> body
  }
}
