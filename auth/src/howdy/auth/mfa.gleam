//// Optional second-factor configuration. Keep the encryption key outside the
//// auth database; all nodes must use the same stable, 32-byte base64url key.

import gleam/bit_array
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import howdy/auth/secret
import howdy/auth/user.{type User}
import howdy/service

pub opaque type Config {
  Config(
    issuer: String,
    key: secret.Secret,
    deliver: Option(fn(User, secret.Secret) -> Result(Nil, Nil)),
  )
}

pub fn new(issuer: String, encryption_key: String) -> service.Result(Config) {
  use key <- result.try(
    bit_array.base64_url_decode(encryption_key)
    |> result.replace_error(service.Invalid(
      "MFA encryption key must be 32 random bytes encoded as base64url",
    )),
  )
  case bit_array.byte_size(key) == 32 {
    False ->
      Error(service.Invalid(
        "MFA encryption key must be 32 random bytes encoded as base64url",
      ))
    True ->
      case string.trim(issuer) != "" && string.byte_size(issuer) <= 128 {
        True -> Ok(Config(issuer, secret.wrap(encryption_key), None))
        False ->
          Error(service.Invalid("MFA issuer must contain 1 to 128 bytes"))
      }
  }
}

/// Deliver to a separately verified channel owned by this user. The application
/// chooses the address/phone; never take the destination from the login request.
/// An email-token login cannot use delivered OTP as its second factor.
pub fn with_delivery(
  config: Config,
  deliver: fn(User, secret.Secret) -> Result(Nil, Nil),
) -> Config {
  Config(..config, deliver: Some(deliver))
}

@internal
pub fn issuer(config: Config) -> String {
  config.issuer
}

@internal
pub fn can_deliver(config: Config) -> Bool {
  option.is_some(config.deliver)
}

@internal
pub fn deliver(
  config: Config,
  user: User,
  code: secret.Secret,
) -> service.Result(Nil) {
  case config.deliver {
    Some(send) ->
      send(user, code)
      |> result.replace_error(service.Internal("MFA code delivery failed"))
    None -> Error(service.Forbidden)
  }
}

@external(erlang, "howdy_auth_mfa_ffi", "new_secret")
@internal
pub fn new_secret() -> String

@external(erlang, "howdy_auth_mfa_ffi", "otp")
@internal
pub fn otp() -> String

@external(erlang, "howdy_auth_mfa_ffi", "backup")
@internal
pub fn backup() -> String

@external(erlang, "howdy_auth_mfa_ffi", "seal")
fn encrypt(key: String, owner: String, value: String) -> Result(String, Nil)

@external(erlang, "howdy_auth_mfa_ffi", "open")
fn decrypt(key: String, owner: String, value: String) -> Result(String, Nil)

@external(erlang, "howdy_auth_mfa_ffi", "verify_totp")
@internal
pub fn verify_totp(
  seed: String,
  code: String,
  after: Int,
  now: Int,
) -> Result(Int, Nil)

@internal
pub fn seal(
  config: Config,
  user_id: String,
  value: String,
) -> service.Result(String) {
  encrypt(secret.reveal(config.key), user_id, value)
  |> result.replace_error(service.Internal("MFA encryption failed"))
}

@internal
pub fn open(
  config: Config,
  user_id: String,
  value: String,
) -> service.Result(String) {
  decrypt(secret.reveal(config.key), user_id, value)
  |> result.replace_error(service.Internal("MFA secret could not be decrypted"))
}
