# Howdy Router

If you have seen the quick start, you will see that you can easily add a single route to the server as it starts up. It would be a rubbish router if you could only and a single route to the server, so lets see how we can add multiple routes.

## Map
You can group multiple routes together using `RouterMap`, like so:

```gleam
import gleam/erlang
import howdy/server
import howdy/router.{RouterMap, Get}
import howdy/response

pub fn main() {
    let routes = RouterMap("/", routes: [
        Get("/", fn(_) { response.of_string("hello from root") }),
        Get("/helloworld", fn(_) { response.of_string("hello, world!")}),
    ])

    let _ = server.start(routes)
    erlang.sleep_forever()
}
```

Isn't that self explanatory? It's pretty simple to see what routes the server supports, right? But wait there is more, you can nest `RouterMaps`

## Nested Maps

```gleam
import gleam/erlang
import howdy/server
import howdy/router.{RouterMap, Get, Post}
import howdy/response

pub fn main() {
    let routes = RouterMap("/", routes: [
        Get("/", fn(_) { response.of_string("hello from root") }),
        Get("/helloworld", fn(_) { response.of_string("hello, world!")}),
        RouterMap("/api", routes: [
            Get("/", fn(_) { response.of_string("hello from API")}),
            Post("/", fn(_) { response.of_string("you posted to the API.")})
        ])

    ])

    let _ = server.start(routes)
    erlang.sleep_forever()
}
```

All the routes within the api `RouterMap` will start with "/api". You can nest as many `RouterMaps` deep as you want.

## Verbs

Howdy support the following HTTP verbs:

| Verb | Example |
|------|---------|
| Get  | ```Get("/", fn(_) { response.of_string("Get")  })```
| Post  | ```Post("/", fn(_) { response.of_string("Post")  })```
| Put  | ```Put("/", fn(_) { response.of_string("Put")  })```
| Patch  | ```Patch("/", fn(_) { response.of_string("Patch")  })```
| Delete  | ```Delete("/", fn(_) { response.of_string("Delete")  })```
| Custom  | ```Custom("Goat","/", fn(_) { response.of_string("Goat")  })```


## Dynamic Routes

Creating static routes is all well and good, but any router worth its salt can cope with dynamic routes, so can Howdy, here's how how it does it:

```gleam
import gleam/erlang
import howdy/server
import howdy/router.{RouterMap, Get}
import howdy/context/url
import howdy/response
import gleam/result
import gleam/string

pub fn main() {
    let routes = RouterMap("/", routes: [
        Get("/hello", hello_name),
        Get("/hello/{Name:String}", hello_name),
    ])

    let _ = server.start(routes)
    erlang.sleep_forever()
}

fn hello_name(ctx) {
    let name = ctx
      |> url.get_string("Name")
      |> result.unwrap(", world!")

    string.concat(["hello ", name])
    |> response.of_string()
}
```

*Important to note, that the name is case sensative, so if you changed the ```url.get_string("name")``` then Howdy would not find it.* 

We support multiple primitive types:

| Type | Example | 
|------|---------|
| String | ```Get("/{Value:String}", fn(ctx) {  url.get_string(ctx, "Value") })```
| Int | ```Get("/{Value:Int}", fn(ctx) { url.get_int(ctx, "Value") })```
| Float | ```Get("/{Value:Float}", fn(ctx) { url.get_float(ctx, "Value") })```
| Uuid | ```Get("/{Value:Uuid}", fn(ctx) { url.get_uuid(ctx, "Value") })```

We plan on adding more as Howdy grows, so watch this space! All functions that return values will return a ```Result(type,Nil)``` if there is not match found you will get an ```Error(Nil)``` returned.


## Static resourses 
Howdy can serve static content as well. I know, right! who would have thought it, a web server, serving static content. The ability to do this is part of the router, and is simple to impliment:

```gleam
import gleam/erlang
import howdy/server
import howdy/router.{RouterMap, Get, Static}
import howdy/response

pub fn main() {
    let routes = RouterMap("/", routes: [
        Get("/", fn(_) { response.of_string("hello from root") }),
        Static("/static/images", "./images"),
        RouterMap("/spa", routes: [
            Static("/", "./spa")  
        ])
    ])

    let _ = server.start(routes)
    erlang.sleep_forever()
}
```

You can add `Static` routes within `RouterMap` and it will add build up the route just like the verbs.

Static routes are greedy, so if the file exists in within the directory on disk it will match it, for example ```./images/cats/cat1.png``` will be found for the route ```/static/images/cats/cat1.png```

## Greedy routes
Howdy will happly let you register as many routes as you want that will match the same URL, this is totally by design. Howdy works on a first come first servced basis (or fifo). This enables you to create some pretty complex routes simply:

```gleam
import gleam/erlang
import howdy/server
import howdy/router.{RouterMap, Get}
import howdy/response

pub fn main() {
    let routes = RouterMap("/", routes: [
        Get("/helloworld", fn(_) { response.of_string("hello, world!")}),
        Get("/{any:String}", fn(_) { response.of_string("hello, everything else!")}),
        Get("/hello/*", fn(_) { response.of_string("hello all other routes")}) //this is super greedy
    ])

    let _ = server.start(routes)
    erlang.sleep_forever()
}
```
The above would responsed as follows:

| Request             | Response |
|---------------------|----------|
|```/helloworld/```   | ```hello, world!``` |
|```/hello/```        | ```hello, everything else!``` |
|```/hello/world/```  | ```hello all other routes``` |

**Note:** the greedy operator "`*`" will only work at the end of the route, and it will be super greedy, it will match everything that comes after the "`*`" so ```hello/image.png``` would also return the text ```hello all other routes```.

## Filters

We can map filters with the `RouterMapWithFilters` router helper, this is like middleware, except it is just for a group of routes instead of all the routes. By the way, Howdy supports middleware as well, and uses the standard Gleam HTTP request and response to ensure it is compatable with any middleware created for Gleam.

You can use filters as follows:

```gleam
import gleam/erlang
import howdy/server
import howdy/router.{RouterMap, RouterMapWithFilters, Get, Post}
import howdy/response
import howdy/filter

pub fn main() {
    let routes = RouterMap("/", routes: [
        Get("/", fn(_) { response.of_string("hello from root") }),
        Get("/helloworld", fn(_) { response.of_string("hello, world!")}),
        RouterMapWithFilters("/api", 
            filters:[filter.accepts_json],
            routes: [
            Get("/", fn(_) { response.of_string("hello from API")}),
            Post("/", fn(_) { response.of_string("you posted to the API.")})
        ])

    ])

    let _ = server.start(routes)
    erlang.sleep_forever()
}
```

For the above example, all the "/api" routes will check the header for `Accept:application/json` and will return a 404 if this header is not present.

Filters are great for handling authentication and authoization, more on that later!

You can create filters as easily as middleware:

```gleam
import gleam/erlang
import howdy/server
import howdy/router.{RouterMap, RouterMapWithFilters, Get, Post}
import howdy/response
import howdy/filter.{Filter}

pub fn main() {
    let routes = RouterMap("/", routes: [
        Get("/", fn(_) { response.of_string("hello from root") }),
        Get("/helloworld", fn(_) { response.of_string("hello, world!")}),
        RouterMapWithFilters("/api", 
            filters:[append_custom_response_header(_, "api-version","v1.0")],
            routes: [
            Get("/", fn(_) { response.of_string("hello from API")}),
            Post("/", fn(_) { response.of_string("you posted to the API.")})
        ])

    ])

    let _ = server.start(routes)
    erlang.sleep_forever()
}

fn stop_all_requests_filter(_filter) {
    fn(_context) {
        response.of_internal_error("Boom!) // status 500
    }
}

fn append_custom_response_header(filter: Filter(a),key: String, value: String)
 -> Filter(a) {
  fn(context) {
    context
    |> filter
    |> response.with_header(key, value)
  }
}

```

The above would add the header `api-version` to all routes in the `/api` group, if you add `stop_all_request_filter` to the filters list, it would return Http status 500 on all the routes in `/api` and not call the routed function.

