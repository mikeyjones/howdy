import gleeunit/should
import howdy/url_parser.{MatchingTemplateTypedSegment}
import howdy/helpers.{get_http_request}
import howdy/context
import howdy/context/url.{get_float, get_int, get_string, get_uuid}
import gleam/dynamic
import gleam/result
import gleam/int
import gleam/float

pub fn get_string_should_find_string_value_from_key_test() {
  let value = "Foo"
  let request_data =
    context.new(
      [
        MatchingTemplateTypedSegment(
          "{Name:String}",
          value,
          "Name",
          dynamic.from(value),
        ),
      ],
      get_http_request(),
      Nil,
    )

  let sut = get_string(request_data, "Name")

  should.be_ok(sut)
  should.equal(value, result.unwrap(sut, "Failed"))
}

pub fn get_string_should_find_error_from_invalid_key_test() {
  let value = "Foo"
  let request_data =
    context.new(
      [
        MatchingTemplateTypedSegment(
          "{Name:String}",
          value,
          "Name",
          dynamic.from(value),
        ),
      ],
      get_http_request(),
      Nil,
    )

  let sut = get_string(request_data, "Bad")

  should.be_error(sut)
}

pub fn get_string_should_find_error_with_empty_url_test() {
  let request_data = context.new([], get_http_request(), Nil)

  let sut = get_string(request_data, "Bad")

  should.be_error(sut)
}

pub fn get_int_should_find_int_value_from_key_test() {
  let value = 101
  let request_data =
    context.new(
      [
        MatchingTemplateTypedSegment(
          "{Id:Int}",
          int.to_string(value),
          "Id",
          dynamic.from(value),
        ),
      ],
      get_http_request(),
      Nil,
    )

  let sut = get_int(request_data, "Id")

  should.be_ok(sut)
  should.equal(value, result.unwrap(sut, -1))
}

pub fn get_uuid_should_find_uuid_value_from_key_test() {
  let value = "f7e321c7-4a4b-4287-a8b8-1ae35b5538ce"
  let request_data =
    context.new(
      [
        MatchingTemplateTypedSegment(
          "{Id:Uuid}",
          value,
          "Id",
          dynamic.from(value),
        ),
      ],
      get_http_request(),
      Nil,
    )

  let sut = get_uuid(request_data, "Id")

  should.be_ok(sut)
}

pub fn get_uuid_should_error_with_an_invalid_uuid_value_from_key_test() {
  let value = "f7e321c7-4a4b-4287-a8b8-1ae35b5538c"
  let request_data =
    context.new(
      [
        MatchingTemplateTypedSegment(
          "{Id:Uuid}",
          value,
          "Id",
          dynamic.from(value),
        ),
      ],
      get_http_request(),
      Nil,
    )

  let sut = get_uuid(request_data, "Id")

  should.be_error(sut)
}

pub fn get_int_should_find_error_with_empty_url_test() {
  let request_data = context.new([], get_http_request(), Nil)

  let sut = get_int(request_data, "Bad")

  should.be_error(sut)
}

pub fn get_float_should_find_int_value_from_key_test() {
  let value = 1.56
  let request_data =
    context.new(
      [
        MatchingTemplateTypedSegment(
          "{Id:Float}",
          float.to_string(value),
          "Id",
          dynamic.from(value),
        ),
      ],
      get_http_request(),
      Nil,
    )

  let sut = get_float(request_data, "Id")

  should.be_ok(sut)
  should.equal(value, result.unwrap(sut, -1.0))
}

pub fn get_float_should_find_error_with_empty_url_test() {
  let request_data = context.new([], get_http_request(), Nil)

  let sut = get_float(request_data, "Bad")

  should.be_error(sut)
}
