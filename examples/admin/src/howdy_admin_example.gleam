//// A notes app with email-token sign-in, on SQLite. `gleam run` serves it
//// as in production; `gleam dev` serves the same app with hot reload and
//// the admin area at <http://localhost:8787/_howdy>.
////
//// Email delivery prints tokens in the terminal **for this local
//// demonstration only**; a real application delivers them privately.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/result
import gloo/adapter/sqlite
import gloo/migration as gloo_migration
import gloo/repo.{type Repo}
import gloo/sql
import howdy
import howdy/auth
import howdy/auth/pages
import howdy/auth/routes
import howdy/auth/secret
import howdy/auth/user.{type User}
import howdy/authorization as access
import howdy/body
import howdy/controller
import howdy/database
import howdy/guard
import howdy/migration
import howdy/service

pub const origin = "http://localhost:8787"

pub fn main() {
  let db = open("admin_example.sqlite")
  let identity = identity(db)
  let assert Ok(_) =
    app(db, identity, permissions(db))
    |> howdy.bind(to: "127.0.0.1")
    |> howdy.listening(on: 8787)
    |> howdy.start
  process.sleep_forever()
}

/// Open the database and bring the schema up to date. A real deployment
/// migrates in a separate step before starting; an example migrates here
/// so `gleam run` and `gleam dev` work from a clean checkout.
pub fn open(path: String) -> Repo {
  let assert Ok(db) = sqlite.start(sqlite.file(path))
  let assert Ok(Nil) = database.sqlite_defaults(db)
  let assert Ok(Nil) =
    migration.run(db, [auth.schema(), access.schema(), schema()])
  db
}

/// Roles and permissions, with one role defined so the admin has something
/// to assign. Assignment is left to the admin: there is no first-user
/// administrator.
pub fn permissions(db: Repo) -> access.Authorization {
  let assert Ok(permissions) = access.new(db)
  let assert Ok(Nil) =
    access.define_role(
      permissions,
      access.Global,
      "reader",
      ["notes.read_all"],
      by: user.System,
    )
  permissions
}

pub fn identity(db: Repo) -> auth.Auth {
  let assert Ok(identity) =
    auth.new(repo: db, origin:, deliver: fn(delivery) {
      io.println(
        "LOCAL DEMO email to "
        <> delivery.email
        <> ": "
        <> secret.reveal(delivery.token),
      )
      Ok(Nil)
    })
  identity
  |> auth.allow_registration
  // Deleting an account removes its notes in the same transaction.
  |> auth.with_account_deletion(fn(conn, user) {
    database.execute(conn, "DELETE FROM notes_notes WHERE user_id = $1", [
      sql.string(user.id),
    ])
  })
}

pub fn app(
  db: Repo,
  identity: auth.Auth,
  permissions: access.Authorization,
) -> howdy.App {
  let notes =
    controller.guarded("/notes", auth.required(identity))
    |> controller.get("/", fn(ctx) {
      list(db, ctx.guard.user)
      |> service.respond(ctx, json.array(_, note_to_json))
    })
    // Everyone's notes, for a user holding the global `reader` role.
    |> controller.get("/all", fn(ctx) {
      use _ <- guard.require(
        ctx,
        access.require_permission(permissions, "notes.read_all", access.Global),
      )
      list_all(db)
      |> service.respond(ctx, json.array(_, note_to_json))
    })
    |> controller.post("/", fn(ctx) {
      use title <- body.json(ctx, decode.at(["title"], decode.string))
      create(db, ctx.guard.user, title)
      |> service.created(ctx, note_to_json)
    })
    |> controller.build
  howdy.new()
  |> howdy.controller(routes.api(identity, at: "/api/auth"))
  |> howdy.controller(pages.routes(identity, at: "/auth", api_at: "/api/auth"))
  |> howdy.controller(notes)
  |> howdy.controller(
    controller.new("/")
    |> controller.get("/", fn(ctx) {
      controller.text(
        ctx,
        "Register at /auth/register, then GET and POST /notes. /notes/all needs the reader role. In development the admin is at /_howdy.",
      )
    }),
  )
}

// -- Notes -------------------------------------------------------------------

pub type Note {
  Note(id: Int, title: String, stars: Int)
}

pub fn schema() -> migration.Package {
  migration.Package("notes", [
    gloo_migration.new(
      1,
      "create_notes",
      "CREATE TABLE notes_notes (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE, title TEXT NOT NULL, stars INTEGER NOT NULL DEFAULT 0, created_at BIGINT NOT NULL DEFAULT (unixepoch()))",
    ),
  ])
}

pub fn list(db: Repo, owner: User) -> service.Result(List(Note)) {
  use conn <- database.connect(db)
  database.query(
    conn,
    "SELECT id, title, stars FROM notes_notes WHERE user_id = $1 ORDER BY id",
    [sql.string(owner.id)],
    note_row(),
  )
}

pub fn list_all(db: Repo) -> service.Result(List(Note)) {
  use conn <- database.connect(db)
  database.query(
    conn,
    "SELECT id, title, stars FROM notes_notes ORDER BY id",
    [],
    note_row(),
  )
}

pub fn create(db: Repo, owner: User, title: String) -> service.Result(Note) {
  use conn <- database.transaction(db)
  use _ <- result.try(
    database.execute(
      conn,
      "INSERT INTO notes_notes (user_id, title) VALUES ($1, $2)",
      [sql.string(owner.id), sql.string(title)],
    ),
  )
  database.one(
    conn,
    "SELECT id, title, stars FROM notes_notes WHERE user_id = $1 ORDER BY id DESC LIMIT 1",
    [sql.string(owner.id)],
    note_row(),
    or: service.Internal("the note was not written"),
  )
}

fn note_row() -> decode.Decoder(Note) {
  use id <- decode.field(0, decode.int)
  use title <- decode.field(1, decode.string)
  use stars <- decode.field(2, decode.int)
  decode.success(Note(id:, title:, stars:))
}

pub fn note_to_json(note: Note) -> json.Json {
  json.object([
    #("id", json.int(note.id)),
    #("title", json.string(note.title)),
    #("stars", json.int(note.stars)),
  ])
}
