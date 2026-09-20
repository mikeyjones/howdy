//// HTML forms submitted as `application/x-www-form-urlencoded`.
////
//// The body can be read only once, so `read` turns it into a `Form` and
//// every field is then taken from that value. Field problems are returned
//// as `validate` errors rather than responses, so a page can be rendered
//// again with its errors and the values the user typed.
////
//// A local variable named `form` would shadow this module, so call the
//// value something else, such as `fields`.
////
//// ```gleam
//// fn signup(fields: Form) -> validate.Result(Signup) {
////   use email <- form.string(fields, "email", [validate.email()])
////   use age <- form.int(fields, "age", [validate.min(13)])
////   use newsletter <- form.checkbox(fields, "newsletter")
////   validate.ok(Signup(email:, age:, newsletter:))
//// }
////
//// fn create(ctx: Context) {
////   use fields <- form.read(ctx)
////   case signup(fields) {
////     Ok(signup) -> ...
////     Error(errors) ->
////       controller.html(ctx, signup_page(fields, errors))
////       |> controller.with_status(422)
////   }
//// }
//// ```
////
//// Browsers submit an empty input as `name=`. `string` keeps the empty
//// string, so pair it with `validate.not_empty()`; `int` treats it as
//// missing; the `optional_*` helpers treat it as `None`. A singular field
//// submitted more than once is an error. Multipart forms are not supported
//// and get a `415`.
////
//// Form posts are not subject to CORS preflight, so cookie-authenticated
//// forms need CSRF protection. Use `howdy/csrf`, or the `Origin` check
//// `howdy_auth` already applies to routes behind its guard.

import ewe
import gleam/bit_array
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import howdy/body
import howdy/controller.{type GuardedContext}
import howdy/query
import howdy/service.{type FieldError}
import howdy/validate.{type Rule}

/// The fields of a submitted form, in the order they were sent.
pub opaque type Form {
  Form(fields: List(#(String, String)))
}

// -- Reading -----------------------------------------------------------------

/// Read the request body as a form. A wrong content type returns `415`; a
/// body that is too large or badly encoded returns `400`. The continuation
/// never runs in either case.
pub fn read(
  ctx: GuardedContext(guarded),
  next: fn(Form) -> Response(ewe.Body),
) -> Response(ewe.Body) {
  read_with_limit(ctx, body.default_limit, next)
}

/// Like `read` but with a custom size limit in bytes.
pub fn read_with_limit(
  ctx: GuardedContext(guarded),
  limit: Int,
  next: fn(Form) -> Response(ewe.Body),
) -> Response(ewe.Body) {
  case check_content_type(ctx) {
    Error(error) -> service.error_response(ctx, error)
    Ok(Nil) ->
      case controller.read_body(ctx, limit:) {
        Ok(bits) ->
          case parse(bits) {
            Ok(form) -> next(form)
            Error(Nil) ->
              invalid(ctx, "request body is not a valid urlencoded form")
          }
        Error(ewe.BodyTooLarge) -> invalid(ctx, "request body too large")
        Error(ewe.InvalidBody) -> invalid(ctx, "request body could not be read")
      }
  }
}

/// Read a form and validate it, for endpoints that answer with JSON. A
/// validation failure returns `422` with every field error, as
/// `body.validated` does. Pages that render their errors should use `read`.
pub fn validated(
  ctx: GuardedContext(guarded),
  validator: fn(Form) -> validate.Result(a),
  next: fn(a) -> Response(ewe.Body),
) -> Response(ewe.Body) {
  use form <- read(ctx)
  validate.check(ctx, validator(form), next)
}

/// A form made of `fields`, for calling a validator directly in a test.
pub fn from_fields(fields: List(#(String, String))) -> Form {
  Form(fields:)
}

// -- Raw access --------------------------------------------------------------

/// The first value submitted for `name`.
pub fn get(form: Form, name: String) -> Result(String, Nil) {
  list.key_find(form.fields, name)
}

/// Every value submitted for `name`, in order. An absent field gives `[]`.
pub fn all(form: Form, name: String) -> List(String) {
  form.fields
  |> list.filter(fn(field) { field.0 == name })
  |> list.map(fn(field) { field.1 })
}

/// The first value submitted for `name`, or `""`. Use it to fill an input
/// back in when rendering a form again. Escape it like any other user input.
pub fn value(form: Form, name: String) -> String {
  result.unwrap(get(form, name), "")
}

/// Every field, in the order submitted.
pub fn fields(form: Form) -> List(#(String, String)) {
  form.fields
}

/// The message for `name` among validation errors, if it has one.
pub fn error(errors: List(FieldError), name: String) -> Option(String) {
  list.find(errors, fn(error) { error.field == name })
  |> result.map(fn(error) { error.message })
  |> option.from_result
}

// -- Typed fields ------------------------------------------------------------
//
// Like `validate.field`, the continuation always runs so that later fields
// are checked too. When a field cannot be read it runs with a placeholder
// and its result is discarded.

/// A required string, checked with `rules`. An empty value is kept.
pub fn string(
  form: Form,
  name: String,
  rules: List(Rule(String)),
  next: fn(String) -> validate.Result(b),
) -> validate.Result(b) {
  let value = result.try(single(form, name), option.to_result(_, required))
  field(name, value, "", rules, next)
}

/// An optional string, checked with `rules` when given. An absent or empty
/// value is `None`, as is one that `rules` leave empty, such as by trimming.
pub fn optional_string(
  form: Form,
  name: String,
  rules: List(Rule(String)),
  next: fn(Option(String)) -> validate.Result(b),
) -> validate.Result(b) {
  let blank_to_none = fn(value) {
    case value {
      Some("") -> Ok(None)
      _ -> Ok(value)
    }
  }
  let rules = [blank_to_none, optionally(rules), blank_to_none]
  field(name, single(form, name), None, rules, next)
}

/// A required integer, checked with `rules`. An empty value is missing.
pub fn int(
  form: Form,
  name: String,
  rules: List(Rule(Int)),
  next: fn(Int) -> validate.Result(b),
) -> validate.Result(b) {
  let value =
    result.try(optional_integer(form, name), option.to_result(_, required))
  field(name, value, 0, rules, next)
}

/// An optional integer, checked with `rules` when given. An absent or empty
/// value is `None`.
pub fn optional_int(
  form: Form,
  name: String,
  rules: List(Rule(Int)),
  next: fn(Option(Int)) -> validate.Result(b),
) -> validate.Result(b) {
  field(name, optional_integer(form, name), None, [optionally(rules)], next)
}

/// Whether a checkbox was ticked. Browsers leave unticked checkboxes out of
/// the submission, so this is `True` when the field is present at all.
pub fn checkbox(
  form: Form,
  name: String,
  next: fn(Bool) -> validate.Result(b),
) -> validate.Result(b) {
  next(all(form, name) != [])
}

/// Every value of a field that may repeat, such as a multi-select.
pub fn strings(
  form: Form,
  name: String,
  next: fn(List(String)) -> validate.Result(b),
) -> validate.Result(b) {
  next(all(form, name))
}

const required = "is required"

/// The value of a field that must not repeat.
fn single(form: Form, name: String) -> Result(Option(String), String) {
  case all(form, name) {
    [] -> Ok(None)
    [value] -> Ok(Some(value))
    _ -> Error("must occur only once")
  }
}

fn optional_integer(form: Form, name: String) -> Result(Option(Int), String) {
  use value <- result.try(single(form, name))
  case value {
    None | Some("") -> Ok(None)
    Some(value) ->
      case int.parse(value) {
        Ok(value) -> Ok(Some(value))
        Error(Nil) -> Error("must be an integer")
      }
  }
}

/// Apply rules to the value inside `Some`, leaving `None` alone.
fn optionally(rules: List(Rule(a))) -> Rule(Option(a)) {
  fn(value) {
    case value {
      Some(value) -> result.map(validate.run(rules, value), Some)
      None -> Ok(None)
    }
  }
}

fn field(
  name: String,
  value: Result(a, String),
  placeholder: a,
  rules: List(Rule(a)),
  next: fn(a) -> validate.Result(b),
) -> validate.Result(b) {
  case value {
    Ok(value) -> validate.field(name, value, rules, next)
    Error(message) ->
      validate.field(name, placeholder, [fn(_) { Error(message) }], next)
  }
}

// -- Parsing -----------------------------------------------------------------

fn check_content_type(
  ctx: GuardedContext(guarded),
) -> Result(Nil, service.Error) {
  let content_type =
    request.get_header(ctx.request, "content-type")
    |> result.unwrap("")
    |> string.split(";")
    |> list.first
    |> result.unwrap("")
    |> string.trim
    |> string.lowercase
  case content_type {
    "application/x-www-form-urlencoded" -> Ok(Nil)
    "multipart/form-data" ->
      Error(service.UnsupportedMediaType("multipart forms are not supported"))
    _ ->
      Error(service.UnsupportedMediaType(
        "content type must be application/x-www-form-urlencoded",
      ))
  }
}

fn parse(bits: BitArray) -> Result(Form, Nil) {
  use text <- result.try(bit_array.to_string(bits))
  use fields <- result.map(query.parse_query(text))
  Form(fields:)
}

fn invalid(
  ctx: GuardedContext(guarded),
  message: String,
) -> Response(ewe.Body) {
  service.error_response(ctx, service.Invalid(message))
}
