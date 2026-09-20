//// Sessions kept outside the database, and provisioning users.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import howdy/auth
import howdy/auth/group
import howdy/auth/groups
import howdy/auth/internal/token
import howdy/auth/policy
import howdy/auth/secret
import howdy/auth/session_store.{type SessionStore, Entry, SessionStore}
import howdy/auth/user
import howdy/service
import support.{count, fixture, signup}

const strong_password = "an uncommon orchard phrase 947!"

fn sign_in(
  identity: auth.Auth,
  mailbox: process.Subject(auth.Delivery),
  email: String,
) {
  let assert Ok(Nil) = auth.request_token(identity, email, auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  session
}

/// A store whose removals fail, as when the backend is unreachable.
fn unable_to_remove(store: SessionStore) -> SessionStore {
  let down = fn() { Error(service.Internal("store is down")) }
  SessionStore(..store, delete: fn(_, _) { down() }, delete_for_user: fn(_, _) {
    down()
  })
}

pub fn the_memory_store_meets_the_contract_and_check_catches_a_broken_one_test() {
  let store = session_store.memory()
  assert session_store.check(store) == Ok(Nil)
  let forgetful = SessionStore(..store, touch: fn(_, _) { Ok(Nil) })
  assert session_store.check(forgetful)
    == Error("touch must change last_seen_at and nothing else")
  let careless =
    SessionStore(..store, delete: fn(digest, _) {
      store.delete(digest, "howdy-check-bob")
    })
  assert session_store.check(careless)
    == Error("delete must not remove another user's record")
  assert session_store.check(unable_to_remove(store))
    == Error("delete_for_user returned an error")
}

pub fn sessions_live_in_the_store_and_never_in_the_database_test() {
  use database, identity, _, mailbox <- fixture
  let store = session_store.memory()
  let identity = auth.with_session_store(identity, store)
  let first = signup(identity, mailbox, "ada@example.com")
  let second = sign_in(identity, mailbox, "ada@example.com")
  let bob = signup(identity, mailbox, "bob@example.com")
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_sessions") == 0
  // The store is keyed by digest and never holds the token.
  let assert Ok(None) = store.get(secret.reveal(first.token))
  let assert Ok(Some(entry)) =
    store.get(token.digest(secret.reveal(first.token)))
  assert entry.user_id == first.user.id
  assert entry.method == "email"
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(second.token))
  assert principal.user == first.user
  let assert Ok(listed) = auth.sessions(identity, principal)
  assert list.length(listed) == 2
  assert list.count(listed, fn(s) { s.current }) == 1
  // Another user's session id does nothing; one's own revokes.
  let assert Ok(bobs) = auth.authenticate(identity, secret.reveal(bob.token))
  assert auth.revoke_session(identity, principal, bobs.session_id) == Ok(Nil)
  let assert Ok(_) = auth.authenticate(identity, secret.reveal(bob.token))
  let assert [other] = list.filter(listed, fn(s) { !s.current })
  assert auth.revoke_session(identity, principal, other.id) == Ok(Nil)
  assert auth.authenticate(identity, secret.reveal(first.token))
    == Error(service.Unauthorized)
  assert auth.logout(identity, principal) == Ok(Nil)
  assert auth.authenticate(identity, secret.reveal(second.token))
    == Error(service.Unauthorized)
  // A database session means nothing once the store is elsewhere, and back.
  let assert Ok(database_only) =
    auth.new(database, "https://example.test", fn(_) { Ok(Nil) })
  assert auth.authenticate(database_only, secret.reveal(bob.token))
    == Error(service.Unauthorized)
}

pub fn expiry_idleness_and_pruning_are_enforced_by_the_package_test() {
  use _, identity, _, mailbox <- fixture
  let store = session_store.memory()
  let identity = auth.with_session_store(identity, store)
  let ada = signup(identity, mailbox, "ada@example.com")
  let now = token.now()
  let entry = fn(secret, last_seen_at, expires_at) {
    Entry(
      digest: token.digest(secret),
      user_id: ada.user.id,
      method: "email",
      created_at: now - 10_000,
      last_seen_at:,
      expires_at:,
      client: "",
    )
  }
  let expired = token.new()
  let idle = token.new()
  let quiet = token.new()
  let assert Ok(Nil) = store.insert(entry(expired, now, now - 1))
  let assert Ok(Nil) = store.insert(entry(idle, now - 5000, now + 9000))
  let assert Ok(Nil) = store.insert(entry(quiet, now - 120, now + 9000))
  assert auth.authenticate(identity, expired) == Error(service.Unauthorized)
  let assert Ok(limited) =
    auth.with_policy(
      identity,
      policy.Policy(..auth.policy(identity), session_idle_seconds: 3600),
    )
  assert auth.authenticate(limited, idle) == Error(service.Unauthorized)
  // Use is recorded in the store.
  let assert Ok(_) = auth.authenticate(limited, quiet)
  let assert Ok(Some(touched)) = store.get(token.digest(quiet))
  assert touched.last_seen_at >= now
  assert auth.prune_expired(identity) == Ok(Nil)
  assert store.get(token.digest(expired)) == Ok(None)
  let assert Ok(principal) = auth.authenticate(identity, quiet)
  let assert Ok(listed) = auth.sessions(identity, principal)
  assert list.length(listed) == 3
}

pub fn passwords_need_a_fresh_email_session_and_revoke_the_rest_test() {
  use _, identity, _, mailbox <- fixture
  let store = session_store.memory()
  let assert Ok(identity) = auth.with_passwords(identity)
  let identity = auth.with_session_store(identity, store)
  let old = signup(identity, mailbox, "ada@example.com")
  let fresh = sign_in(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(fresh.token))
  assert auth.set_password(identity, principal, strong_password) == Ok(Nil)
  assert auth.authenticate(identity, secret.reveal(old.token))
    == Error(service.Unauthorized)
  let assert Ok(by_password) =
    auth.login_password(identity, "ada@example.com", strong_password)
  let assert Ok(weaker) =
    auth.authenticate(identity, secret.reveal(by_password.token))
  assert auth.set_password(identity, weaker, strong_password <> "!")
    == Error(service.Forbidden)
  // Freshness is read from the store's record.
  let assert Ok(Some(entry)) = store.get(principal.session_id)
  let assert Ok(Nil) = store.insert(Entry(..entry, created_at: 0))
  assert auth.set_password(identity, principal, strong_password <> "!")
    == Error(service.Forbidden)
}

pub fn suspension_holds_even_when_the_store_cannot_revoke_test() {
  use _, identity, _, mailbox <- fixture
  let store = session_store.memory()
  let working = auth.with_session_store(identity, store)
  let failing = auth.with_session_store(identity, unable_to_remove(store))
  let ada = signup(working, mailbox, "ada@example.com")
  let secret = secret.reveal(ada.token)
  // The database committed; the caller is told the store did not follow.
  let assert Error(service.Internal(_)) =
    auth.suspend(failing, ada.user.id, by: user.System)
  let assert Ok(Some(_)) = store.get(token.digest(secret))
  assert auth.authenticate(working, secret) == Error(service.Unauthorized)
  // Resuming must not revive it: it refuses until the store can be cleared.
  let assert Error(service.Internal(_)) =
    auth.resume(failing, ada.user.id, by: user.System)
  assert auth.resume(working, ada.user.id, by: user.System) == Ok(Nil)
  assert auth.authenticate(working, secret) == Error(service.Unauthorized)
  let again = sign_in(working, mailbox, "ada@example.com")
  assert auth.revoke_sessions(working, ada.user.id, by: user.System) == Ok(Nil)
  assert auth.authenticate(working, secret.reveal(again.token))
    == Error(service.Unauthorized)
  // A store that cannot take the session fails the sign-in.
  let full =
    SessionStore(..store, insert: fn(_) { Error(service.Internal("full")) })
  let assert Ok(Nil) =
    auth.request_token(working, "ada@example.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Error(service.Internal(_)) =
    auth.exchange(
      auth.with_session_store(identity, full),
      secret.reveal(delivery.token),
    )
}

pub fn provisioning_creates_users_without_public_registration_test() {
  use database, _, _, mailbox <- fixture
  let assert Ok(closed) =
    auth.new(database, "https://example.test", fn(delivery) {
      process.send(mailbox, delivery)
      Ok(Nil)
    })
  assert auth.registration_enabled(closed) == False
  let assert Ok(ada) =
    auth.provision(closed, " ADA@Example.com ", by: user.System)
  assert ada == user.User(ada.id, "ada@example.com", group.default_id)
  let assert Error(service.Conflict(_)) =
    auth.provision(closed, "ada@example.com", by: user.System)
  let assert Error(service.Invalid(_)) =
    auth.provision(closed, "not an address", by: user.System)
  // Nothing was sent; the user signs in when they are ready.
  assert process.receive(mailbox, 0) == Error(Nil)
  let session = sign_in(closed, mailbox, "ada@example.com")
  assert session.user == ada
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'user.provisioned'",
    )
    == 1
}

pub fn provisioning_follows_the_group_mode_test() {
  use _, identity, _, _ <- fixture
  let assert Ok(identity) = auth.with_groups(identity, group.AccountPerGroup)
  let by = user.System
  let assert Ok(_) = groups.create_with_id(identity, id: "acme", name: "A", by:)
  let assert Ok(_) =
    groups.create_with_id(identity, id: "globex", name: "G", by:)
  let assert Error(service.Invalid(_)) =
    auth.provision(identity, "ada@example.com", by:)
  assert auth.provision(
      auth.in_group(identity, "missing"),
      "ada@example.com",
      by:,
    )
    == Error(service.NotFound("group"))
  let assert Ok(first) =
    auth.provision(auth.in_group(identity, "acme"), "ada@example.com", by:)
  let assert Ok(second) =
    auth.provision(auth.in_group(identity, "globex"), "ada@example.com", by:)
  assert first.id != second.id
  assert second.group_id == "globex"
  let assert Error(service.Conflict(_)) =
    auth.provision(auth.in_group(identity, "acme"), "ada@example.com", by:)
  // One account per address everywhere once the mode says so.
  let assert Error(service.Conflict(_)) =
    auth.with_groups(identity, group.OneGroupPerUser)
}
