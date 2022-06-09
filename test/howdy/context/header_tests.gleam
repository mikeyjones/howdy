import gleeunit/should
import howdy/context
import howdy/context/header.{get_value}
import howdy/helpers.{get_http_request}
import gleam/http/request
import gleam/result

pub fn get_value_should_return_value_when_found_test() {
  let ctx =
    context.new([], request.prepend_header(get_http_request(), "test", "info"))

  let sut = get_value(ctx, "test")

  should.be_ok(sut)
  should.equal("info", result.unwrap(sut, "Error"))
}

pub fn get_value_should_return_error_when_value_is_not_present_test() {
  let ctx =
    context.new([], request.prepend_header(get_http_request(), "test", "info"))

  let sut = get_value(ctx, "bad")

  should.be_error(sut)
}

pub fn get_value_should_return_error_when_query_empty_test() {
  let ctx = context.new([], get_http_request())

  let sut = get_value(ctx, "bad")

  should.be_error(sut)
}
