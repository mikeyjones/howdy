import gleam/bit_array
import gleam/crypto

pub fn new() -> String {
  crypto.strong_random_bytes(32) |> bit_array.base64_url_encode(False)
}

/// For values that are already high-entropy secrets, where an unkeyed digest
/// is enough: a stored session or challenge digest cannot be reversed.
pub fn digest(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>)
  |> bit_array.base64_url_encode(False)
}

/// For low-entropy values such as email addresses, where a plain digest is
/// only obfuscation: anyone can hash a candidate address and look for it.
/// The key is a per-installation random secret, so throttle rows do not
/// reveal which addresses have been asking for tokens.
pub fn keyed_digest(key: String, value: String) -> String {
  crypto.hmac(<<value:utf8>>, crypto.Sha256, <<key:utf8>>)
  |> bit_array.base64_url_encode(False)
}

@external(erlang, "howdy_auth_ffi", "now")
pub fn now() -> Int
