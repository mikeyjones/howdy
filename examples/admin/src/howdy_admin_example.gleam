//// A notes app with email-token sign-in, on SQLite, or on PostgreSQL when
//// `DATABASE_URL` is set. `gleam run` serves it as in production;
//// `gleam dev` serves the same app with hot reload and the admin area at
//// <http://localhost:8787/_howdy>.
////
//// With `OTEL_EXPORTER_OTLP_ENDPOINT` set, such as `http://localhost:4318`,
//// `gleam run` sends a trace of every request to that OpenTelemetry
//// collector. Under `gleam dev` the admin shows them instead.
////
//// Auth emails go through `howdy/mail`: over SMTP when `SMTP_URL` is set,
//// otherwise printed in the terminal **for this local demonstration
//// only**. Under `gleam dev` they go to the outbox the admin shows.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gloo/adapter/sqlite
import gloo/migration as gloo_migration
import gloo/repo.{type Repo}
import gloo/sql
import howdy
import howdy/auth
import howdy/auth/emails
import howdy/auth/pages
import howdy/auth/routes
import howdy/auth/user.{type Principal, type User}
import howdy/authorization as access
import howdy/controller.{type GuardedContext}
import howdy/database
import howdy/database/postgres
import howdy/flags
import howdy/flags/database as flags_database
import howdy/guard
import howdy/mail
import howdy/mail/preview
import howdy/mail/smtp
import howdy/migration
import howdy/openapi
import howdy/openapi/endpoint
import howdy/openapi/schema.{type Schema}
import howdy/service
import howdy/telemetry
import howdy/validate
import smail/email as smail
import smail/html

pub const origin = "http://localhost:8787"

pub fn main() {
  // Telemetry is opt-in: without the variable nothing is recorded or sent.
  case telemetry.from_env("notes") {
    Ok(config) -> {
      let assert Ok(Nil) = telemetry.start(config)
      Nil
    }
    Error(Nil) -> Nil
  }
  let db = open("admin_example.sqlite")
  let identity = identity(db, mailer())
  let assert Ok(_) =
    app(db, identity, permissions(db), features(db))
    |> howdy.bind(to: "127.0.0.1")
    |> howdy.listening(on: 8787)
    |> howdy.start
  process.sleep_forever()
}

/// Open the database and bring the schema up to date. A real deployment
/// migrates in a separate step before starting; an example migrates here
/// so `gleam run` and `gleam dev` work from a clean checkout. With
/// `DATABASE_URL` set, PostgreSQL is used instead of the SQLite file.
pub fn open(path: String) -> Repo {
  let db = case postgres.from_env() {
    Ok(config) -> {
      let assert Ok(db) = postgres.start(config)
      db
    }
    Error(_) -> {
      let assert Ok(db) = sqlite.start(sqlite.file(path))
      let assert Ok(Nil) = database.sqlite_defaults(db)
      // PostgreSQL Repos from howdy/database/postgres are traced already.
      database.traced(db)
    }
  }
  let assert Ok(Nil) =
    migration.run(db, [
      auth.schema(),
      access.schema(),
      flags_database.schema(),
      schema(),
    ])
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

/// SMTP from `SMTP_URL`, such as `smtp://localhost:1025` for Mailpit, or
/// else the terminal.
pub fn mailer() -> mail.Mailer {
  let adapter = case smtp.from_env() {
    Ok(config) -> smtp.adapter(config)
    Error(_) ->
      mail.adapter(named: "terminal", send: fn(outgoing: mail.Outgoing) {
        io.println(
          "LOCAL DEMO email to "
          <> string.join(list.map(outgoing.to, mail.address_to_string), ", ")
          <> ": "
          <> outgoing.subject
          <> "\n"
          <> option.unwrap(outgoing.text, ""),
        )
        Ok(mail.Receipt(outgoing.id, option.None))
      })
  }
  mail.mailer(adapter) |> mail.default_from(sender)
}

pub const sender = mail.Address(option.Some("Notes"), "notes@localhost")

pub fn emails(mailer: mail.Mailer) -> emails.Emails {
  emails.new(mailer, app_name: "Notes")
}

/// The app's own email, beside the ones auth sends.
pub fn digest(to email: String, notes notes: List(Note)) -> mail.Message {
  mail.message()
  |> mail.to([mail.address(email)])
  |> mail.subject("Your notes this week")
  |> mail.tag("notes.digest")
  |> mail.template(
    smail.html([], [
      smail.head([], []),
      smail.body([], [
        smail.preview(int.to_string(list.length(notes)) <> " notes"),
        smail.container([], [
          smail.h2([], [html.text("Your notes this week")]),
          ..list.map(notes, fn(note) {
            smail.paragraph([], [
              html.text(note.title <> " · " <> int.to_string(note.stars) <> "★"),
            ])
          })
        ]),
      ]),
    ]),
  )
}

/// Every email the app sends, for the admin's previews.
pub fn previews(mailer: mail.Mailer) -> List(preview.Preview) {
  [
    preview.new("Weekly digest", fn() {
      digest(to: "someone@example.com", notes: [
        Note(id: 1, title: "Buy milk", stars: 2),
        Note(id: 2, title: "Call the plumber", stars: 5),
      ])
    })
      |> preview.in_group("Notes"),
    ..emails.previews(emails(mailer))
  ]
}

pub fn identity(db: Repo, mailer: mail.Mailer) -> auth.Auth {
  let assert Ok(identity) =
    auth.new(repo: db, origin:, deliver: emails.deliver(emails(mailer)))
  let assert Ok(identity) = auth.with_email_links(identity, at: "/auth")
  identity
  |> auth.allow_registration
  // Deleting an account removes its notes in the same transaction.
  |> auth.with_account_deletion(fn(conn, user) {
    database.execute(conn, "DELETE FROM notes_notes WHERE user_id = $1", [
      sql.string(user.id),
    ])
  })
}

/// A feature flag: off until it is turned on, in the admin under **Flags**
/// or from a console, for some users, a group or a share of everyone.
pub fn newest_first() -> flags.Flag {
  flags.flag(
    "notes_newest_first",
    description: "List a user's notes newest first in GET /notes",
  )
}

/// Every flag the app defines: registered at startup, and managed with
/// `gleam run -m tasks/flags`. Add new flags here.
pub fn all_flags() -> List(flags.Flag) {
  [newest_first()]
}

/// The app's flags, kept in its database and kept current from it.
pub fn features(db: Repo) -> flags.Flags {
  let assert Ok(store) = flags_database.store(db)
  let assert Ok(features) =
    flags.new(store) |> flags.register(all_flags()) |> flags.start
  features
}

pub fn app(
  db: Repo,
  identity: auth.Auth,
  permissions: access.Authorization,
  features: flags.Flags,
) -> howdy.App {
  // Documented with howdy/openapi, so the admin can list and call them,
  // signed in as any user.
  let notes =
    controller.guarded("/notes", auth.required(identity))
    |> endpoint.get("/", {
      use <- endpoint.describe([
        endpoint.summary("Your notes"),
        endpoint.security("session"),
        endpoint.response(200, "Your notes", schema.list(note())),
        endpoint.error(401, "Not signed in"),
      ])
      use ctx: GuardedContext(Principal) <- endpoint.handle
      let user = ctx.guard.user
      list(
        db,
        user,
        newest_first: flags.enabled(
          features,
          newest_first(),
          for: flags.user(user.id),
        ),
      )
      |> service.respond(ctx, schema.to_json(_, schema.list(note())))
    })
    // Everyone's notes, for a user holding the global `reader` role.
    |> endpoint.get("/all", {
      use <- endpoint.describe([
        endpoint.summary("Everyone's notes"),
        endpoint.description("Needs the global reader role."),
        endpoint.security("session"),
        endpoint.response(200, "Every note", schema.list(note())),
        endpoint.error(401, "Not signed in"),
        endpoint.error(403, "Without the reader role"),
      ])
      use ctx: GuardedContext(Principal) <- endpoint.handle
      use _ <- guard.require(
        ctx,
        access.require_permission(permissions, "notes.read_all", access.Global),
      )
      list_all(db)
      |> service.respond(ctx, schema.to_json(_, schema.list(note())))
    })
    |> endpoint.post("/", {
      use <- endpoint.describe([
        endpoint.summary("Write a note"),
        endpoint.security("session"),
        endpoint.response(201, "The new note", note()),
        endpoint.error(401, "Not signed in"),
      ])
      use input <- endpoint.body(new_note())
      use ctx: GuardedContext(Principal) <- endpoint.handle
      create(db, ctx.guard.user, input)
      |> service.created(ctx, schema.to_json(_, note()))
    })
    |> controller.build
  let spec =
    openapi.new(title: "Notes", version: "1.0.0")
    |> openapi.description(
      "Sign in at /auth/register, or call as any user from the admin.",
    )
    |> openapi.bearer_auth("session")
  howdy.new()
  |> howdy.controller(routes.api(identity, at: "/api/auth"))
  |> howdy.controller(pages.routes(identity, at: "/auth", api_at: "/api/auth"))
  |> howdy.controller(notes)
  |> howdy.controller(
    controller.new("/")
    |> controller.get("/", fn(ctx) {
      controller.text(
        ctx,
        "Register at /auth/register, then GET and POST /notes. /notes/all needs the reader role. The API is described at /openapi.json. In development the admin is at /_howdy.",
      )
    }),
  )
  |> openapi.serve(spec, at: "/openapi.json")
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
      migration.per_database(
        postgres: "CREATE TABLE notes_notes (id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, user_id TEXT NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE, title TEXT NOT NULL, stars INTEGER NOT NULL DEFAULT 0, created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM now())::bigint)",
        sqlite: "CREATE TABLE notes_notes (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE, title TEXT NOT NULL, stars INTEGER NOT NULL DEFAULT 0, created_at BIGINT NOT NULL DEFAULT (unixepoch()))",
      ),
    ),
  ])
}

pub fn list(
  db: Repo,
  owner: User,
  newest_first newest_first: Bool,
) -> service.Result(List(Note)) {
  use conn <- database.connect(db)
  database.query(
    conn,
    "SELECT id, title, stars FROM notes_notes WHERE user_id = $1 ORDER BY id"
      <> case newest_first {
      True -> " DESC"
      False -> ""
    },
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

pub fn note() -> Schema(Note) {
  {
    use id <- schema.field("id", schema.int(), fn(note: Note) { note.id })
    use title <- schema.field("title", schema.string(), fn(note: Note) {
      note.title
    })
    use stars <- schema.field("stars", schema.int(), fn(note: Note) {
      note.stars
    })
    schema.success(Note(id:, title:, stars:))
  }
  |> schema.named("Note")
}

/// The title of a new note, the only thing a client sends.
fn new_note() -> Schema(String) {
  {
    use title <- schema.field(
      "title",
      schema.string()
        |> schema.rule(validate.trim())
        |> schema.not_empty
        |> schema.max_length(200),
      fn(title: String) { title },
    )
    schema.success(title)
  }
  |> schema.named("NewNote")
}
