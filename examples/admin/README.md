# Admin example

A notes app with email-token sign-in on SQLite, and the `howdy_admin`
development area mounted from `dev/`.

```sh
gleam dev
```

Open <http://localhost:8787/_howdy>. The admin shows the app's tables, users,
groups and roles. Create a user, sign in as them, then `POST /notes` with
`{"title": "..."}` and watch the row appear in the `notes_notes` grid
without a reload. Edit the row in another SQLite client and the grid follows
within a second.

Give a user the global `reader` role from their page or from **Roles**, sign
in as them, and `GET /notes/all` answers; without it the route is `403`.

Deleting a user from their page removes their notes too: the example's
deletion callback does that in the same transaction.

With `DATABASE_URL` set to a PostgreSQL server, the app and the admin use it
instead of the SQLite file, and the grid follows changes through `NOTIFY`
rather than polling.

`gleam run` serves the app without hot reload or the admin: both are dev
dependencies and their entry point lives in `dev/`, which
`gleam export erlang-shipment` leaves out.
