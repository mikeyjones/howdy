//// Body handles the request body helper methods. 
////
//// This relys on being passed the Context, and will
//// interigate the request object. 

import gleam/bit_string
import gleam/dynamic
import gleam/json
import gleam/uri
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
  context in: Context(a),
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
pub fn get_form(context in: Context(a)) -> Result(List(#(String, String)), Nil) {
  try body = bit_string.to_string(in.request.body)
  uri.parse_query(body)
}

