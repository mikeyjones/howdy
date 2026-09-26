//// Keep mail instead of sending it, for development and tests. The admin
//// area (`admin.mail`) shows what an outbox holds, and tests can read the
//// last message to an address.
////
//// ```gleam
//// // dev/my_app_dev.gleam
//// let assert Ok(box) = outbox.start_in("tmp/mail")
//// let mailer = mail.mailer(outbox.adapter(box))
//// ```
////
//// Start the outbox once, outside the function `howdy/dev` rebuilds the
//// app from, so it survives reloads. With `start_in`, each message is also
//// written to the directory as an `.eml` file any mail client can open, and
//// a `.json` file the outbox reads back after a restart. Add the directory
//// to `.gitignore`: it holds sign-in tokens and whatever else was sent.
////
//// Only the newest 500 messages are kept; older ones and their files are
//// removed.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/io
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/timestamp
import howdy/mail.{type Address, type Attachment, type Outgoing}
import howdy/mail/mime
import simplifile

/// How many messages are kept.
pub const capacity = 500

const timeout = 5000

pub opaque type Outbox {
  Outbox(subject: Subject(Command), directory: Option(String))
}

type Command {
  Deliver(Outgoing, reply: Subject(Nil))
  All(reply: Subject(List(Outgoing)))
  Clear(reply: Subject(Nil))
  Subscribe(Pid, fn() -> Nil)
  Down(process.Down)
}

type State {
  State(
    /// Newest first.
    messages: List(Outgoing),
    directory: Option(String),
    subscribers: List(#(process.Monitor, fn() -> Nil)),
  )
}

@external(erlang, "howdy_mail_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, String)

/// An outbox in memory: its messages are gone when the VM stops.
pub fn start() -> Outbox {
  let assert Ok(box) = begin(None, [])
    as "howdy/mail/outbox: the outbox process did not start"
  box
}

/// An outbox that also writes each message to `directory`, creating it if
/// needed, and starts with the messages already there.
pub fn start_in(directory: String) -> Result(Outbox, String) {
  use _ <- result.try(
    simplifile.create_directory_all(directory)
    |> result.map_error(fn(error) {
      "cannot create " <> directory <> ": " <> simplifile.describe_error(error)
    }),
  )
  use messages <- result.try(load(directory))
  begin(Some(directory), messages)
}

fn begin(
  directory: Option(String),
  messages: List(Outgoing),
) -> Result(Outbox, String) {
  actor.new_with_initialiser(timeout, fn(subject) {
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(Down)
    actor.initialised(State(messages:, directory:, subscribers: []))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Outbox(started.data, directory) })
  |> result.map_error(fn(error) { string.inspect(error) })
}

fn handle(state: State, command: Command) -> actor.Next(State, Command) {
  case command {
    Deliver(outgoing, reply) -> {
      let #(kept, dropped) = list.split([outgoing, ..state.messages], capacity)
      case state.directory {
        Some(directory) -> {
          case write(directory, outgoing) {
            Ok(Nil) -> Nil
            Error(reason) -> io.println_error("howdy/mail/outbox: " <> reason)
          }
          list.each(dropped, remove(directory, _))
        }
        None -> Nil
      }
      process.send(reply, Nil)
      notify(state)
      actor.continue(State(..state, messages: kept))
    }
    All(reply) -> {
      process.send(reply, state.messages)
      actor.continue(state)
    }
    Clear(reply) -> {
      case state.directory {
        Some(directory) -> list.each(state.messages, remove(directory, _))
        None -> Nil
      }
      process.send(reply, Nil)
      notify(state)
      actor.continue(State(..state, messages: []))
    }
    Subscribe(pid, callback) -> {
      let monitor = process.monitor(pid)
      actor.continue(
        State(..state, subscribers: [#(monitor, callback), ..state.subscribers]),
      )
    }
    Down(process.ProcessDown(monitor:, ..))
    | Down(process.PortDown(monitor:, ..)) ->
      actor.continue(
        State(
          ..state,
          subscribers: list.filter(state.subscribers, fn(subscriber) {
            subscriber.0 != monitor
          }),
        ),
      )
  }
}

fn notify(state: State) -> Nil {
  list.each(state.subscribers, fn(subscriber) {
    let _ = rescue(subscriber.1)
    Nil
  })
}

/// Keep messages given to this adapter in the outbox.
pub fn adapter(box: Outbox) -> mail.Adapter {
  mail.adapter(named: "outbox", send: fn(outgoing: Outgoing) {
    process.call(box.subject, timeout, Deliver(outgoing, _))
    Ok(mail.Receipt(outgoing.id, None))
  })
}

/// Every message kept, newest first.
pub fn messages(box: Outbox) -> List(Outgoing) {
  process.call(box.subject, timeout, All)
}

pub fn get(box: Outbox, id: String) -> Result(Outgoing, Nil) {
  list.find(messages(box), fn(outgoing) { outgoing.id == id })
}

/// The newest message with this address among its recipients.
pub fn latest_to(box: Outbox, email: String) -> Result(Outgoing, Nil) {
  let email = string.lowercase(email)
  list.find(messages(box), fn(outgoing) {
    list.any(mail.recipients(outgoing), fn(address) {
      string.lowercase(address.email) == email
    })
  })
}

/// Forget every message, and delete their files.
pub fn clear(box: Outbox) -> Nil {
  process.call(box.subject, timeout, Clear)
}

/// Call `notify` whenever a message arrives or the outbox is cleared, until
/// the calling process exits. It runs in the outbox's process, so it should
/// only send a message, as a live component's `dispatch` does.
pub fn subscribe(box: Outbox, notify: fn() -> Nil) -> Nil {
  process.send(box.subject, Subscribe(process.self(), notify))
}

/// Where messages are written, if anywhere.
pub fn directory(box: Outbox) -> Option(String) {
  box.directory
}

// -- Files ---------------------------------------------------------------------

/// Files sort by when they were sent.
fn stem(outgoing: Outgoing) -> String {
  let #(seconds, nanoseconds) =
    timestamp.to_unix_seconds_and_nanoseconds(outgoing.date)
  let milliseconds = seconds * 1000 + nanoseconds / 1_000_000
  string.pad_start(int.to_string(milliseconds), 15, "0") <> "-" <> outgoing.id
}

fn write(directory: String, outgoing: Outgoing) -> Result(Nil, String) {
  let path = directory <> "/" <> stem(outgoing)
  {
    use _ <- result.try(simplifile.write(path <> ".eml", mime.encode(outgoing)))
    simplifile.write(path <> ".json", json.to_string(encode(outgoing)))
  }
  |> result.map_error(fn(error) {
    "cannot write " <> path <> ": " <> simplifile.describe_error(error)
  })
}

fn remove(directory: String, outgoing: Outgoing) -> Nil {
  let path = directory <> "/" <> stem(outgoing)
  let _ = simplifile.delete(path <> ".eml")
  let _ = simplifile.delete(path <> ".json")
  Nil
}

/// The messages in `directory`, newest first. Files that do not decode are
/// skipped.
fn load(directory: String) -> Result(List(Outgoing), String) {
  use names <- result.try(
    simplifile.read_directory(directory)
    |> result.map_error(fn(error) {
      "cannot read " <> directory <> ": " <> simplifile.describe_error(error)
    }),
  )
  names
  |> list.filter(string.ends_with(_, ".json"))
  |> list.filter_map(fn(name) {
    use text <- result.try(
      simplifile.read(directory <> "/" <> name) |> result.replace_error(Nil),
    )
    json.parse(text, decoder()) |> result.replace_error(Nil)
  })
  |> list.sort(fn(a, b) { timestamp.compare(b.date, a.date) })
  |> list.take(capacity)
  |> Ok
}

fn encode(outgoing: Outgoing) -> Json {
  let #(seconds, nanoseconds) =
    timestamp.to_unix_seconds_and_nanoseconds(outgoing.date)
  json.object([
    #("id", json.string(outgoing.id)),
    #("seconds", json.int(seconds)),
    #("nanoseconds", json.int(nanoseconds)),
    #("from", encode_address(outgoing.from)),
    #("to", json.array(outgoing.to, encode_address)),
    #("cc", json.array(outgoing.cc, encode_address)),
    #("bcc", json.array(outgoing.bcc, encode_address)),
    #("reply_to", json.nullable(outgoing.reply_to, encode_address)),
    #("subject", json.string(outgoing.subject)),
    #("html", json.nullable(outgoing.html, json.string)),
    #("text", json.nullable(outgoing.text, json.string)),
    #(
      "headers",
      json.array(outgoing.headers, fn(header) {
        json.preprocessed_array([json.string(header.0), json.string(header.1)])
      }),
    ),
    #("attachments", json.array(outgoing.attachments, encode_attachment)),
    #("tags", json.array(outgoing.tags, json.string)),
  ])
}

fn encode_address(address: Address) -> Json {
  json.object([
    #("name", json.nullable(address.name, json.string)),
    #("email", json.string(address.email)),
  ])
}

fn encode_attachment(attachment: Attachment) -> Json {
  json.object([
    #("filename", json.string(attachment.filename)),
    #("content_type", json.string(attachment.content_type)),
    #("content", json.string(bit_array.base64_encode(attachment.content, True))),
    #("content_id", json.nullable(attachment.content_id, json.string)),
  ])
}

fn decoder() -> decode.Decoder(Outgoing) {
  use id <- decode.field("id", decode.string)
  use seconds <- decode.field("seconds", decode.int)
  use nanoseconds <- decode.field("nanoseconds", decode.int)
  use from <- decode.field("from", address_decoder())
  use to <- decode.field("to", decode.list(address_decoder()))
  use cc <- decode.field("cc", decode.list(address_decoder()))
  use bcc <- decode.field("bcc", decode.list(address_decoder()))
  use reply_to <- decode.field("reply_to", decode.optional(address_decoder()))
  use subject <- decode.field("subject", decode.string)
  use html <- decode.field("html", decode.optional(decode.string))
  use text <- decode.field("text", decode.optional(decode.string))
  use headers <- decode.field(
    "headers",
    decode.list({
      use name <- decode.field(0, decode.string)
      use value <- decode.field(1, decode.string)
      decode.success(#(name, value))
    }),
  )
  use attachments <- decode.field(
    "attachments",
    decode.list(attachment_decoder()),
  )
  use tags <- decode.field("tags", decode.list(decode.string))
  decode.success(mail.Outgoing(
    id:,
    date: timestamp.from_unix_seconds_and_nanoseconds(seconds, nanoseconds),
    from:,
    to:,
    cc:,
    bcc:,
    reply_to:,
    subject:,
    html:,
    text:,
    headers:,
    attachments:,
    tags:,
  ))
}

fn address_decoder() -> decode.Decoder(Address) {
  use name <- decode.field("name", decode.optional(decode.string))
  use email <- decode.field("email", decode.string)
  decode.success(mail.Address(name:, email:))
}

fn attachment_decoder() -> decode.Decoder(Attachment) {
  use filename <- decode.field("filename", decode.string)
  use content_type <- decode.field("content_type", decode.string)
  use content <- decode.field("content", decode.string)
  use content_id <- decode.field("content_id", decode.optional(decode.string))
  case bit_array.base64_decode(content) {
    Ok(content) ->
      decode.success(mail.Attachment(
        filename:,
        content_type:,
        content:,
        content_id:,
      ))
    Error(Nil) ->
      decode.failure(
        mail.attachment(filename, content_type, <<>>),
        "base64 content",
      )
  }
}
