//// helper functions to handle authenticated users.

import gleam/option.{None, Option, Some}
import gleam/list

/// The user type to store the user information
pub type User {
  User(name: String, claims: List(#(String, String)))
}

/// Returns the value of a claim.
/// Either a Ok with the value or Error(Nil) if the 
/// key is not found within the claims.
pub fn get_claim(
  user_option: Option(User),
  claim_key: String,
) -> Result(String, Nil) {
  case user_option {
    Some(user) ->
      user.claims
      |> list.find_map(fn(claim) {
        case claim.0 == claim_key {
          True -> Ok(claim.1)
          False -> Error(Nil)
        }
      })
    None -> Error(Nil)
  }
}
