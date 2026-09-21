import database
import gleam/erlang/process
import gleam/io
import gleam/option.{None, Some}
import howdy
import howdy/auth
import howdy/auth/mfa
import howdy/auth/pages
import howdy/auth/providers/google
import howdy/auth/routes
import howdy/auth/secret
import howdy/auth/user
import howdy/authorization as access
import howdy/controller
import howdy/guard

pub fn app(identity: auth.Auth, permissions: access.Authorization) {
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
  // Local demonstration only. Real applications deliver tokens privately by
  // email and must never send them to logs or the browser that requested them.
  let assert Ok(identity) =
    auth.new(repo: db, origin: "http://localhost:8787", deliver: fn(delivery) {
      // A real application writes one email per purpose. Registering an
      // address that already has an account arrives as AlreadyRegistered, so
      // say so rather than inviting them to register again.
      let subject = case delivery.purpose {
        auth.EmailChange -> "Confirm your new email address"
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
  // This example has no application-owned user data to clean up.
  let identity =
    auth.with_account_deletion(identity, fn(_repo, _user) { Ok(Nil) })
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
    app(identity, permissions)
    |> howdy.bind(to: "127.0.0.1")
    |> howdy.start()
  process.sleep_forever()
}

// Read credentials at startup, never from requests or source-controlled values.
@external(erlang, "howdy_auth_example_ffi", "google_credentials")
fn google_credentials() -> option.Option(#(String, String))

@external(erlang, "howdy_auth_example_ffi", "mfa_key")
fn mfa_key() -> option.Option(String)
