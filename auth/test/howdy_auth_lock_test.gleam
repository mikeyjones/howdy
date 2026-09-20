import gleeunit/should

@external(erlang, "howdy_auth_test_ffi", "lock_serializes")
fn lock_serializes() -> Bool

@external(erlang, "howdy_auth_test_ffi", "lock_reentrant")
fn lock_reentrant() -> Bool

@external(erlang, "howdy_auth_test_ffi", "lock_holder_exit")
fn lock_holder_exit() -> Bool

pub fn concurrent_lock_holders_never_overlap_test() {
  lock_serializes() |> should.be_true
}

pub fn nested_lock_is_reentrant_test() {
  lock_reentrant() |> should.be_true
}

pub fn exiting_holder_releases_the_lock_test() {
  lock_holder_exit() |> should.be_true
}
