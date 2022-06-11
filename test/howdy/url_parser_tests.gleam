import gleeunit/should
import gleam/list
import gleam/dynamic
import howdy/url_parser.{MatchingTemplateTypedSegment, parse}

pub fn parse_should_match_single_url_segment_test() {
  let result = parse("/test", "/test")
  should.be_ok(result)
}

pub fn parse_should_match_single_url_segment_with_missing_slash_test() {
  let result = parse("test/", "/test")
  should.be_ok(result)
}

pub fn parse_should_match_multiple_url_segments_test() {
  let result = parse("/test/route", "/test/route")
  should.be_ok(result)
}

pub fn parse_should_match_templated_string_route_test() {
  let result = parse("/test/{test:String}/", "/test/hello")

  case result {
    Ok(segments) -> {
      let last_segment = list.last(segments)
      case last_segment {
        Ok(MatchingTemplateTypedSegment(_, _, name, value)) -> {
          should.equal(name, "test")
          should.equal(value, dynamic.from("hello"))
        }
        _ -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn parse_should_match_templated_int_route_test() {
  let result = parse("/test/{test:Int}/", "/test/1")

  case result {
    Ok(segments) -> {
      let last_segment = list.last(segments)
      case last_segment {
        Ok(MatchingTemplateTypedSegment(_, _, name, value)) -> {
          should.equal(name, "test")
          should.equal(value, dynamic.from(1))
        }
        _ -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn parse_should_match_templated_float_route_test() {
  let result = parse("/test/{test:Float}/", "/test/1.1")

  case result {
    Ok(segments) -> {
      let last_segment = list.last(segments)
      case last_segment {
        Ok(MatchingTemplateTypedSegment(_, _, name, value)) -> {
          should.equal(name, "test")
          should.equal(value, dynamic.from(1.1))
        }
        _ -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn parse_should_error_with_none_matching_route_test() {
  let result = parse("/test/valid/", "test/invaild")

  should.be_error(result)
}

pub fn parse_should_error_with_incorrect_template_type_test() {
  let result = parse("/test/{name:Int}", "test/notnumber")

  should.be_error(result)
}

pub fn parse_should_error_malformed_template_not_matching_test() {
  let result = parse("/test/{name:String", "/test/hello")

  should.be_error(result)
}

pub fn parse_should_be_vaild_matching_malformed_templates_test() {
  let result = parse("/test/{name:string", "/test/{name:string")

  should.be_ok(result)
}

pub fn parse_should_be_vaild_with_diferent_casing_test() {
  let result = parse("/TEST/", "/test/")

  should.be_ok(result)
}

pub fn parse_should_be_valid_with_root_route_test() {
  let result = parse("/", "")

  should.be_ok(result)
}

pub fn parse_should_match_wildcard_route_test() {
  let result = parse("/test/*", "/test/more/segments")

  should.be_ok(result)
}

pub fn parse_should_not_match_wildcard_route_test() {
  let result = parse("/test/less/*", "/test/more/segments")

  should.be_error(result)
}

pub fn parse_should_not_match_wildcard_malformed_route_test() {
  let result = parse("/test*", "/test/more/segments")

  should.be_error(result)
}

pub fn parse_should_match_wildcard_with_different_case_route_test() {
  let result = parse("/test/*", "/TEST/more/segments")

  should.be_ok(result)
}

pub fn parse_should_match_uuid_should_successed_test() {
  let result =
    parse("/test/{id:uuid}", "/test/f7e321c7-4a4b-4287-a8b8-1ae35b5538ce")

  should.be_ok(result)
}
