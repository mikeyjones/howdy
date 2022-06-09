//// helps for Gleams http response type

import gleam/json.{Json}
import gleam/http/response as http_response
import gleam/bit_builder.{BitBuilder}
import howdy/mime

/// Returns a 200 response with empty body contents
pub fn of_empty() {
  http_response.new(200)
}

/// Returns a 200 response with the body from 
/// the string type
pub fn of_string(text: String) {
  let body = bit_builder.from_string(text)

  http_response.new(200)
  |> http_response.set_body(body)
}

/// Returns a status 200 response with the body
/// of BitString
pub fn of_bit_string(content: BitString) -> http_response.Response(BitBuilder) {
  let body = bit_builder.from_bit_string(content)
  http_response.new(200)
  |> http_response.set_body(body)
}

/// Returns a not found response (404)
/// with response text
pub fn of_not_found(text: String) {
  of_string(text)
  |> with_status(404)
}

/// Returns an internal error (status 500)
/// with string content for the body
pub fn of_interal_error(text: String) {
  of_string(text)
  |> with_status(500)
}

/// Returns json with the status code  200
pub fn of_json(json: Json) {
  of_string(json.to_string(json))
  |> with_content_type(mime.from_extention("json"))
}

/// Overides the status code of the response
pub fn with_status(response: http_response.Response(out), status: Int) {
  http_response.Response(..response, status: status)
}

/// Appends the response headers with a key and value
pub fn with_header(
  response: http_response.Response(BitBuilder),
  key: String,
  value: String,
) {
  http_response.prepend_header(response, key, value)
}

/// Sets the content type of the response
pub fn with_content_type(
  response: http_response.Response(BitBuilder),
  content_type: String,
) {
  response
  |> with_header("Content-Type", content_type)
}

/// Sets the resonse status code to 202
pub fn with_accepted(response: http_response.Response(BitBuilder)) {
  response
  |> with_status(202)
}

/// Sets the resonse status code to 201
pub fn with_created(response: http_response.Response(BitBuilder)) {
  response
  |> with_status(201)
}
