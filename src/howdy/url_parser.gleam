//// Handles matching of router template to the incoming request route 

import gleam/uri
import gleam/list
import gleam/result
import gleam/option.{None, Option, Some, from_result}
import gleam/dynamic.{Dynamic}
import gleam/string
import gleam/int
import gleam/float
import howdy/uuid

/// Error return types for parsing URL segments
pub type SegmentError {
  /// None matching URL
  NonMatchingUrl
}

/// Matching segment types
pub type UrlSegment {
  /// Set when the template segment matches the request segment
  MatchingSegment(lhs: String, rhs: String)

  /// Sets a template segemnt if the URL matches the templated segment
  MatchingTemplateTypedSegment(
    lhs: String,
    rhs: String,
    name: String,
    value: dynamic.Dynamic,
  )

  /// Sets the wildcard segment if the template ends with a '*'
  ///
  /// ### Example
  ///
  /// ```gleam
  /// WildcardSegment(lhs: "/blog/*", rhs: "/blog/page1/content", wildcard_path: "page1/content")
  /// ```
  WildcardSegment(lhs: String, rhs: String, wilcard_path: String)

  /// Sets a non matching segment, this means that the Url from the 
  /// request no longer matches the template url, and forces the parse 
  /// to stop parsing the remaining url segments and retur an Error
  NonMatchingSegment
}

/// parses the route template and the request path into a list of UrlSegments
pub fn parse(template: String, path: String) {
  case string.ends_with(template, "*") {
    True -> wildcard_parse(template, path)
    False -> template_parse(template, path)
  }
}

fn template_parse(template: String, path: String) {
  let template_url = uri.path_segments(template)
  let path_url = uri.path_segments(path)

  list.strict_zip(template_url, path_url)
  |> result.replace_error(NonMatchingUrl)
  |> result.map(url_parts)
  |> result.flatten
}

fn wildcard_parse(template: String, path: String) {
  let template_url = uri.path_segments(template)
  let path_url = uri.path_segments(path)

  list.zip(template_url, path_url)
  |> wildcard_parts(template, path)
}

fn wildcard_parts(
  url_parts: List(#(String, String)),
  template: String,
  path: String,
) {
  list.map(
    url_parts,
    fn(part) {
      case is_wild_card(part.0), template_matches_path(part) {
        True, _ ->
          WildcardSegment(part.0, part.1, wildcard_join_paths(template, path))
        _, True -> MatchingSegment(part.0, part.1)
        _, _ -> NonMatchingSegment
      }
    },
  )
  |> has_nonmatching_segments
}

fn wildcard_join_paths(template: String, path: String) {
  let striped_template = string.drop_right(template, 1)
  string.replace(path, striped_template, "")
}

fn is_wild_card(template_segment: String) {
  template_segment == "*"
}

fn url_parts(url_parts: List(#(String, String))) {
  list.map(url_parts, convert_to_url_segment)
  |> has_nonmatching_segments
}

// This is a problem, it can be optimised once if is introduced, see 
// https://github.com/gleam-lang/suggestions/issues/68
// for more details
fn convert_to_url_segment(url_part: #(String, String)) {
  case is_templated_path(url_part), template_matches_path(url_part) {
    True, False -> process_templated_url_segment(url_part)
    False, True -> MatchingSegment(url_part.0, url_part.1)
    _, _ -> NonMatchingSegment
  }
}

// fn convert_to_url_segment(url_part: #(String, String)) {
//   case url_part {
//     #(template, value) if is_templated_path(template) ->
//       process_templated_url_segment(url_part)
//     #(template, value) if template == value -> MatchingSegment(template, value)
//     _ -> NonMatchingSegment
//   }
// }
fn is_templated_path(key_value: #(String, String)) {
  string.starts_with(key_value.0, "{") && string.ends_with(key_value.0, "}")
}

fn template_matches_path(key_value: #(String, String)) {
  string.lowercase(key_value.0) == string.lowercase(key_value.1)
}

fn process_templated_url_segment(url_part: #(String, String)) {
  case do_process_templated_url_segment(url_part) {
    Ok(result) -> result
    Error(_) -> NonMatchingSegment
  }
}

fn do_process_templated_url_segment(url_part: #(String, String)) {
  let #(template_url, path_url) = url_part

  template_url
  |> string.drop_left(up_to: 1)
  |> string.drop_right(up_to: 1)
  |> string.split_once(on: ":")
  |> result.map(process_template(_, path_url))
  |> result.map(convert_to_template_url_segment(_, template_url, path_url))
}

fn process_template(
  key_value: #(String, String),
  input: String,
) -> #(Option(Dynamic), String) {
  let #(name, template_type) = key_value
  let result = case string.lowercase(template_type) {
    "string" -> process_string(input)
    "int" -> process_int(input)
    "float" -> process_float(input)
    "uuid" -> process_uuid(input)
    _ -> None
  }
  #(result, name)
}

fn convert_to_template_url_segment(
  result: #(Option(Dynamic), String),
  template_segment: String,
  path_segment: String,
) {
  let #(processed, name) = result
  case processed {
    Some(value) ->
      MatchingTemplateTypedSegment(template_segment, path_segment, name, value)
    None -> NonMatchingSegment
  }
}

fn process_string(value: String) -> Option(Dynamic) {
  string.to_option(value)
  |> option.map(fn(str) { dynamic.from(str) })
}

fn process_int(value: String) -> Option(Dynamic) {
  int.parse(value)
  |> from_result()
  |> option.map(fn(num) { dynamic.from(num) })
}

fn process_float(value: String) -> Option(Dynamic) {
  float.parse(value)
  |> from_result()
  |> option.map(fn(num) { dynamic.from(num) })
}

fn process_uuid(value: String) -> Option(Dynamic) {
  uuid.from_string(value)
  |> from_result()
  |> option.map(fn(_id) { dynamic.from(value) })
}

fn has_nonmatching_segments(segments: List(UrlSegment)) {
  case list.contains(segments, NonMatchingSegment) {
    True -> Error(NonMatchingUrl)
    False -> Ok(segments)
  }
}
