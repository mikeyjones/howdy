//// Helper methods to extact querystring parameters

import gleam/http/request
import gleam/list
import howdy/context.{Context}

/// Gets the values of a querystring
///
/// ## Example:
/// ```gleam
/// get(context,"key")
/// ```
pub fn get_value(context: Context, key: String) -> Result(List(String), Nil) {
  case request.get_query(context.request) {
    Ok(query_list) ->
      query_list
      |> list.filter(fn(key_value) { key_value.0 == key })
      |> list.map(fn(key_value) { key_value.1 })
      |> Ok
    Error(_) -> Error(Nil)
  }
}
