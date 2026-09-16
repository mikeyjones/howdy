# Chat example

A chat room built on `howdy/websocket` and `howdy/websocket/channel`.

```sh
cd examples/chat
gleam run
```

It listens on port **8789**. Open http://localhost:8789 in two browser tabs,
pick a name and a room, and talk.

Each room is a channel topic. A socket joins the room when it opens and pg
drops it when the connection ends. Anything that knows the room name can
broadcast to it, so the HTTP routes below reach the same sockets:

```sh
curl http://localhost:8789/rooms/lobby                                   # {"room":"lobby","members":2}
curl -i -X POST http://localhost:8789/rooms/lobby/announce -d '{"text":"Server restarting soon"}'   # 202, shows in every tab
curl -i 'http://localhost:8789/chat/lobby'                               # 400, the name is checked before the upgrade
```

With [websocat](https://github.com/vi/websocat) you can join from a terminal
and type JSON lines:

```sh
websocat 'ws://localhost:8789/chat/lobby?name=Ada'
{"text":"hello from the terminal"}
```

Run the HTTP routes as tests, without a server:

```sh
gleam test
```
