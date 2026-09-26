//// Schemas describe a JSON value once and give you everything built from
//// that description: the decoder a handler reads it with, the encoder a
//// response writes it with, and the JSON Schema the OpenAPI document shows.
//// Because all three come from one definition, the document cannot drift
//// from what the server really accepts and sends.
////
//// ```gleam
//// import howdy/openapi/schema.{type Schema}
////
//// pub fn user() -> Schema(User) {
////   {
////     use id <- schema.field("id", schema.int(), fn(user: User) { user.id })
////     use name <- schema.field(
////       "name",
////       schema.string() |> schema.max_length(50),
////       fn(user: User) { user.name },
////     )
////     schema.success(User(id:, name:))
////   }
////   |> schema.named("User")
//// }
//// ```
////
//// Objects are built like `gleam/dynamic/decode` decoders, with one extra
//// argument per field: a function reading the field back out of the value,
//// which is what lets the same schema encode.
////
//// To document an object, the fields after each one are found by calling
//// the rest of the chain with a placeholder value, such as `""` or `0`. So
//// keep the chain to `field` calls and a final `success`: code that
//// branches on a field's value only has its placeholder branch documented.
////
//// Constraints such as `max_length` are checked while decoding, and shown
//// in the document as the matching JSON Schema keyword. `rule` runs any
//// `howdy/validate` rule too, but the document cannot show what it checks.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import howdy/validate

/// A JSON value's description, decoder and encoder, for values of type `a`.
pub opaque type Schema(a) {
  Schema(
    node: fn() -> Node,
    decoder: Decoder(a),
    encode: fn(a) -> Json,
    placeholder: fn() -> a,
    text: Text,
    members: fn() -> List(fn(a) -> List(#(String, Json))),
  )
}

/// The JSON Schema of a schema, without its types. What `howdy/openapi`
/// renders into the document.
///
/// A named node is shown as a reference to its component, with `outer`
/// keywords, those added after naming, beside the reference.
pub opaque type Node {
  Node(
    keywords: List(#(String, Json)),
    items: Option(Node),
    values: Option(Node),
    properties: List(#(String, Node)),
    required: List(String),
    any_of: List(Node),
    name: Option(String),
    outer: List(#(String, Json)),
  )
}

/// How a schema reads a value from text, for path, query and header
/// parameters. The text becomes the `Dynamic` the decoder expects.
type Text {
  Single(fn(String) -> Dynamic)
  Repeated(fn(String) -> Dynamic)
}

// -- Primitives --------------------------------------------------------------

pub fn string() -> Schema(String) {
  primitive("string", decode.string, json.string, "", dynamic.string)
}

pub fn int() -> Schema(Int) {
  primitive("integer", decode.int, json.int, 0, fn(text) {
    case int.parse(text) {
      Ok(value) -> dynamic.int(value)
      Error(Nil) -> dynamic.string(text)
    }
  })
}

/// A JSON number. Integers such as `5` are accepted too.
pub fn float() -> Schema(Float) {
  let decoder =
    decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
  primitive("number", decoder, json.float, 0.0, fn(text) {
    case float.parse(text), int.parse(text) {
      Ok(value), _ -> dynamic.float(value)
      _, Ok(value) -> dynamic.float(int.to_float(value))
      _, _ -> dynamic.string(text)
    }
  })
}

/// `true` or `false`. As a parameter, only the text `true` or `false`.
pub fn bool() -> Schema(Bool) {
  primitive("boolean", decode.bool, json.bool, False, fn(text) {
    case text {
      "true" -> dynamic.bool(True)
      "false" -> dynamic.bool(False)
      _ -> dynamic.string(text)
    }
  })
}

fn primitive(
  kind: String,
  decoder: Decoder(a),
  encode: fn(a) -> Json,
  placeholder: a,
  from_text: fn(String) -> Dynamic,
) -> Schema(a) {
  Schema(
    node: fn() { leaf([#("type", json.string(kind))]) },
    decoder:,
    encode:,
    placeholder: fn() { placeholder },
    text: Single(from_text),
    members: fn() { [] },
  )
}

// -- Collections -------------------------------------------------------------

/// A JSON array. As a query parameter, every occurrence of the key, as in
/// `?tag=a&tag=b`.
pub fn list(of inner: Schema(a)) -> Schema(List(a)) {
  Schema(
    node: fn() {
      Node(..leaf([#("type", json.string("array"))]), items: Some(inner.node()))
    },
    decoder: decode.list(inner.decoder),
    encode: fn(values) { json.array(values, inner.encode) },
    placeholder: fn() { [] },
    text: Repeated(text_reader(inner.text)),
    members: fn() { [] },
  )
}

/// A JSON object used as a map from string keys to values of one schema.
pub fn dict(of inner: Schema(a)) -> Schema(Dict(String, a)) {
  Schema(
    node: fn() {
      Node(
        ..leaf([#("type", json.string("object"))]),
        values: Some(inner.node()),
      )
    },
    decoder: decode.dict(decode.string, inner.decoder),
    encode: fn(values) { json.dict(values, fn(key) { key }, inner.encode) },
    placeholder: fn() { dict.new() },
    text: Single(dynamic.string),
    members: fn() { [] },
  )
}

/// A value that may be `null`. For a field that may be left out, use
/// `optional_field` instead.
pub fn nullable(inner: Schema(a)) -> Schema(Option(a)) {
  Schema(
    node: fn() {
      Node(..leaf([]), any_of: [
        inner.node(),
        leaf([#("type", json.string("null"))]),
      ])
    },
    decoder: decode.optional(inner.decoder),
    encode: fn(value) { json.nullable(value, inner.encode) },
    placeholder: fn() { None },
    text: inner.text,
    members: fn() { [] },
  )
}

/// A string that must be one of the given names, each standing for a value.
/// Encoding looks the value up to find its name. Panics if `variants` is
/// empty.
///
/// ```gleam
/// schema.enum([#("admin", Admin), #("member", Member)])
/// ```
pub fn enum(variants: List(#(String, a))) -> Schema(a) {
  let assert [#(_, first), ..] = variants
    as "howdy/openapi/schema: enum needs at least one variant"
  let names = list.map(variants, fn(variant) { variant.0 })
  let message = "must be one of " <> string.join(names, ", ")
  Schema(
    node: fn() {
      leaf([
        #("type", json.string("string")),
        #("enum", json.array(names, json.string)),
      ])
    },
    decoder: decode.then(decode.string, fn(name) {
      case list.key_find(variants, name) {
        Ok(value) -> decode.success(value)
        Error(Nil) -> decode.failure(first, message)
      }
    }),
    encode: fn(value) {
      case list.find(variants, fn(variant) { variant.1 == value }) {
        Ok(#(name, _)) -> json.string(name)
        Error(Nil) -> json.null()
      }
    },
    placeholder: fn() { first },
    text: Single(dynamic.string),
    members: fn() { [] },
  )
}

// -- Objects -----------------------------------------------------------------

/// A required object field. `get` reads the field from the finished value,
/// for encoding. See the module docs for how chains are built.
pub fn field(
  name: String,
  schema: Schema(a),
  get: fn(r) -> a,
  next: fn(a) -> Schema(r),
) -> Schema(r) {
  let rest = fn() { next(schema.placeholder()) }
  let member = fn(value) { [#(name, schema.encode(get(value)))] }
  object_step(
    rest:,
    property: #(name, schema),
    required: True,
    member:,
    decoder: decode.field(name, schema.decoder, fn(value) {
      next(value).decoder
    }),
  )
}

/// An object field that may be missing or `null`, both of which decode to
/// `None`. `None` is left out when encoding.
pub fn optional_field(
  name: String,
  schema: Schema(a),
  get: fn(r) -> Option(a),
  next: fn(Option(a)) -> Schema(r),
) -> Schema(r) {
  let rest = fn() { next(None) }
  let member = fn(value) {
    case get(value) {
      Some(inner) -> [#(name, schema.encode(inner))]
      None -> []
    }
  }
  object_step(
    rest:,
    property: #(name, schema),
    required: False,
    member:,
    decoder: decode.optional_field(
      name,
      None,
      decode.optional(schema.decoder),
      fn(value) { next(value).decoder },
    ),
  )
}

fn object_step(
  rest rest: fn() -> Schema(r),
  property property: #(String, Schema(a)),
  required required: Bool,
  member member: fn(r) -> List(#(String, Json)),
  decoder decoder: Decoder(r),
) -> Schema(r) {
  let #(name, schema) = property
  let members = fn() { [member, ..rest().members()] }
  Schema(
    node: fn() {
      let object = unnamed(rest().node())
      Node(
        ..object,
        properties: [#(name, schema.node()), ..object.properties],
        required: case required {
          True -> [name, ..object.required]
          False -> object.required
        },
      )
    },
    decoder:,
    encode: fn(value) { encode_object(members(), value) },
    placeholder: fn() { rest().placeholder() },
    text: Single(dynamic.string),
    members:,
  )
}

/// Finish an object with the value built from its fields.
pub fn success(value: r) -> Schema(r) {
  Schema(
    node: fn() { leaf([#("type", json.string("object"))]) },
    decoder: decode.success(value),
    encode: fn(_) { json.object([]) },
    placeholder: fn() { value },
    text: Single(dynamic.string),
    members: fn() { [] },
  )
}

fn encode_object(
  members: List(fn(r) -> List(#(String, Json))),
  value: r,
) -> Json {
  json.object(list.flat_map(members, fn(member) { member(value) }))
}

// -- Changing types ----------------------------------------------------------

/// Change the type a schema decodes to and encodes from. Both directions
/// must always succeed; see `try_map` for conversions that can fail.
///
/// ```gleam
/// pub fn user_id() -> Schema(UserId) {
///   schema.int() |> schema.map(to: UserId, from: fn(id) { id.value })
/// }
/// ```
pub fn map(
  schema: Schema(a),
  to to: fn(a) -> b,
  from from: fn(b) -> a,
) -> Schema(b) {
  Schema(
    node: schema.node,
    decoder: decode.map(schema.decoder, to),
    encode: fn(value) { schema.encode(from(value)) },
    placeholder: fn() { to(schema.placeholder()) },
    text: schema.text,
    members: fn() {
      list.map(schema.members(), fn(member) {
        fn(value) { member(from(value)) }
      })
    },
  )
}

/// Like `map`, but decoding can fail with a message such as
/// `"must be a date"`. `placeholder` stands in for the value when the
/// document is built and when decoding fails.
pub fn try_map(
  schema: Schema(a),
  to to: fn(a) -> Result(b, String),
  from from: fn(b) -> a,
  placeholder placeholder: b,
) -> Schema(b) {
  Schema(
    node: schema.node,
    decoder: decode.then(schema.decoder, fn(value) {
      case to(value) {
        Ok(value) -> decode.success(value)
        Error(message) -> decode.failure(placeholder, message)
      }
    }),
    encode: fn(value) { schema.encode(from(value)) },
    placeholder: fn() { placeholder },
    text: schema.text,
    members: fn() {
      list.map(schema.members(), fn(member) {
        fn(value) { member(from(value)) }
      })
    },
  )
}

// -- Constraints -------------------------------------------------------------

pub fn min_length(schema: Schema(String), length: Int) -> Schema(String) {
  constrain(
    schema,
    [#("minLength", json.int(length))],
    validate.min_length(length),
  )
}

pub fn max_length(schema: Schema(String), length: Int) -> Schema(String) {
  constrain(
    schema,
    [#("maxLength", json.int(length))],
    validate.max_length(length),
  )
}

/// At least one character. Shown as `minLength: 1`, with the message
/// `"must not be empty"`.
pub fn not_empty(schema: Schema(String)) -> Schema(String) {
  constrain(schema, [#("minLength", json.int(1))], validate.not_empty())
}

/// The light email check from `howdy/validate`, shown as `format: email`.
pub fn email(schema: Schema(String)) -> Schema(String) {
  constrain(schema, [#("format", json.string("email"))], validate.email())
}

pub fn minimum(schema: Schema(Int), value: Int) -> Schema(Int) {
  constrain(schema, [#("minimum", json.int(value))], validate.min(value))
}

pub fn maximum(schema: Schema(Int), value: Int) -> Schema(Int) {
  constrain(schema, [#("maximum", json.int(value))], validate.max(value))
}

/// Run a `howdy/validate` rule while decoding. Rules may change the value,
/// as `validate.trim()` does, and a failing rule reports its message for
/// the field. The document does not show what a rule checks; add a
/// `description` if clients need to know.
pub fn rule(schema: Schema(a), rule: validate.Rule(a)) -> Schema(a) {
  constrain(schema, [], rule)
}

fn constrain(
  schema: Schema(a),
  keywords: List(#(String, Json)),
  rule: validate.Rule(a),
) -> Schema(a) {
  Schema(
    ..schema,
    node: fn() { add_keywords(schema.node(), keywords) },
    decoder: decode.then(schema.decoder, fn(value) {
      case rule(value) {
        Ok(value) -> decode.success(value)
        Error(message) -> decode.failure(value, message)
      }
    }),
  )
}

// -- Documentation -----------------------------------------------------------

/// Show the schema once, under `components/schemas/<name>`, and refer to it
/// by name everywhere it is used. Two different schemas with the same name
/// make building the document panic.
pub fn named(schema: Schema(a), name: String) -> Schema(a) {
  Schema(..schema, node: fn() {
    Node(..unnamed(schema.node()), name: Some(name), outer: [])
  })
}

pub fn description(schema: Schema(a), text: String) -> Schema(a) {
  document(schema, "description", json.string(text))
}

/// An example value, encoded with the schema itself.
pub fn example(schema: Schema(a), value: a) -> Schema(a) {
  document(schema, "examples", json.preprocessed_array([schema.encode(value)]))
}

/// A format hint such as `"date-time"` or `"uuid"`. Only documents the
/// value; pair it with `try_map` or `rule` to check it.
pub fn format(schema: Schema(a), name: String) -> Schema(a) {
  document(schema, "format", json.string(name))
}

pub fn deprecated(schema: Schema(a)) -> Schema(a) {
  document(schema, "deprecated", json.bool(True))
}

fn document(schema: Schema(a), key: String, value: Json) -> Schema(a) {
  Schema(..schema, node: fn() { add_keywords(schema.node(), [#(key, value)]) })
}

// -- Using a schema ----------------------------------------------------------

/// Encode a value, for a response body. Pass it to `service.respond` as
/// `schema.to_json(_, user())`.
pub fn to_json(value: a, schema: Schema(a)) -> Json {
  schema.encode(value)
}

/// The decoder for a schema, for reading JSON outside a handler.
pub fn decoder(schema: Schema(a)) -> Decoder(a) {
  schema.decoder
}

/// The JSON Schema of a schema, for `howdy/openapi`.
@internal
pub fn node(schema: Schema(a)) -> Node {
  schema.node()
}

/// A placeholder value, for documenting an endpoint's later inputs.
@internal
pub fn placeholder(schema: Schema(a)) -> a {
  schema.placeholder()
}

/// Decode parameter text. Every occurrence of a key is given; a schema that
/// is not a `list` fails unless there is exactly one.
@internal
pub fn from_text(
  schema: Schema(a),
  values: List(String),
) -> Result(a, List(decode.DecodeError)) {
  let data = case schema.text {
    Repeated(read) -> dynamic.list(list.map(values, read))
    Single(read) ->
      case values {
        [value] -> read(value)
        _ -> dynamic.list(list.map(values, dynamic.string))
      }
  }
  decode.run(data, schema.decoder)
}

/// Whether a schema describes a JSON object.
@internal
pub fn is_object(schema: Schema(a)) -> Bool {
  case list.key_find(schema.node().keywords, "type") {
    Ok(kind) -> json.to_string(kind) == "\"object\""
    Error(Nil) -> False
  }
}

/// Whether a parameter schema takes every occurrence of its key.
@internal
pub fn is_repeated(schema: Schema(a)) -> Bool {
  case schema.text {
    Repeated(_) -> True
    Single(_) -> False
  }
}

fn text_reader(text: Text) -> fn(String) -> Dynamic {
  case text {
    Single(read) | Repeated(read) -> read
  }
}

// -- Rendering ---------------------------------------------------------------

/// Named schemas seen while rendering, as their JSON and its text, so a
/// second, different schema with the same name can be caught.
pub opaque type Components {
  Components(schemas: Dict(String, #(Json, String)), order: List(String))
}

@internal
pub fn components() -> Components {
  Components(schemas: dict.new(), order: [])
}

/// The named schemas in the order they were first used.
@internal
pub fn component_list(components: Components) -> List(#(String, Json)) {
  list.reverse(components.order)
  |> list.filter_map(fn(name) {
    dict.get(components.schemas, name)
    |> result.map(fn(entry) { #(name, entry.0) })
  })
}

/// Render a node as JSON Schema, collecting named schemas as components.
@internal
pub fn render(node: Node, components: Components) -> #(Json, Components) {
  case node.name {
    Some(name) -> {
      let #(body, components) = render(unnamed(node), components)
      let text = json.to_string(body)
      let components = case dict.get(components.schemas, name) {
        Ok(#(_, existing)) if existing == text -> components
        Ok(_) ->
          panic as { "howdy/openapi: two different schemas are named " <> name }
        Error(Nil) ->
          Components(
            schemas: dict.insert(components.schemas, name, #(body, text)),
            order: [name, ..components.order],
          )
      }
      let reference = #("$ref", json.string("#/components/schemas/" <> name))
      #(json.object([reference, ..node.outer]), components)
    }
    None -> {
      let Node(keywords:, items:, values:, properties:, required:, any_of:, ..) =
        node
      let #(items, components) = render_option("items", items, components)
      let #(values, components) =
        render_option("additionalProperties", values, components)
      let #(properties, components) = case properties {
        [] -> #([], components)
        _ -> {
          let #(rendered, components) =
            list.fold(properties, #([], components), fn(acc, property) {
              let #(rendered, components) = acc
              let #(json, components) = render(property.1, components)
              #([#(property.0, json), ..rendered], components)
            })
          #([#("properties", json.object(list.reverse(rendered)))], components)
        }
      }
      let required = case required {
        [] -> []
        _ -> [#("required", json.array(required, json.string))]
      }
      let #(any_of, components) = case any_of {
        [] -> #([], components)
        _ -> {
          let #(rendered, components) =
            list.fold(any_of, #([], components), fn(acc, node) {
              let #(rendered, components) = acc
              let #(json, components) = render(node, components)
              #([json, ..rendered], components)
            })
          #(
            [#("anyOf", json.preprocessed_array(list.reverse(rendered)))],
            components,
          )
        }
      }
      #(
        json.object(
          list.flatten([keywords, items, values, properties, required, any_of]),
        ),
        components,
      )
    }
  }
}

fn render_option(
  key: String,
  node: Option(Node),
  components: Components,
) -> #(List(#(String, Json)), Components) {
  case node {
    Some(node) -> {
      let #(json, components) = render(node, components)
      #([#(key, json)], components)
    }
    None -> #([], components)
  }
}

fn leaf(keywords: List(#(String, Json))) -> Node {
  Node(
    keywords:,
    items: None,
    values: None,
    properties: [],
    required: [],
    any_of: [],
    name: None,
    outer: [],
  )
}

/// A named node's own schema: its keywords, with those added after naming
/// kept beside the reference instead.
fn unnamed(node: Node) -> Node {
  Node(..node, name: None, outer: [])
}

fn add_keywords(node: Node, keywords: List(#(String, Json))) -> Node {
  case node.name {
    Some(_) -> Node(..node, outer: list.append(node.outer, keywords))
    None -> Node(..node, keywords: list.append(node.keywords, keywords))
  }
}
