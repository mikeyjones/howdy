//// Context that is passed to funxtions called from 
//// the router or the filter

import gleam/http/request.{Request}
import gleam/option.{None, Option}
import howdy/url_parser.{UrlSegment}
import howdy/context/user.{User}

pub type Context {
  Context(
    url: List(UrlSegment),
    request: Request(BitString),
    user: Option(User),
  )
}

/// Creates a new instance of the Context, filling in the default parameters
pub fn new(url: List(UrlSegment), request: Request(BitString)) {
  Context(url, request, None)
}
