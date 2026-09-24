//// A development admin area for a Howdy app. Mount it from your `dev/`
//// entry point, and it appears at `/_howdy`:
////
//// ```gleam
//// import howdy/admin
//// import howdy/dev
////
//// pub fn main() {
////   let db = my_app.open_database()
////   let identity = my_app.identity(db)
////   let assert Ok(_) =
////     dev.start(fn() {
////       my_app.app(db, identity)
////       |> admin.mount(admin.new() |> admin.database(db) |> admin.auth(identity))
////     })
////   process.sleep_forever()
//// }
//// ```
////
//// Gleam has no way to find out which packages an app uses at runtime, and
//// no registry of the values it built, so the app hands the admin what it
//// has. What is registered decides what the admin shows:
////
//// - `database`: the tables of the Gloo Repo, on PostgreSQL or SQLite, in a
////   grid that refreshes as the data changes, with forms to insert, edit
////   and delete rows.
//// - `auth`: users and groups, creating and suspending users, moving them
////   between groups, and signing in to the app as any user. Registering
////   auth registers its database too.
////
//// ## Development only
////
//// There is no login: anyone who can reach the pages can read and change
//// every row and sign in as anyone. Keep `howdy_admin` a dev dependency,
//// mount it only from `dev/`, and serve it from `howdy/dev`, which listens
//// on loopback. The pages also refuse a request whose `Host` is not
//// `localhost`, `127.0.0.1` or `[::1]` unless `allow_hosts` says otherwise,
//// so a browser on another machine, or a DNS-rebinding page, gets `403`.
//// Forms carry no CSRF token: a page you visit while the admin runs could
//// post to it, which is one more reason to only run it against data you
//// can afford to lose.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gloo/repo.{type Repo}
import howdy.{type App}
import howdy/admin/internal/accounts
import howdy/admin/internal/config.{type Config, Config}
import howdy/admin/internal/data
import howdy/admin/internal/overview
import howdy/auth.{type Auth}
import howdy/controller.{type Controller}
import howdy/service

/// An admin area under construction.
pub opaque type Admin {
  Admin(config: Config)
}

/// An admin at `/_howdy` that knows about nothing yet.
pub fn new() -> Admin {
  Admin(
    Config(
      prefix: "/_howdy",
      name: "Howdy admin",
      database: None,
      identity: None,
      hosts: [
        "localhost",
        "127.0.0.1",
        "[::1]",
      ],
    ),
  )
}

/// Mount the pages somewhere other than `/_howdy`.
pub fn at(admin: Admin, prefix: String) -> Admin {
  let prefix =
    "/"
    <> {
      string.split(prefix, "/")
      |> list.filter(fn(segment) { segment != "" })
      |> string.join("/")
    }
  let assert True = prefix != "/"
    as "howdy/admin: the prefix cannot be the root"
  Admin(Config(..admin.config, prefix:))
}

/// The name shown in the sidebar. Defaults to "Howdy admin".
pub fn named(admin: Admin, name: String) -> Admin {
  Admin(Config(..admin.config, name:))
}

/// Browse and edit the tables of this Repo.
pub fn database(admin: Admin, repo: Repo) -> Admin {
  Admin(Config(..admin.config, database: Some(repo)))
}

/// Manage the users and groups of this auth configuration, and sign in as
/// them. Its Repo is browsed too, unless `database` was given another.
pub fn auth(admin: Admin, identity: Auth) -> Admin {
  let database = case admin.config.database {
    Some(repo) -> Some(repo)
    None -> Some(auth.repo(identity))
  }
  Admin(Config(..admin.config, identity: Some(identity), database:))
}

/// Exact request hostnames (without port) the pages answer, replacing the
/// loopback names. Anyone who can reach an allowed host owns your data.
pub fn allow_hosts(admin: Admin, hosts: List(String)) -> Admin {
  let assert True =
    list.all(hosts, fn(host) {
      host != "" && !string.contains(host, "*") && !string.contains(host, "/")
    })
    as "howdy/admin: allow_hosts requires exact hostnames, not URLs or wildcards"
  Admin(Config(..admin.config, hosts:))
}

/// Add the admin's routes to an app.
pub fn mount(app: App, admin: Admin) -> App {
  list.fold(controllers(admin), app, howdy.controller)
}

/// The admin's controllers, for mounting them yourself.
pub fn controllers(admin: Admin) -> List(Controller) {
  let config = admin.config
  list.flatten([
    [overview.controller(config)],
    case config.database {
      Some(repo) -> [data.controller(config, repo)]
      None -> []
    },
    case config.identity {
      Some(identity) -> [accounts.controller(config, identity)]
      None -> []
    },
  ])
  |> list.map(controller.middleware(_, only_hosts(config)))
}

/// Refuse requests from hosts other than the allowed ones. `request.host`
/// carries no port, so entries are compared whole.
fn only_hosts(config: Config) -> controller.Middleware {
  fn(ctx: controller.Context, next) {
    case list.contains(config.hosts, ctx.request.host) {
      True -> next(ctx)
      False -> service.error_response(ctx, service.Forbidden)
    }
  }
}

/// Where the pages are, for linking to them.
pub fn prefix(admin: Admin) -> String {
  admin.config.prefix
}

/// Whether a database was registered.
pub fn has_database(admin: Admin) -> Bool {
  option.is_some(admin.config.database)
}

/// Whether auth was registered.
pub fn has_auth(admin: Admin) -> Bool {
  option.is_some(admin.config.identity)
}
