//// Services hold application logic and return plain results. This module
//// turns those results into HTTP responses so controllers stay lean.
////
//// ```gleam
//// fn by_id(ctx: Context) {
////   use id <- param.int(ctx, "id")
////   user_service.find(id)
////   |> service.respond(ctx, user.to_json)
//// }
//// ```

import ewe
import gleam
import gleam/http/response.{type Response}
import gleam/int
import gleam/json.{type Json}
import howdy/context.{type Context}
import logging

/// The ways a service call can fail. Each variant maps to a status code.
pub type Error {
  /// 404. The message names what was not found.
  NotFound(String)
  /// 400. The message explains what was wrong with the input.
  Invalid(String)
  /// 409. The message explains the conflict.
  Conflict(String)
  /// 401.
  Unauthorized
  /// 403.
  Forbidden
  /// 500. The message is logged and never sent to the client.
  Internal(String)
  /// 422. Input was well formed but failed validation. Usually produced by
  /// `howdy/validate`, but a service can return it too, for example for a
  /// duplicate email.
  Validation(List(FieldError))
  /// 429 with a `retry-after` header. Usually produced by `howdy/rate_limit`,
  /// but a service can return it too, for example for password resets.
  TooManyRequests(retry_after_seconds: Int)
}

/// One problem with one field. The same type as `validate.FieldError`.
pub type FieldError {
  FieldError(field: String, message: String)
}

/// The result type every service function returns.
pub type Result(a) =
  gleam.Result(a, Error)

/// `Ok` becomes `200` with the encoded value. `Error` becomes the matching
/// status with a JSON body of `{"error": "..."}`.
pub fn respond(
  result: Result(a),
  ctx: Context(guarded),
  encode: fn(a) -> Json,
) -> Response(ewe.Body) {
  case result {
    Ok(value) -> json_response(encode(value))
    Error(error) -> error_response(ctx, error)
  }
}

/// Like `respond` but `Ok` becomes `201`.
pub fn created(
  result: Result(a),
  ctx: Context(guarded),
  encode: fn(a) -> Json,
) -> Response(ewe.Body) {
  case result {
    Ok(value) -> json_response(encode(value)) |> with_status(201)
    Error(error) -> error_response(ctx, error)
  }
}

/// `Ok` becomes `204` with no body. Useful for deletes.
pub fn no_content(
  result: Result(Nil),
  ctx: Context(guarded),
) -> Response(ewe.Body) {
  case result {
    Ok(Nil) -> response.new(204) |> response.set_body(ewe.Empty)
    Error(error) -> error_response(ctx, error)
  }
}

/// The status code an error maps to.
pub fn status_code(error: Error) -> Int {
  case error {
    NotFound(_) -> 404
    Invalid(_) -> 400
    Conflict(_) -> 409
    Unauthorized -> 401
    Forbidden -> 403
    Internal(_) -> 500
    Validation(_) -> 422
    TooManyRequests(_) -> 429
  }
}

/// The message sent to the client for an error.
pub fn message(error: Error) -> String {
  case error {
    NotFound(message) -> message
    Invalid(message) -> message
    Conflict(message) -> message
    Unauthorized -> "unauthorized"
    Forbidden -> "forbidden"
    Internal(_) -> "internal server error"
    Validation(_) -> "validation failed"
    TooManyRequests(_) -> "too many requests"
  }
}

/// Build the response for an error. Used by `respond` and by the extractors
/// in `howdy/param` and `howdy/body` so every error has the same shape.
pub fn error_response(
  _ctx: Context(guarded),
  error: Error,
) -> Response(ewe.Body) {
  case error {
    Internal(detail) -> logging.log(logging.Error, detail)
    _ -> Nil
  }

  let fields = case error {
    Validation(errors) -> [
      #(
        "fields",
        json.array(errors, fn(e) {
          json.object([
            #("field", json.string(e.field)),
            #("message", json.string(e.message)),
          ])
        }),
      ),
    ]
    _ -> []
  }

  let response =
    json_response(
      json.object([#("error", json.string(message(error))), ..fields]),
    )
    |> with_status(status_code(error))

  case error {
    TooManyRequests(seconds) ->
      response.set_header(response, "retry-after", int.to_string(seconds))
    _ -> response
  }
}

fn json_response(body: Json) -> Response(ewe.Body) {
  response.new(200)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(ewe.Text(json.to_string(body)))
}

fn with_status(res: Response(ewe.Body), code: Int) -> Response(ewe.Body) {
  response.Response(..res, status: code)
}
