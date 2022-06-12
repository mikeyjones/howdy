# Server

## Start
There are 3 options to starting your server:

Start a server on the default port of 3000
```gleam
pub fn main() {
  assert Ok(_) = server.start(routes)
  erlang.sleep_forever()
}
```

Start a server on the default port of 3000 with configuration:
```gleam
pub type Config {
 Config(connection_string: String)
}

pub fn main() {
  assert Ok(_) = server.start_with_config(routes, config: Config("my_database"))
  erlang.sleep_forever()
}
```

Start a server on the a diferent port and with configuration:
```gleam
pub fn main() {
  assert Ok(_) = server.start_with_port(routes, port: 8080, config: Nil)
  erlang.sleep_forever()
}
```
***Note:** If you do not want to set the config, it's perfectly fine to send Nil in and the config will not be set to anything* 

## Register routes
Howdy requires you to set at least 1 route on start up. Whats the point of a webserver with no routes registered? But can can register more routes after the server has started. To od this can do the following:

```gleam
import gleam/erlang
import howdy/server
import howdy/router.{Get}
import howdy/response

pub fn main() {
     case server.start(Get("/", fn(_) { response.of_string("Hello, World!") })) {
        Ok(pid) -> {
            server.register_routes(Get("/hi", 
                fn(_) { response.of_string("hi, world!")}))
            erlang.sleep_forever()
        }
        Error(_) -> Nil
     }
}
```

## Middleware
You can register middleware that is using the standardized gleam/http/server functions. To do this you can do the following:

```gleam
case server.start(routes) {
    Ok(pid) -> {
      pid
      |> server.add_middleware(fn(middleware) {
        middleware
            |> service.prepend_response_header("made-by", "howdy")
            |> service.prepend_response_header("with-love", "howdy team")
      })
      erlang.sleep_forever()
    }
    Error(_) -> io.println("Server failed to start")
}
```

***Note:** you can only register middleware once, calling `register_middleware` again will overwrite any middle where set previously.*

There are two main diferences between middleware and filters. Middleware only has access to the request and not the full context, unlike filters. The other differnece is that middleware is applied to all endpoints in Howdy. Middleware are also processed for routes that are not added to the router, this makes middleware great for things like CORS.