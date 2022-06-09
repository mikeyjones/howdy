//// helper functions to handle authenticated users.

import gleam/map.{Map}

/// The user type to store the user information
pub type User {
  User(name: String, claims: Map(String, String))
}
