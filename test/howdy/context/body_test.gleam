import gleeunit/should
import gleam/http/request
import gleam/map
import gleam/bit_string
import gleam/result
import howdy/context
import howdy/context/body.{get_form}
import howdy/helpers.{get_http_request}

pub fn get_form_should_return_map_if_vaild_string_test() {
  let req =
    get_http_request()
    |> request.set_body(bit_string.from_string("key=value"))

  let sut =
    get_form(context.new([], req))
    |> result.unwrap(map.new())
    |> map.get("key")

  case sut {
    Ok(val) -> should.equal(val, "value")
    Error(_) -> should.fail()
  }
}

pub fn get_form_should_return_map_if_vaild_strings_test() {
  let req =
    get_http_request()
    |> request.set_body(bit_string.from_string(
      "key1=value1&key2=value2&key3=value3",
    ))

  let sut =
    get_form(context.new([], req))
    |> result.unwrap(map.new())
    |> map.get("key2")

  case sut {
    Ok(val) -> should.equal(val, "value2")
    Error(_) -> should.fail()
  }
}

pub fn get_form_should_return_error_if_invaild_string_test() {
  let req =
    get_http_request()
    |> request.set_body(bit_string.from_string("keyvalue"))

  let sut =
    get_form(context.new([], req))
    |> result.unwrap(map.new())
    |> map.get("key")

  should.be_error(sut)
}
