//// Password registration, login and storage.

import argus
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import gloo/repo
import howdy/auth
import howdy/auth/internal/token as auth_token
import howdy/auth/secret
import howdy/auth/user
import howdy/service
import howdy/testing
import support.{app, count, exec, fixture, signup}

// Registering with a password cannot be answered from the inbox, so that path
// keeps its own per-address cooldown, and the cooldown doubles.
pub fn password_registration_cooldown_is_persistent_and_doubles_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let assert Ok(Nil) =
    auth.register_password(identity, "new@example.com", strong_password)
  let assert Ok(_) = process.receive(mailbox, 1000)
  let assert Error(service.TooManyRequests(wait)) =
    auth.register_password(identity, "NEW@example.com", strong_password)
  assert wait > 0 && wait <= 60
  assert process.receive(mailbox, 0) == Error(Nil)
  exec(
    database,
    "UPDATE howdy_auth_throttles SET next_at = "
      <> int.to_string(auth_token.now()),
  )
  let assert Ok(Nil) =
    auth.register_password(identity, "new@example.com", strong_password)
  let assert Error(service.TooManyRequests(wait)) =
    auth.register_password(identity, "new@example.com", strong_password)
  assert wait > 60 && wait <= 120
  exec(database, "UPDATE howdy_auth_throttles SET next_at = 0")
  let assert Ok(Nil) =
    auth.register_password(identity, "new@example.com", strong_password)
  let assert Error(service.TooManyRequests(wait)) =
    auth.register_password(identity, "new@example.com", strong_password)
  assert wait <= 60
}

const strong_password = "an uncommon orchard phrase 947!"

fn password_signup(
  identity: auth.Auth,
  mailbox: process.Subject(auth.Delivery),
  email: String,
  password: String,
) {
  let assert Ok(Nil) = auth.register_password(identity, email, password)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  session
}

pub fn password_registration_requires_email_and_stores_argon2id_only_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let assert Ok(Nil) =
    auth.register_password(identity, "ada@example.com", strong_password)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 0
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_passwords") == 0
  let assert Ok([encoded]) =
    repo.all(
      database,
      "SELECT password_hash FROM howdy_auth_challenges",
      [],
      decode.field(0, decode.string, decode.success),
    )
  assert string.starts_with(encoded, "$argon2id$v=19$m=19456,t=2,p=1$")
  assert !string.contains(encoded, strong_password)
  assert argus.verify(encoded, strong_password) == Ok(True)
  assert auth.login_password(identity, "ada@example.com", strong_password)
    == Error(service.Unauthorized)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  let assert Ok([stored]) =
    repo.all(
      database,
      "SELECT encoded_hash FROM howdy_auth_passwords",
      [],
      decode.field(0, decode.string, decode.success),
    )
  assert stored == encoded
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_challenges") == 0
  let assert Ok(login) =
    auth.login_password(identity, " ADA@example.com ", strong_password)
  assert login.user == session.user
  assert secret.reveal(login.token) != secret.reveal(session.token)
  assert auth.login_password(identity, "ada@example.com", "wrong password")
    == Error(service.Unauthorized)
  let second =
    password_signup(identity, mailbox, "other@example.com", strong_password)
  let assert Ok(hashes) =
    repo.all(
      database,
      "SELECT encoded_hash FROM howdy_auth_passwords",
      [],
      decode.field(0, decode.string, decode.success),
    )
  assert list.length(list.unique(hashes)) == 2
  assert second.user.id != session.user.id
}

pub fn password_method_and_registration_are_explicitly_enabled_test() {
  use database, identity, permissions, mailbox <- fixture
  assert auth.register_password(identity, "ada@example.com", strong_password)
    == Error(service.Forbidden)
  assert auth.login_password(identity, "ada@example.com", strong_password)
    == Error(service.Forbidden)
  assert testing.get("/auth/password/login")
    |> testing.send(app(identity, permissions))
    |> fn(r) { r.status }
    == 404
  let assert Ok(enabled) = auth.with_passwords(identity)
  let assert Ok(Nil) =
    auth.register_password(enabled, "ada@example.com", strong_password)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert auth.exchange(identity, secret.reveal(delivery.token))
    == Error(service.Forbidden)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 0
  let assert Ok(closed) =
    auth.new(database, "https://example.test", fn(_) { Ok(Nil) })
  let assert Ok(closed) = auth.with_passwords(closed)
  assert auth.register_password(closed, "other@example.com", strong_password)
    == Error(service.Forbidden)
}

pub fn password_policy_and_exact_input_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let assert Error(service.Invalid(_)) =
    auth.register_password(identity, "short@example.com", "short")
  let assert Error(service.Invalid(_)) =
    auth.register_password(
      identity,
      "large@example.com",
      string.repeat("a", 1025),
    )
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_challenges") == 0
  let exact = "  a long passphrase with spaces  "
  let _ = password_signup(identity, mailbox, "ada@example.com", exact)
  let assert Ok(_) = auth.login_password(identity, "ada@example.com", exact)
  assert auth.login_password(identity, "ada@example.com", string.trim(exact))
    == Error(service.Unauthorized)
  assert auth.login_password(
      identity,
      "ada@example.com",
      string.repeat("a", 1025),
    )
    == Error(service.Unauthorized)
}

pub fn password_registration_never_overwrites_existing_credentials_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let first =
    password_signup(identity, mailbox, "ada@example.com", strong_password)
  exec(database, "DELETE FROM howdy_auth_throttles")
  let assert Ok(Nil) =
    auth.register_password(
      identity,
      "ada@example.com",
      "a totally different password",
    )
  // The address already has an account, so the password in that request is
  // discarded and the token only offers to sign the account in.
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert delivery.purpose == auth.AlreadyRegistered
  let assert Ok(signed_in) =
    auth.exchange(identity, secret.reveal(delivery.token))
  assert signed_in.user.id == first.user.id
  let assert Ok(session) =
    auth.login_password(identity, "ada@example.com", strong_password)
  assert session.user.id == first.user.id
  assert auth.login_password(
      identity,
      "ada@example.com",
      "a totally different password",
    )
    == Error(service.Unauthorized)
  // The same holds for an account that has never had a password: registering
  // one for it does not attach the credential.
  let _ = signup(identity, mailbox, "email-only@example.com")
  exec(database, "DELETE FROM howdy_auth_throttles")
  let assert Ok(Nil) =
    auth.register_password(identity, "email-only@example.com", strong_password)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert delivery.purpose == auth.AlreadyRegistered
  let assert Ok(_) = auth.exchange(identity, secret.reveal(delivery.token))
  assert auth.login_password(
      identity,
      "email-only@example.com",
      strong_password,
    )
    == Error(service.Unauthorized)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_passwords") == 1
}

pub fn password_login_is_throttled_and_suspension_is_enforced_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let session =
    password_signup(identity, mailbox, "ada@example.com", strong_password)
  list.each(list.repeat(Nil, 5), fn(_) {
    assert auth.login_password(identity, "ada@example.com", "wrong")
      == Error(service.Unauthorized)
  })
  let assert Error(service.TooManyRequests(wait)) =
    auth.login_password(identity, "ADA@example.com", strong_password)
  assert wait > 0 && wait <= 60
  exec(database, "UPDATE howdy_auth_password_attempts SET window_start = 0")
  exec(database, "UPDATE howdy_auth_password_clients SET next_at = 0")
  let assert Ok(_) =
    auth.login_password(identity, "ada@example.com", strong_password)
  let assert Ok(Nil) = auth.suspend(identity, session.user.id, by: user.System)
  assert auth.login_password(identity, "ada@example.com", strong_password)
    == Error(service.Unauthorized)
  assert auth.authenticate(identity, secret.reveal(session.token))
    == Error(service.Unauthorized)
  assert auth.login_password(identity, "missing@example.com", strong_password)
    == Error(service.Unauthorized)
}

pub fn password_corrupt_hash_fails_closed_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let _ = password_signup(identity, mailbox, "ada@example.com", strong_password)
  exec(database, "UPDATE howdy_auth_passwords SET encoded_hash = 'invalid'")
  let assert Error(service.Internal(_)) =
    auth.login_password(identity, "ada@example.com", strong_password)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_sessions") == 1
}

// Independent known-answer vector generated with system libargon2's
// argon2id_hash_encoded(2, 19456, 1, password, salt, 32, ...), version 0x13.
// Tests the actual hash bytes, not just the encoded version label.
pub fn argus_matches_standard_argon2id_test() {
  let strong_password = "correct horse battery staple"
  let hasher =
    argus.hasher()
    |> argus.algorithm(argus.Argon2id)
    |> argus.memory_cost(19_456)
    |> argus.time_cost(2)
    |> argus.parallelism(1)
    |> argus.hash_length(32)
  let assert Ok(salt) = argus.make_salt(<<"howdy-test-salt!":utf8>>)
  assert argus.derive_encryption_key(hasher, strong_password, salt)
    == Ok(<<
      188,
      83,
      152,
      155,
      145,
      169,
      114,
      183,
      168,
      193,
      23,
      166,
      183,
      253,
      237,
      200,
      199,
      244,
      55,
      120,
      139,
      105,
      162,
      87,
      7,
      48,
      64,
      240,
      176,
      154,
      105,
      115,
    >>)
  assert argus.verify(
      "$argon2id$v=19$m=19456,t=2,p=1$aG93ZHktdGVzdC1zYWx0IQ$vFOYm5GpcreowRemt/3tyMf0N3iLaaJXBzBA8LCaaXM",
      strong_password,
    )
    == Ok(True)
}
