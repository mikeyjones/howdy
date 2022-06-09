//// Body handles the request body helper methods. 
////
//// This relys on being passed the Context, and will
//// interigate the request object. 

import gleam/bit_string
import gleam/string
import gleam/list
import gleam/dynamic
import gleam/json
import gleam/result
import gleam/map.{Map}
import howdy/context.{Context}

/// Gets the body of the request as Json.
/// It will return an Error if it is unable to 
/// decode the contents of the request body as
/// a Json object.
///
/// # Example:
///
/// ```gleam
/// get_json(context, dynamic.decode2(
///              Input,
///              field("test", of: dynamic.string),
///              field("name", of: dynamic.string),
///            ))
/// ```
pub fn get_json(
  context in: Context,
  decoder: dynamic.Decoder(t),
) -> Result(t, json.DecodeError) {
  let result = bit_string.to_string(in.request.body)
  case result {
    Ok(str) -> json.decode(from: str, using: decoder)
    Error(_) -> Error(json.UnexpectedEndOfInput)
  }
}

/// Gets the request body as a key/value Map 
/// This is designed to work with HTML standard Post
/// methods.
///
/// **Note:** this does not support multipart forms
///
/// ## Example:
/// ```gleam
/// get_form(context)
/// ```
pub fn get_form(context in: Context) -> Result(Map(String, String), Nil) {
  try body = bit_string.to_string(in.request.body)

  body
  |> string.split("&")
  |> list.map(fn(x) {
    x
    |> string.split("=")
    |> to_tuple
  })
  |> list.filter(fn(x) { x != Error(Nil) })
  |> list.map(fn(x) { result.unwrap(x, #("", "")) })
  |> map.from_list
  |> Ok
}

fn to_tuple(lst: List(String)) -> Result(#(String, String), Nil) {
  case list.length(lst) {
    2 -> {
      try first = list.first(lst)
      try last = list.last(lst)
      Ok(#(first, last))
    }
    _ -> Error(Nil)
  }
}
