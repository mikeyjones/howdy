# Context

The context is an important part of Howdy, and is used to pass information to the routes and filters. 

The context consists of 4 items:

* Url
* Request
* User
* Config

There are helper methods to make it easier to access parts of the context, so you do not need to always work on the internals.

## Url
Contains a list of the Url segments. Howdy uses this when it's trying to match the route coming from the request with the routes it in the router.

Dynamic routes are processed and stored here. Howdy provides helper methods to access the values in the dynamic url segements.

You can access the dynamic routes data with the following:

```gleam
import howdy/context/url
```

| Type | Example | Url|
|------|---------|----|
| String | ```Get("/{Value:String}", fn(ctx) {  url.get_string(ctx, "Value") })```| /hello
| Int | ```Get("/{Value:Int}", fn(ctx) { url.get_int(ctx, "Value") })```| /123
| Float | ```Get("/{Value:Float}", fn(ctx) { url.get_float(ctx, "Value") })```| /123.1
| Uuid | ```Get("/{Value:Uuid}", fn(ctx) { url.get_uuid(ctx, "Value") })```| /9e5d67bc-722e-4d8a-8425-0c0019f9e53c


## Body
Howdy gives you helper methos to get the body of the request, this allows you to quickly access the body if it is a common type. Currently, Howdy only supports JSON and web forms (*please note it cannot cope with mulitpart forms yet*).

You can access the body helper methods like so:

**Json**
```gleam
import gleam/dynamic
import howdy/context/body
import howdy/response

fn(context) {
    case body.get_json(
        context, 
        dynamic.decode3(
            Todo,
            dynamic.field("id", of: dynamic.int),
            dynamic.field("task", of: dynamic.string),
            dynamic.field("is_completed", of: dynamic.bool),
        )) {
        Ok(todo_item) -> response.of_string("I have a Json Todo Item.")
        Error(_) -> response.of_interal_error("Todo item is on correct format!")
```

**Web form post**
```gleam
import howdy/context/body

fn(context) {
    let form_feilds = case body.get_form(context){
        Ok(form) -> form
        Error(_) -> []
    }
}
```
Form feilds are stored in a list of key/value tuples `List(#(String, String))`.

## Header 
You can retrive head vaules by their key, with the following:

```gleam
import howdy/context/header

fn(context) {
    case header.get_value("content-type") {
        Ok(ct) -> response.of_string(ct)
        Error(_) -> response.of_internal_error("Header 'content-type' missing")
    }
}
```

## Querystring
If you need to access values in the querystring, you can do so with the following:

```gleam
import howdy/context/querystring
import howdy/response
import gleam/list
import gleam/result

fn(context) {
    case querystring.get_value(context, "search")
    {
        Ok(value_list) -> response.of_string(result.unwrap(list.first(value_list),""))
        Error(_) -> response.of_internal_error("querystring 'search' missing.") 
    }
}
```

## User
This is used for authentication, and should be filled in once the server has authenticated the user/service.

You can check if the user is authenticated, with the following:

```gleam
import howdy/context
import howdy/response

fn(ctx) {
    case context.is_authenticated(ctx) {
        True -> response.of_string("Is authenticated")
        False -> response.of_string("Is not authenticated")
    }
}
```

You can also get the claims of the user, with the following:

```gleam
import howdy/response

fn(context) {
    case context.user {
        Some(user) {
            let claims = user.claims
            response.of_string("User has claims")
        }
        None -> response.of_string("User has no claims") 
    }

}
```

You can get claims from the user with the `get_claim` helper function, this will return `Result(String,Nil)` and expects an `Option(User)` as input:

```gleam
import gleam/result
import howdy/response
import howdy/context/user

fn(context) {
    context.user 
    |> user.get_claim("email") 
    |> result.unwrap("No email found")
    |> response.of_string()
}
```
## Config
When the server starts up you can send in any `Type` which will be then available to all the routes. You can do the following:

```gleam

pub type Config {
  Config(connection_string: String)
}

fn hello_connetion(context: Context(Config)) {
  response.of_string(context.config.connection_string)
}

let routes =
    RouterMap(
      "/",
      routes: [Get("/", hello_connection)])

pub fn main() {
     assert Ok(_) = server.start_with_port(3030, routes, Config("connection to database"))
  erlang.sleep_forever()
}
```

***NOTE:** Please don't expose your connection string to the database like this, it's just an example.*