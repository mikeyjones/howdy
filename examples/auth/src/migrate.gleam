import database
import gloo/repo
import howdy/auth
import howdy/authorization
import howdy/migration
import notes

pub fn main() {
  let db = database.connect()
  let assert Ok(_) =
    migration.run(db, [auth.schema(), authorization.schema(), notes.schema()])
  let assert Ok(_) = repo.close(db)
}
