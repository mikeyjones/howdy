//// Connection lifecycle/configuration belongs to the application. Auth only
//// receives the resulting Repo. This example chooses SQLite.

import gloo/adapter/sqlite
import gloo/repo.{type Repo}

pub fn connect() -> Repo {
  let assert Ok(db) = sqlite.start(sqlite.file("data.sqlite"))
  let assert Ok(_) = repo.execute(db, "PRAGMA foreign_keys = ON", [])
  let assert Ok(_) = repo.execute(db, "PRAGMA busy_timeout = 5000", [])
  db
}
