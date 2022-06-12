import gleam/erlang
import howdy/server
import howdy/router.{Get, RouterMap}
import howdy/response

pub fn main() {
  let routes =
    RouterMap(
      "/",
      routes: [
        Get("/", fn(_) { response.of_string("hello from root") }),
        Get("/helloworld", fn(_) { response.of_string("hello, world!") }),
      ],
    )

  let _ = server.start_with_port(3007, routes)
  erlang.sleep_forever()
}
