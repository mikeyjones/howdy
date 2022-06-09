import gleam/http
import gleam/http/request as http_request
import gleam/bit_string
import gleam/option.{None}

pub fn get_http_request() {
  http_request.Request(
    method: http.Get,
    headers: [#("test", "header")],
    body: bit_string.from_string(""),
    scheme: http.Http,
    host: "192.168.0.1",
    port: None,
    path: "/",
    query: None,
  )
}
