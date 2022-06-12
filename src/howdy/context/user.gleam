//// helper functions to handle authenticated users.

import gleam/map.{Map}

/// The user type to store the user information
pub type User {
  User(name: String, claims: Map(String, String))
}

pub fn change_name(user: User, name: String) {
  User(..user, name: name)
}

pub fn add_claim(user: User, key: String, value: String) {
  let new_claims = map.insert(user.claims, key, value)
  User(..user, claims: new_claims)
}
