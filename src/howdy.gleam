import gleam/erlang
import howdy/server
import howdy/router.{Get, RouterMap}
import howdy/response

pub fn main() {
  let routes =
    RouterMap(
      "/",
      routes: [
        Get("/", fn(_) { response.of_string("hello 1") }),
        Get("/", fn(_) { response.of_string("hello 2") }),
      ],
    )

  let _ = server.start(routes)
  erlang.sleep_forever()
}
