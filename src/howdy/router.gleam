import gleam/http/response.{Response}
import gleam/bit_builder.{BitBuilder}
import howdy/filter.{Filter}
import howdy/context.{Context}

/// Handles the router types 
pub type Route {
  /// Sets a function response for a request with a get method
  Get(route: String, func: fn(Context) -> Response(BitBuilder))

  /// Sets a function response for a request with a post method
  Post(route: String, func: fn(Context) -> Response(BitBuilder))

  /// Sets a function response for a request with a put method
  Put(route: String, func: fn(Context) -> Response(BitBuilder))

  /// Sets a functions response for a request with a patch method
  Patch(route: String, func: fn(Context) -> Response(BitBuilder))

  /// Sets a function with a response for a request with a custom method type
  Custom(
    method: String,
    route: String,
    func: fn(Context) -> Response(BitBuilder),
  )

  /// Sets a function with a response for a request with a delete method
  Delete(route: String, func: fn(Context) -> Response(BitBuilder))

  /// Sets a wildcard path for the router and trys to match files found in the file_path 
  Static(route: String, file_path: String)

  /// Sets a route that contains a list of other routes
  RouterMap(route: String, routes: List(Route))

  /// Sets a route that contains a list of other routes and applys a filter
  /// to each of the contained routes
  RouterMapWithFilters(
    route: String,
    routes: List(Route),
    filters: List(fn(Filter) -> Filter),
  )

  /// Sets a wildcard route that will always foward to a specific file
  ///
  /// ## Example
  ///
  /// ```gleam
  /// Spa("/", "./client/index.html")
  Spa(route: String, file_path: String)
}
