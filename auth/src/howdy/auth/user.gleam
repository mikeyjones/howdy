//// Application profile data belongs in application tables keyed by user ID.

import gleam/dynamic/decode
import gleam/json

/// `group_id` is the one group the user belongs to; see `howdy/auth/group`.
pub type User {
  User(id: String, email: String, group_id: String)
}

/// A verified session. Roles are intentionally absent: authorization reads
/// current grants rather than retaining stale permissions in a session.
/// `client` is where this request came from, as the caller identified it; it
/// is recorded with the audit events the principal causes. It is empty when
/// the transport did not supply one.
pub type Principal {
  Principal(user: User, session_id: String, client: String)
}

/// Who performed a privileged operation, recorded with its audit event.
/// `System` is trusted code acting for nobody: provisioning, scheduled jobs.
/// `SystemFrom` is the same, with a client to record for an operator request
/// that arrived over some transport of the application's own.
pub type Actor {
  System
  Acting(Principal)
  SystemFrom(client: String)
}

/// The user id to record for an actor, empty for system operations.
@internal
pub fn actor_id(actor: Actor) -> String {
  case actor {
    System | SystemFrom(_) -> ""
    Acting(principal) -> principal.user.id
  }
}

/// Where an actor's request came from, empty when unknown.
@internal
pub fn actor_client(actor: Actor) -> String {
  case actor {
    System -> ""
    SystemFrom(client) -> client
    Acting(principal) -> principal.client
  }
}

pub fn to_json(user: User) -> json.Json {
  json.object([
    #("id", json.string(user.id)),
    #("email", json.string(user.email)),
    #("group_id", json.string(user.group_id)),
  ])
}

@internal
pub fn row() -> decode.Decoder(User) {
  use id <- decode.field(0, decode.string)
  use email <- decode.field(1, decode.string)
  use group_id <- decode.field(2, decode.string)
  decode.success(User(id, email, group_id))
}
