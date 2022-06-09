//// Helper functions to handle URL elemnts of the 
//// context. 

import gleam/list
import gleam/result
import gleam/option.{None, Some}
import gleam/dynamic
import howdy/context.{Context}
import howdy/url_parser.{MatchingTemplateTypedSegment, UrlSegment}

/// Gets a dynamic segment for the URL of type String.
/// Returns Error(Nil) if no matching string is found for the given key
///
/// ## Example
///
/// ```gleam
/// get_string(context, "name")
/// ```
pub fn get_string(context: Context, key: String) -> Result(String, Nil) {
  context.url
  |> list.find(fn(segment) { has_matching_template_key(segment, key) })
  |> result.map(fn(segment) {
    get_value_from_template_segment(segment)
    |> option.map(fn(dynamic_value) {
      dynamic.string(dynamic_value)
      |> result.replace_error(Nil)
    })
    |> option.to_result(Nil)
    |> result.flatten()
  })
  |> result.flatten()
}

/// Gets a dynamic segment for the URL of type Int.
/// Returns Error(Nil) if no matching int is found for the given key
///
/// ## Example
///
/// ```gleam
/// get_int(context, "name")
/// ```
pub fn get_int(context: Context, key: String) -> Result(Int, Nil) {
  context.url
  |> list.find(fn(segment) { has_matching_template_key(segment, key) })
  |> result.map(fn(segment) {
    get_value_from_template_segment(segment)
    |> option.map(fn(dynamic_value) {
      dynamic.int(dynamic_value)
      |> result.replace_error(Nil)
    })
    |> option.to_result(Nil)
    |> result.flatten()
  })
  |> result.flatten()
}

/// Gets a dynamic segment for the URL of type Float.
/// Returns Error(Nil) if no matching float is found for the given key
///
/// ## Example
///
/// ```gleam
/// get_float(context, "name")
/// ```
pub fn get_float(context: Context, key: String) -> Result(Float, Nil) {
  context.url
  |> list.find(fn(segment) { has_matching_template_key(segment, key) })
  |> result.map(fn(segment) {
    get_value_from_template_segment(segment)
    |> option.map(fn(dynamic_value) {
      dynamic.float(dynamic_value)
      |> result.replace_error(Nil)
    })
    |> option.to_result(Nil)
    |> result.flatten()
  })
  |> result.flatten()
}

fn has_matching_template_key(segment: UrlSegment, key: String) {
  case segment {
    MatchingTemplateTypedSegment(_, _, name, _) -> name == key
    _ -> False
  }
}

fn get_value_from_template_segment(segment: UrlSegment) {
  case segment {
    MatchingTemplateTypedSegment(_, _, _, value) -> Some(value)
    _ -> None
  }
}
