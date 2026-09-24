//// Every page of the admin, driven through the app without a server,
//// against an in-memory SQLite database with auth installed.

import gleam/dynamic/decode
import gleam/http/request
import gleam/list
import gleam/string
import gleeunit
import gloo/adapter/sqlite
import gloo/migration as gloo_migration
import gloo/repo.{type Repo}
import gloo/sql
import howdy
import howdy/admin
import howdy/auth
import howdy/auth/group
import howdy/auth/user
import howdy/database
import howdy/migration
import howdy/testing

pub fn main() {
  gleeunit.main()
}

// -- Fixtures ----------------------------------------------------------------

fn notes() -> migration.Package {
  migration.Package("notes", [
    gloo_migration.new(
      1,
      "create",
      "CREATE TABLE notes_notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL, body TEXT, stars INTEGER NOT NULL DEFAULT 0)",
    ),
  ])
}

fn with_database(run: fn(Repo) -> a) -> a {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  let assert Ok(Nil) = database.sqlite_defaults(db)
  let assert Ok(Nil) = migration.run(db, [auth.schema(), notes()])
  let value = run(db)
  let assert Ok(_) = repo.close(db)
  value
}

fn with_auth(run: fn(Repo, auth.Auth) -> a) -> a {
  use db <- with_database
  let assert Ok(identity) =
    auth.new_without_email(repo: db, origin: "http://localhost:8787")
  run(db, identity)
}

fn app(register: fn(admin.Admin) -> admin.Admin) -> howdy.App {
  howdy.new() |> admin.mount(admin.new() |> register)
}

fn get(app: howdy.App, path: String) -> String {
  let res =
    testing.get(path) |> request.set_host("localhost") |> testing.send(app)
  assert res.status == 200
    as { "GET " <> path <> " gave " <> string.inspect(res.status) }
  testing.text(res)
}

fn post(
  app: howdy.App,
  path: String,
  fields: List(#(String, String)),
) -> String {
  let res =
    testing.post_form(path, fields)
    |> request.set_host("localhost")
    |> testing.send(app)
  assert res.status == 303
    as {
      "POST "
      <> path
      <> " gave "
      <> string.inspect(res.status)
      <> ": "
      <> testing.text(res)
    }
  let assert Ok(location) = list.key_find(res.headers, "location")
  location
}

fn count(db: Repo, statement: String) -> Int {
  let assert Ok([n]) =
    repo.all(db, statement, [], decode.field(0, decode.int, decode.success))
  n
}

fn titles(db: Repo) -> List(String) {
  let assert Ok(rows) =
    repo.all(
      db,
      "SELECT title, body FROM notes_notes ORDER BY id",
      [],
      decode.field(0, decode.string, decode.success),
    )
  rows
}

// -- Mounting ----------------------------------------------------------------

pub fn overview_says_what_is_registered_test() {
  let bare = get(app(fn(a) { a }), "/_howdy")
  assert string.contains(bare, "Not registered")
  assert !string.contains(bare, "Browse tables")

  use db <- with_database
  let page = get(app(admin.database(_, db)), "/_howdy")
  assert string.contains(page, "SQLite")
  assert string.contains(page, "Browse tables")
  assert string.contains(page, "auth v")
  assert string.contains(page, "notes v1")
  assert !string.contains(page, "Users")
}

pub fn auth_registers_its_database_too_test() {
  use _, identity <- with_auth
  let registered = admin.new() |> admin.auth(identity)
  assert admin.has_database(registered)
  assert admin.has_auth(registered)
  let page = get(app(fn(_) { registered }), "/_howdy")
  assert string.contains(page, "0 users")
  assert string.contains(page, "1 group")
  assert string.contains(page, "Browse tables")
}

pub fn mounts_at_another_prefix_test() {
  use db <- with_database
  let app = app(fn(a) { a |> admin.at("dev/admin/") |> admin.database(db) })
  assert string.contains(get(app, "/dev/admin"), "Browse tables")
  assert string.contains(get(app, "/dev/admin/data"), "notes_notes")
  let res =
    testing.get("/_howdy") |> request.set_host("localhost") |> testing.send(app)
  assert res.status == 404
}

pub fn refuses_other_hosts_test() {
  use db <- with_database
  let app = app(admin.database(_, db))
  let res =
    testing.get("/_howdy")
    |> request.set_host("evil.example")
    |> testing.send(app)
  assert res.status == 403
  let allowed =
    howdy.new()
    |> admin.mount(
      admin.new()
      |> admin.database(db)
      |> admin.allow_hosts(["dev.example.test"]),
    )
  let res =
    testing.get("/_howdy")
    |> request.set_host("dev.example.test")
    |> testing.send(allowed)
  assert res.status == 200
}

// -- Data --------------------------------------------------------------------

pub fn lists_tables_and_columns_test() {
  use db <- with_database
  let app = app(admin.database(_, db))
  // Howdy's own tables are hidden until asked for.
  let index = get(app, "/_howdy/data")
  assert string.contains(index, "notes_notes")
  assert !string.contains(index, "howdy_auth_users")
  assert string.contains(index, "Howdy tables too")
  let index = get(app, "/_howdy/data?all=1")
  assert string.contains(index, "notes_notes")
  assert string.contains(index, "howdy_auth_users")
  assert string.contains(index, "Hide Howdy")
  let table = get(app, "/_howdy/data/notes_notes")
  assert string.contains(table, "INTEGER")
  assert string.contains(table, "stars")
  assert string.contains(table, "/_howdy/live/data/notes_notes")
  let res =
    testing.get("/_howdy/data/nope")
    |> request.set_host("localhost")
    |> testing.send(app)
  assert res.status == 200
  assert string.contains(testing.text(res), "Not found")
}

pub fn inserts_edits_and_deletes_rows_test() {
  use db <- with_database
  let app = app(admin.database(_, db))
  // Empty columns take their defaults; NULL is explicit.
  let location =
    post(app, "/_howdy/data/notes_notes", [
      #("value-title", "First"),
      #("value-body", ""),
      #("null-body", "1"),
      #("value-stars", ""),
    ])
  assert location == "/_howdy/data/notes_notes"
  assert titles(db) == ["First"]
  assert count(
      db,
      "SELECT COUNT(*) FROM notes_notes WHERE body IS NULL AND stars = 0",
    )
    == 1

  let form = get(app, "/_howdy/data/notes_notes/row?k=1")
  assert string.contains(form, "value=\"First\"")
  let assert Ok(_) =
    repo.execute(db, "UPDATE notes_notes SET body = 'kept' WHERE id = 1", [])
  let _ =
    post(app, "/_howdy/data/notes_notes/row?k=1", [
      #("value-id", "1"),
      #("value-title", "Renamed"),
      #("value-body", "hello"),
      #("value-stars", "3"),
    ])
  assert titles(db) == ["Renamed"]
  assert count(
      db,
      "SELECT COUNT(*) FROM notes_notes WHERE body = 'hello' AND stars = 3",
    )
    == 1

  let _ = post(app, "/_howdy/data/notes_notes/row/delete?k=1", [])
  assert titles(db) == []
}

pub fn shows_the_database_error_when_a_write_is_refused_test() {
  use db <- with_database
  let app = app(admin.database(_, db))
  let res =
    testing.post_form("/_howdy/data/notes_notes", [#("value-body", "no title")])
    |> request.set_host("localhost")
    |> testing.send(app)
  assert res.status == 200
  assert string.contains(testing.text(res), "NOT NULL")
  assert titles(db) == []
}

pub fn a_table_without_a_primary_key_is_addressed_by_rowid_test() {
  use db <- with_database
  let assert Ok(_) = repo.execute(db, "CREATE TABLE loose (a TEXT, b TEXT)", [])
  let assert Ok(_) =
    repo.execute(db, "INSERT INTO loose VALUES ('x', 'y'), ('p', 'q')", [])
  let app = app(admin.database(_, db))
  let page = get(app, "/_howdy/data/loose/row?k=2")
  assert string.contains(page, "value=\"p\"")
  let _ =
    post(app, "/_howdy/data/loose/row?k=2", [
      #("value-a", "P"),
      #("value-b", "q"),
    ])
  assert count(db, "SELECT COUNT(*) FROM loose WHERE a = 'P'") == 1
  let _ = post(app, "/_howdy/data/loose/row/delete?k=1", [])
  assert count(db, "SELECT COUNT(*) FROM loose") == 1
}

// -- Auth --------------------------------------------------------------------

pub fn creates_lists_and_manages_users_test() {
  use db, identity <- with_auth
  let app = app(admin.auth(_, identity))
  assert string.contains(get(app, "/_howdy/users"), "No users yet")

  let location = post(app, "/_howdy/users", [#("email", "Ada@Example.com")])
  let assert "/_howdy/users/" <> id = location
  assert string.contains(get(app, "/_howdy/users"), "ada@example.com")
  let page = get(app, location)
  assert string.contains(page, "Sign in as this user")
  assert string.contains(page, "active")

  let _ = post(app, location <> "/suspend", [])
  let page = get(app, location)
  assert string.contains(page, "suspended")
  assert !string.contains(page, "Sign in as this user")
  let _ = post(app, location <> "/resume", [])
  assert string.contains(get(app, location), "active")
  let _ = post(app, location <> "/revoke", [])
  assert count(
      db,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'sessions.revoked' AND client = 'howdy_admin'",
    )
    == 1
  let assert Ok(_) = auth.impersonate(identity, id, by: user.System)

  // A duplicate is refused with the reason on the page.
  let res =
    testing.post_form("/_howdy/users", [#("email", "ada@example.com")])
    |> request.set_host("localhost")
    |> testing.send(app)
  assert res.status == 200
  assert string.contains(testing.text(res), "already exists")
}

pub fn signing_in_as_a_user_sets_the_session_cookie_test() {
  use _, identity <- with_auth
  let app = app(admin.auth(_, identity))
  let assert "/_howdy/users/" <> id =
    post(app, "/_howdy/users", [#("email", "ada@example.com")])
  let res =
    testing.post_form("/_howdy/users/" <> id <> "/impersonate", [])
    |> request.set_host("localhost")
    |> testing.send(app)
  assert res.status == 303
  assert list.key_find(res.headers, "location") == Ok("/")
  let assert Ok(token) =
    list.key_find(testing.cookies(res), auth.cookie_name(identity))
  let assert Ok(principal) = auth.authenticate(identity, token)
  assert principal.user.id == id
}

pub fn manages_groups_test() {
  use db, identity <- with_auth
  let assert Ok(identity) = auth.with_groups(identity, group.OneGroupPerUser)
  let app = app(admin.auth(_, identity))
  let page = get(app, "/_howdy/groups")
  assert string.contains(page, "one-group-per-user")
  assert string.contains(page, "New group")

  let location =
    post(app, "/_howdy/groups", [#("name", "Acme"), #("id", "acme")])
  assert location == "/_howdy/groups/acme"
  let assert "/_howdy/groups/" <> generated =
    post(app, "/_howdy/groups", [#("name", "Generated"), #("id", "")])
  assert generated != ""
  let _ = post(app, location <> "/rename", [#("name", "Acme Ltd")])
  assert string.contains(get(app, location), "Acme Ltd")

  // A user created in a group, then moved to another.
  let assert "/_howdy/users/" <> id =
    post(app, "/_howdy/users", [
      #("email", "ada@example.com"),
      #("group", "acme"),
    ])
  assert string.contains(get(app, location), "ada@example.com")
  let _ = post(app, "/_howdy/users/" <> id <> "/move", [#("group", generated)])
  assert !string.contains(get(app, location), "ada@example.com")
  assert string.contains(
    get(app, "/_howdy/groups/" <> generated),
    "ada@example.com",
  )

  let _ = post(app, location <> "/delete", [])
  assert count(db, "SELECT COUNT(*) FROM howdy_auth_groups WHERE id = 'acme'")
    == 0
  let res =
    testing.post_form("/_howdy/groups/default/delete", [])
    |> request.set_host("localhost")
    |> testing.send(app)
  assert string.contains(testing.text(res), "default group cannot be deleted")
}

pub fn the_live_grid_serves_a_socket_route_test() {
  use db <- with_database
  let app = app(admin.database(_, db))
  // Without an upgrade request the socket route answers as a plain route
  // would: not a page, but not a routing miss either.
  let res =
    testing.get("/_howdy/live/data/notes_notes")
    |> request.set_host("localhost")
    |> testing.send(app)
  assert res.status != 404
  let _ = sql.string("unused")
}
