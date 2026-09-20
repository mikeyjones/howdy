//// Groups partition users: a workspace, a tenant, an organization. Every
//// user belongs to exactly one. Manage them with `howdy/auth/groups`.

import gleam/dynamic/decode
import gleam/json

/// The least a group is: application data about it belongs in application
/// tables keyed by its id.
pub type Group {
  Group(id: String, name: String)
}

/// How users relate to groups. Choose one with `auth.with_groups`.
pub type Mode {
  /// Every user is in the one group, `default_id`. This is what an
  /// installation that never mentions groups gets.
  Single
  /// There are many groups and each user is in exactly one of them. An email
  /// address has one account across the whole installation.
  OneGroupPerUser
  /// There are many groups and an email address may have a separate account
  /// in each: separate user ids, credentials and sessions. Within one group
  /// an address still has at most one account.
  AccountPerGroup
}

/// The group every user is in under `Single`. It always exists.
pub const default_id = "default"

pub fn to_json(group: Group) -> json.Json {
  json.object([
    #("id", json.string(group.id)),
    #("name", json.string(group.name)),
  ])
}

@internal
pub fn row() -> decode.Decoder(Group) {
  use id <- decode.field(0, decode.string)
  use name <- decode.field(1, decode.string)
  decode.success(Group(id, name))
}

@internal
pub fn mode_name(mode: Mode) -> String {
  case mode {
    Single -> "single"
    OneGroupPerUser -> "one-group-per-user"
    AccountPerGroup -> "account-per-group"
  }
}

@internal
pub fn mode_from(name: String) -> Result(Mode, Nil) {
  case name {
    "single" -> Ok(Single)
    "one-group-per-user" -> Ok(OneGroupPerUser)
    "account-per-group" -> Ok(AccountPerGroup)
    _ -> Error(Nil)
  }
}

/// What the unique `login_key` column holds for an account. Under
/// `AccountPerGroup` it is qualified by the group, so the database enforces
/// one account per address per group; otherwise it is the address, so the
/// database enforces one account per address. Group ids cannot contain ':'.
@internal
pub fn login_key(mode: Mode, group_id: String, email: String) -> String {
  case mode {
    AccountPerGroup -> group_id <> ":" <> email
    Single | OneGroupPerUser -> email
  }
}
