//// Browser transport for providers; the headless flow lives in auth.

import gleam/http/response
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import howdy/auth.{type Auth}
import howdy/auth/internal/login_transport
import howdy/auth/secret
import howdy/controller
import howdy/cookie
import howdy/guard
import howdy/middleware
import howdy/query
import howdy/rate_limit
import howdy/service

pub fn routes(
  identity: Auth,
  prefix: String,
  success: String,
  failure: String,
  key: fn(controller.Context) -> Option(String),
) -> controller.Controller {
  let assert True =
    auth.provider_path(prefix)
    && !string.ends_with(prefix, "/")
    && auth.provider_path(success)
    && auth.provider_path(failure)
    as "provider routes require local paths without queries or fragments"
  let limited =
    rate_limit.by(rate_limit.fixed_window(limit: 30, per_seconds: 60), key)
  let wrap = middleware.wrap(_, limited)
  let routes =
    controller.new(prefix)
    |> controller.middleware(fn(ctx, next) {
      next(ctx)
      |> response.set_header("cache-control", "no-store")
      |> response.set_header("referrer-policy", "no-referrer")
      |> response.set_header("x-content-type-options", "nosniff")
    })
  list.fold(auth.providers(identity), routes, fn(routes, provider) {
    let #(id, _) = provider
    let path = "/providers/" <> id
    let callback = prefix <> path <> "/callback"
    routes
    |> controller.post(
      path <> "/login",
      wrap(fn(ctx) {
        use _ <- guard.require(ctx, fn(ctx) { auth.check_origin(identity, ctx) })
        use group <- query.optional_string(ctx, "group")
        let scoped = case auth.bound_group(identity), group {
          None, Some(g) -> auth.in_group(identity, g)
          _, _ -> identity
        }
        start(
          ctx,
          identity,
          id,
          auth.begin_provider(scoped, id, callback, option.unwrap(key(ctx), "")),
        )
      }),
    )
    |> controller.post(
      path <> "/link",
      wrap(fn(ctx) {
        use _ <- guard.require(ctx, fn(ctx) { auth.check_origin(identity, ctx) })
        use principal <- guard.require(ctx, auth.required_from(identity, key))
        start(
          ctx,
          identity,
          id,
          auth.begin_provider_link(identity, principal, id, callback),
        )
      }),
    )
    |> controller.get(
      path <> "/callback",
      wrap(fn(ctx) {
        use state <- query.string(ctx, "state")
        use code <- query.optional_string(ctx, "code")
        use error <- query.optional_string(ctx, "error")
        use browser <- cookie.optional_string(ctx, cookie_name(identity, id))
        let principal =
          auth.required_from(identity, key)(ctx) |> option.from_result
        let code = case error {
          Some(_) -> None
          None -> code
        }
        let completed =
          auth.finish_provider(
            identity,
            id,
            callback,
            state,
            option.unwrap(browser, ""),
            code,
            principal,
          )
        let res = case completed {
          Ok(auth.ProviderSession(session)) -> {
            // Rotate an existing local session when switching accounts.
            case principal {
              Some(p) -> {
                let _ = auth.logout(identity, p)
                Nil
              }
              None -> Nil
            }
            redirect(ctx, success)
            |> cookie.set(
              auth.cookie_name(identity),
              secret.reveal(session.token),
              options(identity)
                |> cookie.max_age(auth.policy(identity).session_seconds),
            )
          }
          Ok(auth.ProviderSecondFactor(challenge)) -> {
            case principal {
              Some(p) -> {
                let _ = auth.logout(identity, p)
                Nil
              }
              None -> Nil
            }
            case login_transport.try_trusted(identity, ctx, challenge) {
              auth.SignedIn(session) ->
                redirect(ctx, success)
                |> cookie.set(
                  auth.cookie_name(identity),
                  secret.reveal(session.token),
                  options(identity)
                    |> cookie.max_age(auth.policy(identity).session_seconds),
                )
              auth.SecondFactor(challenge) ->
                login_transport.pending(
                  identity,
                  redirect(ctx, prefix <> "/mfa"),
                  challenge,
                )
            }
          }
          Ok(auth.ProviderLinked) -> redirect(ctx, success)
          Error(_) -> redirect(ctx, failure)
        }
        res |> cookie.delete(cookie_name(identity, id), options(identity))
      }),
    )
  })
}

fn start(ctx, identity, id, started: service.Result(auth.ProviderStart)) {
  case started {
    Error(error) -> service.error_response(ctx, error)
    Ok(start) ->
      redirect(ctx, start.url)
      |> cookie.set(
        cookie_name(identity, id),
        secret.reveal(start.browser_token),
        options(identity) |> cookie.max_age(600),
      )
  }
}

fn redirect(ctx, location) {
  controller.status(ctx, 303) |> response.set_header("location", location)
}

fn options(identity) {
  cookie.defaults() |> cookie.secure(auth.secure(identity))
}

fn cookie_name(identity, id) {
  case auth.secure(identity) {
    True -> "__Host-howdy_provider_"
    False -> "howdy_dev_provider_"
  }
  <> id
}
