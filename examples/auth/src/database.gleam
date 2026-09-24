//// Connection lifecycle/configuration belongs to the application. Auth and
//// `notes` only receive the resulting Repo. This example chooses SQLite.

import gloo/adapter/sqlite
import gloo/repo.{type Repo}
import howdy/database

pub fn connect() -> Repo {
  let assert Ok(db) = sqlite.start(sqlite.file("data.sqlite"))
  let assert Ok(_) = database.sqlite_defaults(db)
  db
}
