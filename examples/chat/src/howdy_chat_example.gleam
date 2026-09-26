//// A chat server. Run with `gleam run` from `examples/chat`, then open
//// http://localhost:8789 in two browser tabs.
////
//// Every room is a channel topic. A socket joins its room on open and
//// leaves when it closes; anything with the room name can broadcast to it,
//// including the plain HTTP route below.
////
//// ```sh
//// curl http://localhost:8789/rooms/lobby                                   # {"room":"lobby","members":2}
//// curl -X POST http://localhost:8789/rooms/lobby/announce -d '{"text":"Server restarting soon"}'
//// websocat 'ws://localhost:8789/chat/lobby?name=Ada'                      # then type JSON lines: {"text":"hi"}
//// ```

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import howdy
import howdy/body
import howdy/controller.{type Context}
import howdy/logger
import howdy/param
import howdy/query
import howdy/static
import howdy/websocket
import howdy/websocket/channel
import logging

pub fn app() -> howdy.App {
  howdy.new()
  |> howdy.middleware(logger.log)
  |> howdy.controller(chat_controller())
  |> howdy.controller(rooms_controller())
  |> howdy.controller(static.serve("/", from: "priv/public"))
}

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Info)

  let assert Ok(_) = app() |> howdy.listening(on: 8789) |> howdy.start

  process.sleep_forever()
}

// -- WebSocket ---------------------------------------------------------------

/// What one connection knows about itself.
type Member {
  Member(name: String, room: String)
}

/// A message from the client, `{"text": "..."}`.
fn inbound_decoder() -> decode.Decoder(String) {
  use text <- decode.field("text", decode.string)
  decode.success(text)
}

fn topic(room: String) -> String {
  "room:" <> room
}

/// `GET /chat/:room?name=Ada` upgrades to a WebSocket. Query parsing runs
/// before the upgrade, so a missing name is a plain `400` and never a socket.
fn chat_controller() {
  controller.new("chat")
  |> controller.get("/:room", fn(ctx: Context) {
    use room <- param.string(ctx, "room")
    use name <- query.string(ctx, "name")

    websocket.new(fn(socket) {
      channel.join(socket, topic(room))
      notice(room, name <> " joined")
      Member(name:, room:)
    })
    |> websocket.on_json(inbound_decoder(), fn(_socket, member, text) {
      channel.broadcast_json(
        topic(member.room),
        json.object([
          #("kind", json.string("message")),
          #("from", json.string(member.name)),
          #("text", json.string(text)),
        ]),
      )
      websocket.continue(member)
    })
    |> websocket.on_close(fn(_socket, member) {
      // pg drops the socket from the room by itself; only the people need
      // telling.
      notice(member.room, member.name <> " left")
    })
    |> websocket.upgrade(ctx)
  })
}

fn notice(room: String, text: String) -> Nil {
  channel.broadcast_json(
    topic(room),
    json.object([#("kind", json.string("notice")), #("text", json.string(text))]),
  )
}

// -- HTTP --------------------------------------------------------------------

/// Plain routes that read and write the same channels the sockets use.
fn rooms_controller() {
  controller.new("rooms")
  |> controller.get("/:room", fn(ctx: Context) {
    use room <- param.string(ctx, "room")
    controller.json(
      ctx,
      json.object([
        #("room", json.string(room)),
        #("members", json.int(channel.size(topic(room)))),
      ]),
    )
  })
  |> controller.post("/:room/announce", fn(ctx: Context) {
    use room <- param.string(ctx, "room")
    use text <- body.json(ctx, inbound_decoder())
    notice(room, text)
    controller.status(ctx, 202)
  })
}
