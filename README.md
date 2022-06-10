# howdy

[![Package Version](https://img.shields.io/hexpm/v/howdy)](https://hex.pm/packages/howdy)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/howdy/)

A simple but powerful webserver build on top of Cowboy. Howdy's goal is to make create web servers using Gleam as easy as it can be.

## Installation

If available on Hex this package can be added to your Gleam project:

```sh
gleam add howdy
```

and its documentation can be found at <https://hexdocs.pm/howdy>.

## Quick Start

```gleam
import gleam/erlang
import howdy/server
import howdy/router.{Get}
import howdy/response

pub fn main() {
    let _ = server.start(Get("/", fn(_) { response.of_string("Hello, World!") }))
    erlang.sleep_forever()
}
```

See router documentation for more details [here](https://github.com/mikeyjones/howdy/blob/main/manual/routes.md)