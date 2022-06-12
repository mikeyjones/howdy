//// Context that is passed to funxtions called from 
//// the router or the filter

import gleam/http/request.{Request}
import gleam/option.{None, Option, Some}
import howdy/url_parser.{UrlSegment}
import howdy/context/user.{User}

pub type Context(a) {
  Context(
    url: List(UrlSegment),
    request: Request(BitString),
    user: Option(User),
    config: a,
  )
}

/// Creates a new instance of the Context, filling in the default parameters
pub fn new(url: List(UrlSegment), request: Request(BitString), config: a) {
  Context(url, request, None, config)
}

pub fn is_authenticated(context: Context(a)) {
  case context.user {
    Some(_) -> True
    None -> False
  }
}
