import gleeunit/should
import howdy/context
import howdy/context/querystring.{get_value}
import howdy/helpers.{get_http_request}
import gleam/http/request
import gleam/result
import gleam/list

pub fn get_value_should_return_value_when_found_test() {
  let ctx =
    context.new(
      [],
      request.set_query(get_http_request(), [#("test", "info")]),
      Nil,
    )

  let sut =
    result.unwrap(get_value(ctx, "test"), [])
    |> list.first()

  should.be_ok(sut)
  should.equal("info", result.unwrap(sut, "Error"))
}

pub fn get_value_should_return_multiple_values_when_found_test() {
  let ctx =
    context.new(
      [],
      request.set_query(
        get_http_request(),
        [#("test", "info"), #("test", "hello"), #("hello", "bad")],
      ),
      Nil,
    )

  let sut = result.unwrap(get_value(ctx, "test"), [])

  should.equal(sut, ["info", "hello"])
}

pub fn get_value_should_return_error_when_value_is_not_present_test() {
  let ctx =
    context.new(
      [],
      request.set_query(get_http_request(), [#("test", "info")]),
      Nil,
    )

  let sut = result.unwrap(get_value(ctx, "bad"), ["bad"])

  should.equal(sut, [])
}

pub fn get_value_should_return_error_when_query_empty_test() {
  let ctx = context.new([], get_http_request(), Nil)

  let sut = result.unwrap(get_value(ctx, "bad"), ["bad"])

  should.equal(sut, [])
}
