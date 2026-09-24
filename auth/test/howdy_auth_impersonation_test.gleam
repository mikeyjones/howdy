//// Operator tooling: listing users, reading suspension, and issuing a
//// session for a user without a credential.

import gleam/list
import howdy/auth
import howdy/auth/secret
import howdy/auth/user
import howdy/auth/users
import howdy/service
import support.{count, fixture, signup}

pub fn impersonation_issues_an_audited_session_test() {
  use database, identity, _, mailbox <- fixture
  let ada = signup(identity, mailbox, "ada@example.com")
  let assert Ok(session) =
    auth.impersonate(identity, ada.user.id, by: user.SystemFrom("admin"))
  assert session.user.id == ada.user.id
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  assert principal.user.email == "ada@example.com"
  let assert Ok(listed) = auth.sessions(identity, principal)
  let assert [current] = list.filter(listed, fn(s) { s.current })
  assert current.method == auth.Impersonation
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'session.impersonated' AND client = 'admin'",
    )
    == 1
}

pub fn impersonation_refuses_unknown_and_suspended_users_test() {
  use _, identity, _, mailbox <- fixture
  let ada = signup(identity, mailbox, "ada@example.com")
  assert auth.impersonate(identity, "nobody", by: user.System)
    == Error(service.NotFound("user"))
  let assert Ok(Nil) = auth.suspend(identity, ada.user.id, by: user.System)
  assert auth.impersonate(identity, ada.user.id, by: user.System)
    == Error(service.NotFound("user"))
}

pub fn users_are_listed_with_their_suspension_test() {
  use _, identity, _, mailbox <- fixture
  let grace = signup(identity, mailbox, "grace@example.com")
  let ada = signup(identity, mailbox, "ada@example.com")
  let assert Ok(listed) = users.list(identity)
  assert list.map(listed, fn(u) { u.email })
    == ["ada@example.com", "grace@example.com"]
  assert users.suspended(identity, ada.user.id) == Ok(False)
  let assert Ok(Nil) = auth.suspend(identity, grace.user.id, by: user.System)
  assert users.suspended(identity, grace.user.id) == Ok(True)
  assert users.suspended(identity, "nobody") == Error(service.NotFound("user"))
}
