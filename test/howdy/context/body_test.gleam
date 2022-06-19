import gleeunit/should
import gleam/http/request
import gleam/list
import gleam/bit_string
import gleam/result
import howdy/context
import howdy/context/body.{get_form}
import howdy/helpers.{get_http_request}

pub fn get_form_should_return_list_if_vaild_string_test() {
  let req =
    get_http_request()
    |> request.set_body(bit_string.from_string("key=value"))

  let sut =
    get_form(context.new([], req, Nil))
    |> result.unwrap([])
    |> list.find(fn(key_value) { key_value.0 == "key"})

  case sut {
    Ok(val) -> should.equal(val.1, "value")
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
    get_form(context.new([], req, Nil))
    |> result.unwrap([])
    |> list.find(fn(key_value) { key_value.0 == "key2"})

  case sut {
    Ok(val) -> should.equal(val.1, "value2")
    Error(_) -> should.fail()
  }
}

pub fn get_form_should_return_error_if_invaild_string_test() {
  let req =
    get_http_request()
    |> request.set_body(bit_string.from_string("keyvalue"))

  let sut =
    get_form(context.new([], req, Nil))
    |> result.unwrap([])
    |> list.find(fn(key_value) { key_value.0 == "key"})

  should.be_error(sut)
}
