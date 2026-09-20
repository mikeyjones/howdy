import database
import gleam/erlang/process
import gleam/io
import howdy
import howdy/auth
import howdy/auth/pages
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
  let identity = auth.allow_registration(identity)
  let assert Ok(identity) = auth.with_passwords(identity)
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
