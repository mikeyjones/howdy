//// Middleware runs around a handler. It can reject a request before the
//// handler runs, change the context on the way in, or change the response
//// on the way out.
////
//// ```gleam
//// pub fn require_api_key(ctx: Context, next: Next) {
////   case request.get_header(ctx.request, "x-api-key") {
////     Ok("secret") -> next(ctx)
////     _ -> service.error_response(ctx, service.Unauthorized)
////   }
//// }
//// ```
////
//// Apply it at three levels:
////
//// ```gleam
//// howdy.new() |> howdy.middleware(request_logger)              // every request
//// controller.new("user") |> controller.middleware(require_api_key) // every route
//// controller.post("/", create |> middleware.wrap(rate_limit))   // one route
//// ```
////
//// App middleware wraps controller middleware, which wraps route middleware,
//// which wraps the handler. Within a level the first added is the outermost.

import howdy/controller.{type Handler}

pub type Next =
  controller.Next

pub type Middleware =
  controller.Middleware

/// Wrap a handler in one middleware.
pub fn wrap(handler: Handler, middleware: Middleware) -> Handler {
  controller.wrap(handler, middleware)
}

/// Wrap a handler in several middleware. The first in the list is the
/// outermost.
pub fn wrap_all(handler: Handler, middleware: List(Middleware)) -> Handler {
  controller.wrap_all(handler, middleware)
}
