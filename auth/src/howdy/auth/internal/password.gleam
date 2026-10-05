//// Argon2id password storage; token digests remain SHA-256 elsewhere.

import argus
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import howdy/auth/internal/token
import howdy/auth/policy
import howdy/service

pub opaque type Passwords {
  Passwords(hasher: argus.Hasher, dummy_hash: String)
}

/// Explicit policy, independent of changes to dependency defaults: 19 MiB,
/// two iterations, one lane, 32-byte hash, fresh random salt for every hash.
pub fn new() -> service.Result(Passwords) {
  let hasher =
    argus.hasher()
    |> argus.algorithm(argus.Argon2id)
    |> argus.memory_cost(19_456)
    |> argus.time_cost(2)
    |> argus.parallelism(1)
    |> argus.hash_length(32)
  use dummy <- result.try(
    argus.hash(hasher, token.new()) |> result.map_error(failed),
  )
  use encoded <- result.try(standard_hash(dummy.encoded_hash))
  Ok(Passwords(hasher, encoded))
}

@external(erlang, "howdy_auth_ffi", "normalize_password")
pub fn normalize(password: String) -> String

/// Reject passwords that are weak in ways a length minimum does not catch.
/// With a 15 character minimum, the classic short passwords are already out;
/// what gets through is long and structured: a common word with a decorative
/// suffix, one unit repeated, a keyboard run, a handful of characters.
///
/// This is a shape check, not a breach corpus. It cannot know that a given
/// passphrase appeared in a public dump. Applications that need that supply
/// it with `auth.with_password_check`; see `howdy/auth/password_check`.
pub fn common_check(password: String) -> service.Result(Nil) {
  let lower = string.lowercase(password)
  let bare = undecorate(lower)
  case
    list.contains(common, lower)
    || list.contains(common, bare)
    || bare == ""
    || rooted(bare)
    || repeated_unit(lower)
    || thin_alphabet(lower)
    || run_of(bare)
  {
    True ->
      Error(service.Invalid("choose a password that is not common or breached"))
    False -> Ok(Nil)
  }
}

const common = [
  "password", "password123", "passwordpassword", "123456789012345",
  "1234567890123456", "qwertyuiopasdfgh", "letmeinletmein",
  "correct horse battery staple", "iloveyouiloveyou", "administrator",
  "thisismypassword", "mypasswordis1234", "letmeinplease123",
  "welcometothejungle", "passwordispassword", "keyboardkeyboard",
]

/// Words that carry no strength however they are dressed up.
const roots = [
  "password", "passwort", "passphrase", "letmein", "welcome", "qwerty",
  "iloveyou", "princess", "monkey", "dragon", "football", "baseball", "sunshine",
  "trustno", "admin", "administrator", "changeme", "secret", "master", "shadow",
  "superman", "batman", "starwars", "whatever", "freedom", "hello", "login",
  "abc", "test", "qwertyuiop", "asdfghjkl",
]

/// Rows and alphabets people walk along instead of choosing something.
const runs = [
  "1234567890123456789012345678901234567890", "qwertyuiop", "qwertzuiop",
  "azertyuiop", "asdfghjkl", "zxcvbnm", "abcdefghijklmnopqrstuvwxyz",
  "!@#$%^&*()", "qazwsxedcrfvtgbyhnujmikolp",
]

/// Decoration people add to reach a length minimum, at either end.
const decoration = "0123456789!@#$%^&*._-+= "

fn undecorate(value: String) -> String {
  value
  |> string.to_graphemes
  |> list.drop_while(string.contains(decoration, _))
  |> list.reverse
  |> list.drop_while(string.contains(decoration, _))
  |> list.reverse
  |> string.concat
}

/// A weak word, alone or simply repeated, is still that weak word.
fn rooted(bare: String) -> Bool {
  list.any(roots, fn(root) {
    bare == root || { root != "" && bare == repeat_to(root, bare) }
  })
}

/// True when `value` is some prefix of itself repeated three times or more:
/// "abcabcabcabcabc" has the strength of "abc".
fn repeated_unit(value: String) -> Bool {
  let graphemes = string.to_graphemes(value)
  let length = list.length(graphemes)
  // Every unit length that could tile the password at least three times.
  list.index_map(graphemes, fn(_, index) { index + 1 })
  |> list.take(length / 3)
  |> list.any(fn(size) {
    let unit = graphemes |> list.take(size) |> string.concat
    unit != "" && repeat_to(unit, value) == value
  })
}

fn repeat_to(unit: String, target: String) -> String {
  let needed = string.length(target) / string.length(unit) + 1
  string.repeat(unit, needed)
  |> string.to_graphemes
  |> list.take(string.length(target))
  |> string.concat
}

/// Length bought with very few different characters buys little.
fn thin_alphabet(value: String) -> Bool {
  list.length(list.unique(string.to_graphemes(value))) <= 4
}

/// The whole password is a walk along one keyboard row or alphabet.
fn run_of(bare: String) -> Bool {
  list.any(runs, fn(run) {
    string.contains(run, bare) || string.contains(reverse(run), bare)
  })
}

fn reverse(value: String) -> String {
  value |> string.to_graphemes |> list.reverse |> string.concat
}

pub fn validate(password: String, min_length: Int) -> service.Result(Nil) {
  case
    string.byte_size(password) <= policy.password_max_bytes
    && list.length(string.to_utf_codepoints(password)) >= min_length
  {
    True -> Ok(Nil)
    False ->
      Error(service.Invalid(
        "password must contain at least "
        <> int.to_string(min_length)
        <> " characters and at most "
        <> int.to_string(policy.password_max_bytes)
        <> " UTF-8 bytes",
      ))
  }
}

/// Callers validate the password against their policy first.
pub fn hash(hasher: Passwords, password: String) -> service.Result(String) {
  argus.hash(hasher.hasher, normalize(password))
  |> result.map(fn(output) { output.encoded_hash })
  |> result.map_error(failed)
  |> result.try(standard_hash)
}

fn standard_hash(encoded: String) -> service.Result(String) {
  case string.starts_with(encoded, "$argon2id$v=19$m=19456,t=2,p=1$") {
    True -> Ok(encoded)
    False -> Error(service.Internal("unsupported password hash format"))
  }
}

/// Accept legacy hashes made before normalization; the caller rehashes them
/// after success, under the same credential lock used for issuing a session.
/// Only unknown legacy hashes may use the second, exact-input verification.
pub fn verify(
  encoded: String,
  password: String,
  normalized: Bool,
) -> service.Result(#(Bool, Bool)) {
  use valid <- result.try(
    argus.verify(encoded, normalize(password)) |> result.map_error(failed),
  )
  case normalized || valid || normalize(password) == password {
    True -> Ok(#(valid, False))
    False ->
      argus.verify(encoded, password)
      |> result.map(fn(valid) { #(valid, valid) })
      |> result.map_error(failed)
  }
}

type Parameters {
  Parameters(memory: Int, iterations: Int, lanes: Int, length: Int)
}

fn parameters(encoded: String) -> Result(Parameters, Nil) {
  case string.split(encoded, "$") {
    ["", _, _, costs, _, hash] -> {
      case string.split(costs, ",") {
        ["m=" <> memory, "t=" <> iterations, "p=" <> lanes] -> {
          use memory <- result.try(int.parse(memory))
          use iterations <- result.try(int.parse(iterations))
          use lanes <- result.try(int.parse(lanes))
          use bytes <- result.try(bit_array.base64_decode(hash))
          Ok(Parameters(memory, iterations, lanes, bit_array.byte_size(bytes)))
        }
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

pub fn needs_rehash(encoded: String) -> Bool {
  case parameters(encoded) {
    Ok(p) ->
      !string.starts_with(encoded, "$argon2id$v=19$")
      || p.memory < 19_456
      || p.iterations < 2
      || p.length < 32
    Error(_) -> True
  }
}

/// Upgrade without reducing any existing cost or output length. Keep stronger
/// stored hashes intact when only the application's minimum has changed.
pub fn rehash(
  hasher: Passwords,
  encoded: String,
  password: String,
) -> service.Result(String) {
  use p <- result.try(
    parameters(encoded)
    |> result.map_error(fn(_) {
      service.Internal("unsupported password hash format")
    }),
  )
  let upgraded =
    hasher.hasher
    |> argus.memory_cost(int.max(p.memory, 19_456))
    |> argus.time_cost(int.max(p.iterations, 2))
    |> argus.parallelism(int.max(p.lanes, 1))
    |> argus.hash_length(int.max(p.length, 32))
  argus.hash(upgraded, normalize(password))
  |> result.map(fn(output) { output.encoded_hash })
  |> result.map_error(failed)
}

pub fn dummy(hasher: Passwords) -> String {
  hasher.dummy_hash
}

fn failed(_error: argus.HashError) -> service.Error {
  service.Internal("password hashing operation failed")
}
