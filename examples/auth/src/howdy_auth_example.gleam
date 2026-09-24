import database
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/option.{None, Some}
import gloo/repo.{type Repo}
import howdy
import howdy/auth
import howdy/auth/mfa
import howdy/auth/pages
import howdy/auth/providers/google
import howdy/auth/routes
import howdy/auth/secret
import howdy/auth/user
import howdy/authorization as access
import howdy/body
import howdy/controller
import howdy/guard
import howdy/migration
import howdy/service
import notes

pub fn app(db: Repo, identity: auth.Auth, permissions: access.Authorization) {
  let account =
    controller.guarded("/account", auth.required(identity))
    |> controller.get("/me", fn(ctx) {
      controller.json(ctx, user.to_json(ctx.guard.user))
    })
    |> controller.get("/reports", fn(ctx) {
      use _ <- guard.require(
        ctx,
        access.require_permission(permissions, "reports.read", access.Global),
      )
      controller.text(ctx, "You can read reports.")
    })
    // Application-owned rows, kept beside auth's through howdy/database.
    |> controller.get("/notes", fn(ctx) {
      notes.list(db, ctx.guard.user)
      |> service.respond(ctx, json.array(_, notes.to_json))
    })
    |> controller.post("/notes", fn(ctx) {
      use title <- body.json(ctx, decode.at(["title"], decode.string))
      notes.create(db, ctx.guard.user, title)
      |> service.created(ctx, notes.to_json)
    })
    |> controller.delete("/notes/:id", fn(ctx) {
      let assert Ok(id) = controller.param(ctx, "id")
      notes.delete(db, ctx.guard.user, id) |> service.no_content(ctx)
    })
    |> controller.build()

  howdy.new()
  |> howdy.controller(routes.api(identity, at: "/api/auth"))
  |> howdy.controller(routes.providers(
    identity,
    at: "/auth",
    success_path: "/auth/account",
    failure_path: "/auth/login",
  ))
  |> howdy.controller(pages.routes(identity, at: "/auth", api_at: "/api/auth"))
  |> howdy.controller(account)
}

pub fn main() {
  let db = database.connect()
  // Refuse to start against a schema `gleam run -m migrate` has not caught up.
  let assert Ok(_) = migration.check(db, notes.schema())
  // Local demonstration only. Real applications deliver tokens privately by
  // email and must never send them to logs or the browser that requested them.
  let assert Ok(identity) =
    auth.new(repo: db, origin: "http://localhost:8787", deliver: fn(delivery) {
      // A real application writes one email per purpose. Registering an
      // address that already has an account arrives as AlreadyRegistered, so
      // say so rather than inviting them to register again.
      let subject = case delivery.purpose {
        auth.EmailChange -> "Confirm your new email address"
        auth.EmailChangeApproval ->
          "Approve moving your account to a new email address"
        auth.EmailChanged -> "Your account now uses a different email address"
        auth.PasswordChanged ->
          "Your password was changed; reset it by email if this was not you"
        auth.SignIn -> "Your sign-in token"
        auth.Registration -> "Confirm your new account"
        auth.AlreadyRegistered ->
          "You already have an account; this token signs you in"
      }
      io.println(
        "LOCAL DEMO email for "
        <> delivery.email
        <> " ["
        <> subject
        <> "]: "
        <> secret.reveal(delivery.token),
      )
      Ok(Nil)
    })
  let identity = case google_credentials() {
    None -> identity
    Some(#(client_id, client_secret)) -> {
      let assert Ok(identity) =
        auth.with_provider(identity, google.new(client_id:, client_secret:))
      identity
    }
  }
  // Application-owned rows go in the same transaction as the account.
  let identity = auth.with_account_deletion(identity, notes.delete_all)
  let identity = auth.allow_registration(identity)
  let assert Ok(identity) = auth.with_passwords(identity)
  let assert Ok(identity) = auth.with_passkeys(identity, "Howdy demo")
  let identity = case mfa_key() {
    None -> identity
    Some(key) -> {
      let assert Ok(config) = mfa.new("Howdy demo", key)
      auth.with_mfa(identity, config)
    }
  }
  let assert Ok(permissions) = access.new(db)
  let assert Ok(_) =
    access.define_role(
      permissions,
      access.Global,
      "reader",
      ["reports.read"],
      by: user.System,
    )
  let assert Ok(_) =
    app(db, identity, permissions)
    |> howdy.bind(to: "127.0.0.1")
    |> howdy.start()
  process.sleep_forever()
}

// Read credentials at startup, never from requests or source-controlled values.
@external(erlang, "howdy_auth_example_ffi", "google_credentials")
fn google_credentials() -> option.Option(#(String, String))

@external(erlang, "howdy_auth_example_ffi", "mfa_key")
fn mfa_key() -> option.Option(String)
