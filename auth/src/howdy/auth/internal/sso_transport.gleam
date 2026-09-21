//// Outbound requests to a customer's identity provider. Unlike the built-in
//// providers, the URL is configuration a customer supplied, so it is treated
//// as hostile: HTTPS only, public addresses only, no redirects followed.

import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/option.{None}
import gleam/result
import howdy/service

pub type Send =
  fn(Request(String)) -> service.Result(Response(String))

@external(erlang, "howdy_auth_sso_ffi", "public_host")
fn public_host(host: String) -> Bool

// Catch transport exceptions as well as ordinary errors: some OTP socket/TLS
// errors are not represented by gleam_httpc's error type. Never log requests.
@external(erlang, "howdy_auth_oidc_ffi", "protect")
fn protect(
  run: fn() -> service.Result(Response(String)),
  message: String,
) -> service.Result(Response(String))

pub fn send(req: Request(String)) -> service.Result(Response(String)) {
  let failed = "SSO provider request failed"
  case req.scheme == http.Https && req.port == None && public_host(req.host) {
    False -> Error(service.Internal(failed))
    True ->
      protect(
        fn() {
          httpc.configure()
          |> httpc.timeout(10_000)
          |> httpc.follow_redirects(False)
          |> httpc.dispatch(req)
          |> result.replace_error(service.Internal(failed))
        },
        failed,
      )
  }
}
