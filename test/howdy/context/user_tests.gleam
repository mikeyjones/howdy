import gleeunit/should
import howdy/context/user.{User, get_claim}
import gleam/option.{Some}
import gleam/result

pub fn get_claim_should_return_claim_if_it_exists_test() {
  let user = Some(User("test", [#("email", "test@email.com")]))

  let sut = get_claim(user, "email")

  should.be_ok(sut)
  should.equal("test@email.com", result.unwrap(sut, "fail"))
}

pub fn get_claim_should_return_error_if_claim_does_not_exist_test() {
  let user = Some(User("test", [#("email", "test@email.com")]))

  let sut = get_claim(user, "name")

  should.be_error(sut)
}

pub fn get_claim_should_return_error_if_no_claims_exist_test() {
  let user = Some(User("test", []))

  let sut = get_claim(user, "name")

  should.be_error(sut)
}
