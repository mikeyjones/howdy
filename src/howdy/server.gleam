//// Howdy server, using cowboy as the base server

import gleam/http/cowboy
import gleam/http.{Method}
import gleam/http/response.{Response}
import gleam/http/request.{Request}
import gleam/http/service.{Service}
import gleam/otp/actor
import gleam/otp/process.{Sender}
import gleam/bit_builder.{BitBuilder}
import gleam/string
import gleam/io
import gleam/list
import gleam/function.{compose}
import gleam/option.{None, Option, Some}
import howdy/url_parser.{UrlSegment}
import howdy/router
import howdy/filter.{Filter}
import howdy/context.{Context}
import howdy/static_resource

/// starts a new instance of Howdy setting the port 
/// number to 3000
pub fn start(router: router.Route) {
  start_with_port(3000, router)
}

/// starts a new instance of Howdy and sets the port number 
pub fn start_with_port(port: Int, router: router.Route) {
  let actor = actor.start(State([], None), handle_message)
  case actor {
    Ok(pid) ->
      case cowboy.start(my_service(pid, _), on_port: port) {
        Ok(_) -> {
          register_routes(pid, router)
          Ok(pid)
        }
        Error(error) -> Error(error)
      }
    Error(error) -> Error(error)
  }
}

fn not_found() {
  let body = bit_builder.from_string("Not Found!")

  response.new(404)
  |> response.prepend_header("made-with", "Gleam")
  |> response.set_body(body)
}

fn my_service(pid, req: Request(BitString)) -> Response(BitBuilder) {
  let service = fn(request: Request(BitString)) {
    let match = match_route(pid, request.path, request.method)

    // let _ =
    //   bit_string.to_string(request.body)
    //   |> result.map(fn(x) { io.println(x) })
    case match {
      SuccessfulRequest(route, url) -> {
        let context = context.new(url, request)
        // let filters_result =
        //   list.reduce(route.filters, fn(filter, next) { compose(filter, next) })
        // case filters_result {
        //   Ok(filters) ->
        //     compose(filters, fn(ctx) { route.function(ctx) })(context)
        //   Error(_) -> route.function(new_context)
        // }
        add_filters_to_response(route.filters, route.function)(context)
      }
      // case filter.combine(Context(url, request), route.filters) {
      //   Continue(new_context) -> route.function(new_context)
      //   Stop(stop_response) -> stop_response
      // }
      NonRoutableRequest -> not_found()
    }
  }

  case get_middleware(pid) {
    Some(middleware) -> middleware(service)(req)
    //middleware(service(req))
    None -> service(req)
  }
  // service(req)
}

fn add_filters_to_response(
  filters: List(fn(Filter) -> Filter),
  fun: fn(Context) -> Response(BitBuilder),
) -> fn(Context) -> Response(BitBuilder) {
  case list.length(filters) {
    0 -> fun
    _ ->
      case list.reduce(
        list.reverse(filters),
        fn(filter, next) { compose(filter, next) },
      ) {
        Ok(fillters_compose) -> fillters_compose(fun)
        Error(_) -> fun
      }
  }
}

// pub fn map_get(pid, url: String, func: fn(Request) -> Response) {
//   process_map(pid, url, func, http.Get, [])
// }
// pub fn map_post(pid, url: String, func: fn(Request) -> Response) {
//   process_map(pid, url, func, http.Post, [])
// }
// pub fn map_delete(pid, url: String, func: fn(Request) -> Response) {
//   process_map(pid, url, func, http.Delete, [])
// }
fn process_map(
  pid,
  url: String,
  func: fn(Context) -> Response(BitBuilder),
  method: Method,
  filters: List(fn(Filter) -> Filter),
) {
  process.call(pid, AddRoute(Route(method, url, func, filters), _), 100)
  pid
}

/// Prints out the registered routes for debugging
/// This will be better formatted when the server is ready for production
pub fn get_routes(pid) {
  let response = process.call(pid, GetRoutes, 100)
  io.println(response)
  pid
}

// registered. This may not be needed in future
/// registers additional routes after the inital routes have been
pub fn register_routes(pid, route: router.Route) {
  register_routes_with_root(pid, route, "", [])
  pid
}

/// registers middleware for the server
///
/// ## Example
///
/// ```gleam
/// case server.start(routes) {
///    Ok(pid) -> {
///      pid
///      |> server.add_middleware(fn(middleware) {
///        middleware
///        |> service.prepend_response_header("made-by", "howdy")
///        |> service.prepend_response_header("with-love", "howdy team")
///      })
///      |> server.get_routes()
///      erlang.sleep_forever()
///    }
///    Error(_) -> io.println("Server failed to start")
///  }
///}
pub fn add_middleware(
  pid,
  middleware: fn(Service(BitString, BitBuilder)) ->
    Service(BitString, BitBuilder),
) {
  process.call(pid, RegisterMiddleware(middleware, _), 100)
  pid
}

fn register_routes_with_root(
  pid,
  routes: router.Route,
  root: String,
  filters: List(fn(Filter) -> Filter),
) {
  case routes {
    router.Get(route, func) -> {
      process_map(pid, join_urls(root, route), func, http.Get, filters)
      Nil
    }
    router.Post(route, func) -> {
      process_map(pid, join_urls(root, route), func, http.Post, filters)
      Nil
    }
    router.Delete(route, func) -> {
      process_map(pid, join_urls(root, route), func, http.Delete, filters)
      Nil
    }
    router.Put(route, func) -> {
      process_map(pid, join_urls(root, route), func, http.Put, filters)
      Nil
    }
    router.Patch(route, func) -> {
      process_map(pid, join_urls(root, route), func, http.Patch, filters)
      Nil
    }
    router.Custom(method, route, func) -> {
      process_map(
        pid,
        join_urls(root, route),
        func,
        http.Other(method),
        filters,
      )
      Nil
    }

    router.RouterMap(route_path, route_list) ->
      //   let new_url = io.println("registering route ")
      route_list
      |> list.each(fn(route) {
        register_routes_with_root(
          pid,
          route,
          join_urls(root, route_path),
          filters,
        )
      })
    router.RouterMapWithFilters(route_path, route_list, filter_list) ->
      route_list
      |> list.each(fn(route) {
        register_routes_with_root(
          pid,
          route,
          join_urls(root, route_path),
          list.append(filters, filter_list),
        )
      })
    router.Static(route_path, file_path) -> {
      let full_route = case string.ends_with(route_path, "/*") {
        True -> join_urls(root, route_path)
        False -> join_urls(root, join_urls(route_path, "/*"))
      }
      process_map(
        pid,
        full_route,
        static_resource.get_file_contents(file_path),
        http.Get,
        filters,
      )
      Nil
    }
    router.Spa(route_path, spa_file_path) -> {
      let full_route = case string.ends_with(route_path, "/*") {
        True -> join_urls(root, route_path)
        False -> join_urls(root, join_urls(route_path, "/*"))
      }
      process_map(
        pid,
        full_route,
        static_resource.get_spa_file_contents(spa_file_path),
        http.Get,
        filters,
      )
      Nil
    }
  }
  // check if wildcard is on the end and add it if not
  // create a get route with function from static_resource
}

fn join_urls(lhs: String, rhs: String) {
  case string.ends_with(lhs, "/"), string.starts_with(rhs, "/") {
    True, True -> string.append(lhs, string.drop_left(rhs, 1))
    True, False -> string.append(lhs, rhs)
    False, True -> string.append(lhs, rhs)
    False, False ->
      lhs
      |> string.append("/")
      |> string.append(rhs)
  }
}

fn match_route(pid, path, method) -> RequestType {
  process.call(pid, MatchRoute(path, method, _), 100)
}

fn get_middleware(
  pid,
) -> Option(
  fn(Service(BitString, BitBuilder)) -> Service(BitString, BitBuilder),
) {
  process.call(pid, GetMiddleware, 100)
}

fn handle_message(msg: Message, state: State) {
  // io.println("The actor got a message")
  case msg {
    AddRoute(route, reply_channel) -> {
      process.send(reply_channel, "Adding route")
      let new_state = State(..state, routes: list.append(state.routes, [route]))
      actor.Continue(new_state)
    }
    GetRoutes(reply_channel) -> {
      print_route(state.routes)
      process.send(reply_channel, "Getting routes")
      actor.Continue(state)
    }
    MatchRoute(path, method, reply_channel) -> {
      let result = find_route(state.routes, path, method)
      process.send(reply_channel, result)
      actor.Continue(state)
    }
    RegisterMiddleware(middleware, reply_channel) -> {
      let new_state = State(..state, middleware: Some(middleware))
      process.send(reply_channel, True)
      actor.Continue(new_state)
    }
    GetMiddleware(reply_channel) -> {
      process.send(reply_channel, state.middleware)
      actor.Continue(state)
    }
  }
}

fn print_route(routes: List(Route)) {
  case routes {
    [] -> io.println("No more routes")
    [head, ..tail] -> {
      io.println(head.url)
      print_route(tail)
    }
  }
}

fn find_route(routes: List(Route), path: String, method: Method) -> RequestType {
  routes
  //|> list.reverse
  |> list.fold_until(
    NonRoutableRequest,
    fn(acc, route) {
      let url = url_parser.parse(route.url, path)
      case url, route.method == method {
        Ok(segments), True -> list.Stop(SuccessfulRequest(route, segments))
        _, _ -> list.Continue(acc)
      }
    },
  )
}

/// Messages that are sent the OTP
pub opaque type Message {
  AddRoute(route: Route, reply_channel: Sender(String))
  GetRoutes(reply_channel: Sender(String))
  MatchRoute(path: String, method: Method, reply_channel: Sender(RequestType))
  RegisterMiddleware(
    middleware: fn(Service(BitString, BitBuilder)) ->
      Service(BitString, BitBuilder),
    reply_channel: Sender(Bool),
  )
  GetMiddleware(
    reply_channel: Sender(
      Option(
        fn(Service(BitString, BitBuilder)) -> Service(BitString, BitBuilder),
      ),
    ),
  )
}

type State {
  State(
    routes: List(Route),
    middleware: Option(
      fn(Service(BitString, BitBuilder)) -> Service(BitString, BitBuilder),
    ),
  )
}

/// Compiled route stored within the state
pub opaque type Route {
  Route(
    method: Method,
    url: String,
    function: fn(Context) -> Response(BitBuilder),
    filters: List(fn(Filter) -> Filter),
  )
}

/// Returned to the server if the route has a matching template
pub opaque type RequestType {
  NonRoutableRequest
  //InternalErrorRequest(error: String)
  SuccessfulRequest(route: Route, url: List(UrlSegment))
}
