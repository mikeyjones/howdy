//// JSON endpoints for custom pages and API clients. Mount once at startup.

import howdy/auth/secret

import gleam/dynamic/decode
import gleam/http
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/string
import howdy/auth.{type Auth}
import howdy/auth/user
import howdy/body
import howdy/context
import howdy/controller
import howdy/cookie
import howdy/guard
import howdy/middleware
import howdy/rate_limit
import howdy/service

/// POST /login and /register deliver email tokens; POST /session exchanges
/// for a browser cookie; POST /token exchanges for a bearer token.
/// POST /password/register sends verification; /password/session and
/// /password/token authenticate with email/password when enabled.
/// POST /password sets or replaces the caller's password; see
/// `auth.set_password` for the fresh email-token session it requires.
/// The endpoints that take an email address also take an optional `group`
/// id, applied with `auth.in_group`; see `auth.with_groups` for when it is
/// needed. It is the client's claim about where it wants to sign in, not
/// proof of membership: `principal.user.group_id` is the group to trust.
/// GET /me, GET /sessions, POST /sessions/revoke and POST /logout accept either
/// transport, never both together. Cookie writes require Origin. Other
/// endpoints allow absent Origin for nonbrowser clients, but reject any
/// foreign/duplicate Origin.
///
/// Clients are rate limited by socket address. Behind a reverse proxy that
/// is the proxy for everyone: use `api_limited_by` there.
pub fn api(identity: Auth, at prefix: String) -> controller.Controller {
  api_limited_by(identity, at: prefix, key: fn(ctx) {
    context.client_ip(ctx.request)
  })
}

/// Requests per client per minute to endpoints that send email, exchange
/// tokens or hash passwords.
pub const credential_limit = 30

/// Requests per client per minute to the signed-in endpoints, which pages
/// call routinely.
pub const session_limit = 300

/// As `api`, identifying clients for rate limiting with `key`. Behind a
/// trusted proxy, read the header it sets:
///
/// ```gleam
/// routes.api_limited_by(identity, at: "/api/auth", key: fn(ctx) {
///   request.get_header(ctx.request, "fly-client-ip") |> option.from_result
/// })
/// ```
///
/// Only use a header your ingress overwrites; a client-supplied value lets
/// anyone choose their own bucket. `None` skips limiting for that request.
pub fn api_limited_by(
  identity: Auth,
  at prefix: String,
  key key: fn(controller.Context) -> Option(String),
) -> controller.Controller {
  let strict =
    rate_limit.by(
      rate_limit.fixed_window(limit: credential_limit, per_seconds: 60),
      key,
    )
  let signed_in =
    rate_limit.by(
      rate_limit.fixed_window(limit: session_limit, per_seconds: 60),
      key,
    )
  let strict = middleware.wrap(_, strict)
  let signed_in = middleware.wrap(_, signed_in)
  // The same identity used for rate limiting is what audit events record.
  let client = fn(ctx) { option.unwrap(key(ctx), "") }
  let required = auth.required_from(identity, key)
  controller.new(prefix)
  |> controller.middleware(fn(ctx, next) {
    let origins =
      list.filter(ctx.request.headers, fn(h) {
        string.lowercase(h.0) == "origin"
      })
    let origin_ok = origins == [] || auth.check_origin(identity, ctx) == Ok(Nil)
    let media_ok = case ctx.request.method {
      http.Post -> {
        case
          list.filter(ctx.request.headers, fn(h) {
            string.lowercase(h.0) == "content-type"
          })
        {
          [#(_, value)] ->
            case string.split(string.lowercase(value), ";") {
              [media, ..] -> string.trim(media) == "application/json"
              _ -> False
            }
          _ -> False
        }
      }
      _ -> True
    }
    let answer = case origin_ok, media_ok {
      False, _ -> service.error_response(ctx, service.Forbidden)
      _, False ->
        service.error_response(
          ctx,
          service.Invalid("expected application/json"),
        )
      True, True -> next(ctx)
    }
    answer
    |> response.set_header("cache-control", "no-store")
    |> response.set_header("referrer-policy", "no-referrer")
    |> response.set_header("x-content-type-options", "nosniff")
  })
  |> controller.post(
    "/login",
    strict(fn(ctx) { request_email(identity, ctx, auth.Login, client(ctx)) }),
  )
  |> controller.post(
    "/register",
    strict(fn(ctx) { request_email(identity, ctx, auth.Register, client(ctx)) }),
  )
  |> controller.post(
    "/session",
    strict(fn(ctx) {
      use _ <- guard.require(ctx, fn(ctx) { auth.check_origin(identity, ctx) })
      use secret <- body.json_with_limit(ctx, body_limit, field("token"))
      browser_session(
        identity,
        ctx,
        auth.exchange_from(identity, secret, client(ctx)),
        required,
      )
    }),
  )
  |> controller.post(
    "/token",
    strict(fn(ctx) {
      use secret <- body.json_with_limit(ctx, body_limit, field("token"))
      auth.exchange_from(identity, secret, client(ctx))
      |> service.respond(ctx, token_json(identity))
    }),
  )
  |> controller.post(
    "/password/register",
    strict(fn(ctx) {
      use credentials <- body.json_with_limit(ctx, body_limit, credentials())
      auth.register_password_from(
        within(identity, credentials.2),
        credentials.0,
        credentials.1,
        client(ctx),
      )
      |> email_response(ctx)
    }),
  )
  |> controller.post(
    "/password/session",
    strict(fn(ctx) {
      use _ <- guard.require(ctx, fn(ctx) { auth.check_origin(identity, ctx) })
      use credentials <- body.json_with_limit(ctx, body_limit, credentials())
      browser_session(
        identity,
        ctx,
        auth.login_password_from(
          within(identity, credentials.2),
          credentials.0,
          credentials.1,
          client(ctx),
        ),
        required,
      )
    }),
  )
  |> controller.post(
    "/password/token",
    strict(fn(ctx) {
      use credentials <- body.json_with_limit(ctx, body_limit, credentials())
      auth.login_password_from(
        within(identity, credentials.2),
        credentials.0,
        credentials.1,
        client(ctx),
      )
      |> service.respond(ctx, token_json(identity))
    }),
  )
  |> controller.post(
    "/password",
    strict(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use password <- body.json_with_limit(ctx, body_limit, field("password"))
      auth.set_password(identity, principal, password)
      |> service.no_content(ctx)
    }),
  )
  |> controller.get(
    "/sessions",
    signed_in(fn(ctx) {
      use principal <- guard.require(ctx, required)
      auth.sessions(identity, principal)
      |> service.respond(ctx, json.array(_, session_json))
    }),
  )
  |> controller.post(
    "/sessions/revoke",
    signed_in(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use id <- body.json_with_limit(ctx, body_limit, field("id"))
      auth.revoke_session(identity, principal, id)
      |> service.no_content(ctx)
    }),
  )
  |> controller.get(
    "/me",
    signed_in(fn(ctx) {
      use principal <- guard.require(ctx, required)
      controller.json(ctx, user.to_json(principal.user))
    }),
  )
  |> controller.post(
    "/logout",
    signed_in(fn(ctx) {
      use principal <- guard.require(ctx, required)
      auth.logout(identity, principal)
      |> service.no_content(ctx)
      |> cookie.delete(auth.cookie_name(identity), options(identity))
    }),
  )
}

/// Request bodies hold an address, a token or a password; nothing larger.
const body_limit = 4096

fn options(identity: Auth) -> cookie.Options {
  cookie.defaults()
  |> cookie.secure(auth.secure(identity))
  |> cookie.max_age(auth.policy(identity).session_seconds)
}

fn field(name: String) -> decode.Decoder(String) {
  decode.field(name, decode.string, decode.success)
}

fn request_email(identity, ctx, intent, client) {
  use #(email, group) <- body.json_with_limit(ctx, body_limit, {
    use email <- decode.field("email", decode.string)
    use group <- decode.then(group())
    decode.success(#(email, group))
  })
  auth.request_token_from(within(identity, group), email, intent, client)
  |> email_response(ctx)
}

fn group() -> decode.Decoder(Option(String)) {
  use group <- decode.optional_field(
    "group",
    option.None,
    decode.optional(decode.string),
  )
  decode.success(group)
}

fn within(identity: Auth, group: Option(String)) -> Auth {
  case group {
    option.Some(id) -> auth.in_group(identity, id)
    option.None -> identity
  }
}

fn email_response(result, ctx) {
  case result {
    Ok(Nil) ->
      controller.json(
        ctx,
        json.object([
          #("message", json.string("Check your email for a sign-in token.")),
        ]),
      )
      |> controller.with_status(202)
    Error(error) -> service.error_response(ctx, error)
  }
}

fn credentials() -> decode.Decoder(#(String, String, Option(String))) {
  use email <- decode.field("email", decode.string)
  use password <- decode.field("password", decode.string)
  use group <- decode.then(group())
  decode.success(#(email, password, group))
}

fn browser_session(
  identity: Auth,
  ctx: controller.Context,
  result: service.Result(auth.Session),
  required: fn(controller.Context) -> service.Result(user.Principal),
) {
  case result {
    Error(error) -> service.error_response(ctx, error)
    Ok(session) -> {
      case required(ctx) {
        Ok(principal) -> {
          let _ = auth.logout(identity, principal)
          Nil
        }
        Error(_) -> Nil
      }
      controller.json(ctx, user.to_json(session.user))
      |> cookie.set(
        auth.cookie_name(identity),
        secret.reveal(session.token),
        options(identity),
      )
    }
  }
}

fn session_json(session: auth.SessionInfo) -> json.Json {
  json.object([
    #("id", json.string(session.id)),
    #(
      "method",
      json.string(case session.method {
        auth.EmailToken -> "email"
        auth.Password -> "password"
      }),
    ),
    #("created_at", json.int(session.created_at)),
    #("last_seen_at", json.int(session.last_seen_at)),
    #("expires_at", json.int(session.expires_at)),
    #("current", json.bool(session.current)),
    #("client", json.string(session.client)),
  ])
}

fn token_json(identity: Auth) -> fn(auth.Session) -> json.Json {
  fn(session: auth.Session) {
    json.object([
      #("access_token", json.string(secret.reveal(session.token))),
      #("token_type", json.string("Bearer")),
      #("expires_in", json.int(auth.policy(identity).session_seconds)),
      #("user", user.to_json(session.user)),
    ])
  }
}
