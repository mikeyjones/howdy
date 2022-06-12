//// built in filter functions for Howdy

import gleam/http/response.{Response}
import gleam/bit_builder.{BitBuilder}
import gleam/option.{Some}
import howdy/context.{Context}
import howdy/context/header
import howdy/context/user.{User}
import howdy/response
import howdy/mime

pub type Filter(a) =
  fn(Context(a)) -> Response(BitBuilder)

/// Filters on the mime type in the request headers of
/// the 'Accept' key
///
/// ## Example
///
/// ```gleam
///  filters: [ must_accept(_,"application/json")] 
/// ```
pub fn must_accept(filter: Filter(a), mime_type: String) {
  fn(context: Context(a)) {
    case header.get_value(context, "Accept") {
      Ok(value) if value == mime_type -> filter(context)
      _ -> response.of_not_found("")
    }
  }
}

// filters on the the Accept value equalling
/// 'application/json' 
///
/// ```gleam
/// filters: [accepts_json]
/// ```
pub fn accepts_json(filter: Filter(a)) {
  must_accept(filter, mime.from_extention("json"))
}

/// filters on the the Accept value equalling
/// 'application/html' 
///
/// ```gleam
/// filters: [accepts_html]
/// ```
pub fn accepts_html(filter: Filter(a)) {
  must_accept(filter, mime.from_extention("html"))
}

pub fn authenticate(
  filter: Filter(a),
  auth: fn(Context(a)) -> Result(User, Nil),
) {
  fn(context) {
    case auth(context) {
      Ok(user) ->
        Context(..context, user: Some(user))
        |> filter
      Error(_) ->
        response.of_string("")
        |> response.with_status(401)
    }
  }
}
