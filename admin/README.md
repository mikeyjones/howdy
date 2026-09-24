# howdy_admin

A development admin area for [howdy](../README.md) apps: browse and edit the
database, manage users and groups, and sign in as any user. It is mounted from
the `dev/` entry point beside [`howdy_dev`](../howdy_dev/README.md), so it
never reaches a deployment.

```toml
[dev_dependencies]
howdy_dev = { path = "../howdy-v2/howdy_dev" }
howdy_admin = { path = "../howdy-v2/admin" }
```

```gleam
// dev/my_app_dev.gleam
import gleam/erlang/process
import howdy/admin
import howdy/dev
import my_app

pub fn main() {
  let db = my_app.open_database()
  let identity = my_app.identity(db)
  let permissions = my_app.permissions(db)
  let dashboard =
    admin.new() |> admin.auth(identity) |> admin.authorization(permissions)

  let assert Ok(_) =
    dev.start(fn() {
      my_app.app(db, identity, permissions) |> admin.mount(dashboard)
    })
  process.sleep_forever()
}
```

Run `gleam dev` and open <http://localhost:8787/_howdy> (whatever port the app
listens on). See [`examples/admin`](../examples/admin/README.md) for a complete
app.

## What the app registers is what the admin shows

Gleam cannot discover at runtime which packages an app uses, and there is no
registry of the Repo or `auth.Auth` the app built, so the app hands them over:

- `admin.database(repo)`: the tables of a Gloo Repo, on PostgreSQL or SQLite.
  The overview names the backend and the packages `howdy/migration` has
  applied. Each table has a grid of its rows that refreshes every second, so a
  row your app or another client writes appears on its own and is marked
  `changed` for a few seconds. Rows can be inserted, edited and deleted. A
  row is addressed by its primary key, or by `rowid` (SQLite) or `ctid`
  (PostgreSQL) when the table has none.
- `admin.auth(identity)`: users and groups. Create a user (provisioned without
  a credential), suspend and resume them, see their live sessions (method,
  when they signed in, last seen, expiry and client) and revoke any one of
  them or all at once, move them between groups, and create, rename and
  delete groups. Registering auth also
  registers its Repo, unless `admin.database` was given another.
- `admin.authorization(permissions)`: roles in every scope, each with its
  permissions and who holds it. Define a role (global, or in an organization)
  with its permissions one per line, replace the list later, assign and revoke
  it from the role's page or from a user's page, and delete it, which drops
  its assignments. Needs `auth` too.
- `admin.at("/somewhere")` moves the pages, and `admin.named` sets the sidebar
  title.

Every value in the grid is shown and edited as text, and the database casts
what it is given: PostgreSQL through an explicit `CAST` to the column's type,
SQLite by column affinity. A refused write shows the driver's message, which a
real application never should. In an insert form, a column left empty takes its
default and the `NULL` box stores a null; in an edit form every column is
written.

## Signing in as a user

The user's page has **Sign in as this user**. It calls `auth.impersonate`,
which issues a session with method `Impersonation`, records
`session.impersonated` in the audit trail with the actor `howdy_admin`, and
sets the app's own session cookie before redirecting to `/`. Because the admin
shares the app's origin, the cookie is the real one: the next request to the
app is authenticated as that user. Suspended users cannot be impersonated,
and the session skips second factors and SSO enforcement, which is why it is
never reachable by the user themselves.

`howdy_auth` migration **18** allows the new method name; run it before using
this version.

## Development only

There is no login. Anyone who can reach the pages can read and change every
row and sign in as anyone. The defences are:

- It is a dev dependency and its entry point lives in `dev/`, which `gleam
  export erlang-shipment` leaves out.
- `howdy/dev` listens on loopback. The admin also refuses any request whose
  `Host` is not `localhost`, `127.0.0.1` or `[::1]` with `403`, so a page on
  another site cannot reach it through DNS rebinding. `admin.allow_hosts`
  replaces that list for a trusted network; anyone who can reach an allowed
  host owns your data.
- Forms carry no CSRF token. A page you visit while the admin runs could post
  to it, which is one more reason to run it only against data you can afford
  to lose.

## How the grid stays current

Neither driver reports changes: `sqlight` does not expose SQLite's update
hook and `pog` has no `LISTEN`. So each open grid is a Lustre server component
that re-runs its query once a second, compares the page with the previous one,
and marks what differs. A delete from the grid refreshes at once. This is
polling, which is fine for a development tool with a few tabs open; PostgreSQL
`NOTIFY` triggers could replace it later.

## Testing

`gleam test` drives every page through `howdy/testing` against an in-memory
SQLite database. `node browser_test/live_grid.mjs` opens the grid in headless
Chromium against a running `examples/admin`, changes the table with `sqlite3`,
and checks the grid follows.
