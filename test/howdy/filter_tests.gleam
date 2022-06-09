import gleeunit/should
// import howdy/filter.{Continue, ContinueOrStop, Stop, combine}
import howdy/response
import howdy/helpers.{get_http_request}
import howdy/context.{Context}
import gleam/io
// pub fn something_test() {
//   let req = Context([], get_http_request())
//   let filters = [sample_bad, sample]
//   let sut = combine(req, filters)
//   case sut {
//     Continue(_) -> should.fail()
//     Stop(_) -> should.be_true(True)
//   }
// }
// pub fn something2_test() {
//   let req = Context([], get_http_request())
//   let filters = [sample]
//   let sut = combine(req, filters)
//   case sut {
//     Continue(_) -> should.be_true(True)
//     Stop(_) -> should.fail()
//   }
// }
// fn sample(req: Context) -> ContinueOrStop {
//   io.println("Filtter before")
//   Continue(req)
// }
// fn sample_bad(_req: Context) -> ContinueOrStop {
//   Stop(
//     response.of_string("I'm bad")
//     |> response.with_status(500),
//   )
// }
