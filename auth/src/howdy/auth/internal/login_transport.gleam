//// MFA-aware cookie and bearer transport shared by login routes.

import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import howdy/auth
import howdy/auth/internal/security_store
import howdy/auth/secret
import howdy/auth/user
import howdy/controller
import howdy/cookie
import howdy/service

pub fn pending_cookie(identity: auth.Auth) -> String {
  case auth.secure(identity) {
    True -> "__Host-howdy_mfa"
    False -> "howdy_dev_mfa"
  }
}

pub fn trusted_cookie(identity: auth.Auth) -> String {
  case auth.secure(identity) {
    True -> "__Host-howdy_trusted"
    False -> "howdy_dev_trusted"
  }
}

pub fn options(identity: auth.Auth) -> cookie.Options {
  cookie.defaults() |> cookie.secure(auth.secure(identity))
}

pub fn challenge(
  identity: auth.Auth,
  ctx: controller.Context,
) -> service.Result(String) {
  case auth.check_origin(identity, ctx) {
    Error(e) -> Error(e)
    Ok(_) -> unique_cookie(ctx, pending_cookie(identity))
  }
}

fn unique_cookie(
  ctx: controller.Context,
  name: String,
) -> service.Result(String) {
  case
    list.filter(request.get_cookies(ctx.request), fn(pair) { pair.0 == name })
  {
    [#(_, value)] -> Ok(value)
    _ -> Error(service.Unauthorized)
  }
}

/// The second element finishes the response: when device trust renews on use,
/// it re-sets the device cookie so the browser keeps it as long as the server.
pub fn try_trusted(
  identity: auth.Auth,
  ctx: controller.Context,
  challenge: auth.MfaChallenge,
) {
  case unique_cookie(ctx, trusted_cookie(identity)) {
    Ok(device) ->
      case
        auth.use_trusted_device(
          identity,
          secret.reveal(challenge.token),
          device,
        )
      {
        Ok(session) -> #(auth.SignedIn(session), fn(res) {
          case auth.mfa_trust_renewal(identity) {
            True ->
              cookie.set(
                res,
                trusted_cookie(identity),
                device,
                options(identity)
                  |> cookie.max_age(auth.mfa_trust_seconds(identity)),
              )
            False -> res
          }
        })
        Error(_) -> #(auth.SecondFactor(challenge), fn(res) { res })
      }
    Error(_) -> #(auth.SecondFactor(challenge), fn(res) { res })
  }
}

pub fn pending(identity: auth.Auth, res, challenge: auth.MfaChallenge) {
  res
  |> cookie.set(
    pending_cookie(identity),
    secret.reveal(challenge.token),
    options(identity) |> cookie.max_age(security_store.challenge_seconds),
  )
  |> cookie.delete(auth.cookie_name(identity), options(identity))
}

pub fn browser(
  identity: auth.Auth,
  ctx: controller.Context,
  answer: service.Result(auth.LoginStep),
  required,
) {
  let #(answer, remembered) = case answer {
    Ok(auth.SecondFactor(challenge)) -> {
      let #(step, remembered) = try_trusted(identity, ctx, challenge)
      #(Ok(step), remembered)
    }
    other -> #(other, fn(res) { res })
  }
  case answer {
    Error(error) -> service.error_response(ctx, error)
    Ok(step) -> {
      case required(ctx) {
        Ok(principal) -> {
          let _ = auth.logout(identity, principal)
          Nil
        }
        Error(_) -> Nil
      }
      case step {
        auth.SignedIn(session) ->
          controller.json(ctx, user_json(session))
          |> cookie.set(
            auth.cookie_name(identity),
            secret.reveal(session.token),
            options(identity)
              |> cookie.max_age(auth.session_cookie_seconds(identity)),
          )
          |> cookie.delete(pending_cookie(identity), options(identity))
          |> remembered
        auth.SecondFactor(challenge) ->
          pending(
            identity,
            controller.json(
              ctx,
              json.object([#("mfa_required", json.bool(True))]),
            )
              |> controller.with_status(202),
            challenge,
          )
      }
    }
  }
}

fn user_json(session: auth.Session) {
  user.to_json(session.user)
}

pub fn bearer(
  identity: auth.Auth,
  ctx,
  answer: service.Result(auth.LoginStep),
) {
  case answer {
    Error(error) -> service.error_response(ctx, error)
    Ok(auth.SignedIn(session)) ->
      controller.json(ctx, token_json(identity, session))
    Ok(auth.SecondFactor(challenge)) ->
      controller.json(
        ctx,
        json.object([
          #("mfa_required", json.bool(True)),
          #("mfa_token", json.string(secret.reveal(challenge.token))),
        ]),
      )
      |> controller.with_status(202)
  }
}

pub fn token_json(identity: auth.Auth, session: auth.Session) -> json.Json {
  json.object([
    #("access_token", json.string(secret.reveal(session.token))),
    #("token_type", json.string("Bearer")),
    #("expires_in", json.int(auth.policy(identity).session_seconds)),
    #("user", user.to_json(session.user)),
  ])
}

pub fn completed(
  identity: auth.Auth,
  ctx,
  answer: service.Result(auth.MfaSession),
  required,
) {
  case answer {
    Error(error) -> service.error_response(ctx, error)
    Ok(completed) -> {
      let res =
        browser(identity, ctx, Ok(auth.SignedIn(completed.session)), required)
      case completed.trusted_device {
        None -> res
        Some(device) ->
          res
          |> cookie.set(
            trusted_cookie(identity),
            secret.reveal(device),
            options(identity)
              |> cookie.max_age(auth.mfa_trust_seconds(identity)),
          )
      }
    }
  }
}
