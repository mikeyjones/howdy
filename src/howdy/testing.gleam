//// Exercise an app without starting a server.
////
//// Build a request, send it through the app, and read the response. The
//// whole pipeline runs: routing, middleware, guards, versioning, body
//// decoding and validation. Nothing touches a socket, so tests are fast and
//// need no ports.
////
//// ```gleam
//// import howdy/testing
////
//// fn app() {
////   howdy.new() |> howdy.controller(user_controller())
//// }
////
//// pub fn create_user_test() {
////   let res =
////     testing.post("/user", json.object([#("name", json.string("Ada"))]))
////     |> testing.header("x-api-key", "secret")
////     |> testing.send(app())
////
////   assert res.status == 201
////   assert testing.json(res, user.decoder()) == Ok(User(id: 1, name: "Ada"))
//// }
////
//// pub fn rejects_blank_name_test() {
////   let res =
////     testing.post("/user", json.object([#("name", json.string(""))]))
////     |> testing.send(app())
////
////   assert res.status == 422
////   assert testing.field_errors(res)
////     == Ok([service.FieldError("name", "must not be empty")])
//// }
//// ```
////
//// Requests are ordinary `gleam/http/request` values, so anything that
//// module offers, such as `request.set_header`, works on them too.

import ewe
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode.{type Decoder}
import gleam/http.{type Method}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import howdy.{type App}
import howdy/context.{type Body}
import howdy/service.{type FieldError}

// -- Building requests -------------------------------------------------------

/// A request with the given method and no body. A query string in `path`,
/// such as `"/users?page=2"`, is split off and set as the query.
pub fn request(method: Method, path: String) -> Request(Body) {
  let #(path, query) = case string.split_once(path, "?") {
    Ok(#(path, query)) -> #(path, Some(query))
    Error(Nil) -> #(path, None)
  }
  request.new()
  |> request.set_method(method)
  |> request.set_path(path)
  |> request.set_body(context.fake(<<>>, None))
  |> fn(req) { request.Request(..req, query:) }
}

pub fn get(path: String) -> Request(Body) {
  request(http.Get, path)
}

pub fn delete(path: String) -> Request(Body) {
  request(http.Delete, path)
}

/// A `POST` with a JSON body and matching content type.
pub fn post(path: String, body: Json) -> Request(Body) {
  request(http.Post, path) |> json_body(body)
}

/// A `PUT` with a JSON body and matching content type.
pub fn put(path: String, body: Json) -> Request(Body) {
  request(http.Put, path) |> json_body(body)
}

/// A `PATCH` with a JSON body and matching content type.
pub fn patch(path: String, body: Json) -> Request(Body) {
  request(http.Patch, path) |> json_body(body)
}

/// A `POST` of an HTML form: the pairs are urlencoded and the content type
/// set, as a browser would submit them.
pub fn post_form(
  path: String,
  pairs: List(#(String, String)),
) -> Request(Body) {
  request(http.Post, path) |> form_body(pairs)
}

/// Replace the body with JSON and set the content type.
pub fn json_body(req: Request(Body), body: Json) -> Request(Body) {
  req
  |> bytes_body(<<json.to_string(body):utf8>>)
  |> request.set_header("content-type", "application/json")
}

/// Replace the body with urlencoded form fields and set the content type.
/// Repeat a name for multi-value fields such as multi-selects.
pub fn form_body(
  req: Request(Body),
  pairs: List(#(String, String)),
) -> Request(Body) {
  req
  |> bytes_body(<<uri.query_to_string(pairs):utf8>>)
  |> request.set_header("content-type", "application/x-www-form-urlencoded")
}

/// Replace the body with text and set the content type.
pub fn text_body(req: Request(Body), body: String) -> Request(Body) {
  req
  |> bytes_body(<<body:utf8>>)
  |> request.set_header("content-type", "text/plain; charset=utf-8")
}

/// Replace the body with raw bytes. No content type is set.
pub fn bytes_body(req: Request(Body), body: BitArray) -> Request(Body) {
  request.set_body(req, context.with_bits(req.body, body))
}

/// Set a header, replacing any existing value.
pub fn header(
  req: Request(Body),
  name: String,
  value: String,
) -> Request(Body) {
  request.set_header(req, name, value)
}

/// Set the query string from key and value pairs, replacing any existing
/// query. Values are encoded for you.
pub fn query(
  req: Request(Body),
  pairs: List(#(String, String)),
) -> Request(Body) {
  request.set_query(req, pairs)
}

/// Add a cookie. The value is percent-encoded, matching what `cookie.set`
/// writes, so anything `cookie.string` can read round-trips.
pub fn cookie(
  req: Request(Body),
  name: String,
  value: String,
) -> Request(Body) {
  request.set_cookie(req, name, uri.percent_encode(value))
}

/// Make the request appear to come from `ip`. Without this the client
/// address is unknown and `rate_limit.by_ip` does not count the request.
pub fn from_ip(req: Request(Body), ip: String) -> Request(Body) {
  request.set_body(req, context.with_ip(req.body, ip))
}

// -- Sending -----------------------------------------------------------------

/// Run the request through the app and return the response, exactly as the
/// server would produce it.
pub fn send(req: Request(Body), app: App) -> Response(ewe.Body) {
  howdy.serve(app)(req)
}

// -- Reading responses -------------------------------------------------------

/// The response body as text. `Empty` is `""`. Panics for bodies that are
/// not UTF-8 or that stream, since those cannot be read in a test.
pub fn text(res: Response(ewe.Body)) -> String {
  case bit_array.to_string(bytes(res)) {
    Ok(text) -> text
    Error(Nil) -> panic as "howdy/testing: response body is not valid UTF-8"
  }
}

/// The response body as bytes. `Empty` is `<<>>`. Panics for bodies that
/// stream, since those cannot be read in a test.
pub fn bytes(res: Response(ewe.Body)) -> BitArray {
  case res.body {
    ewe.Text(text) -> <<text:utf8>>
    ewe.Bytes(tree) -> bytes_tree.to_bit_array(tree)
    ewe.Empty -> <<>>
    _ -> panic as "howdy/testing: response body is streamed and cannot be read"
  }
}

/// Decode the response body as JSON with `decoder`.
pub fn json(
  res: Response(ewe.Body),
  decoder: Decoder(a),
) -> Result(a, json.DecodeError) {
  json.parse_bits(bytes(res), decoder)
}

/// The message from a standard error response, `{"error": "..."}`, as
/// produced by `service.error_response`. `Error(Nil)` when the body is not
/// one.
pub fn error(res: Response(ewe.Body)) -> Result(String, Nil) {
  let decoder = {
    use message <- decode.field("error", decode.string)
    decode.success(message)
  }
  json(res, decoder) |> result.replace_error(Nil)
}

/// The field errors from a `422` validation response. `Error(Nil)` when the
/// body is not one.
pub fn field_errors(res: Response(ewe.Body)) -> Result(List(FieldError), Nil) {
  let field = {
    use field <- decode.field("field", decode.string)
    use message <- decode.field("message", decode.string)
    decode.success(service.FieldError(field:, message:))
  }
  let decoder = {
    use fields <- decode.field("fields", decode.list(field))
    decode.success(fields)
  }
  json(res, decoder) |> result.replace_error(Nil)
}

/// Every cookie the response sets, as name and decoded value pairs in the
/// order they were set. A deleted cookie appears with an empty value.
/// Attributes such as `Path` and `Max-Age` are dropped; read the raw
/// `set-cookie` headers to check those.
pub fn cookies(res: Response(ewe.Body)) -> List(#(String, String)) {
  res.headers
  |> list.filter(fn(pair) { pair.0 == "set-cookie" })
  // gleam/http prepends headers, so the newest cookie comes first.
  |> list.reverse
  |> list.filter_map(fn(pair) {
    let cookie = case string.split_once(pair.1, ";") {
      Ok(#(cookie, _)) -> cookie
      Error(Nil) -> pair.1
    }
    case string.split_once(cookie, "=") {
      Ok(#(name, value)) ->
        Ok(#(
          string.trim(name),
          uri.percent_decode(value) |> result.unwrap(value),
        ))
      Error(Nil) -> Error(Nil)
    }
  })
}
