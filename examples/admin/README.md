# Admin example

A notes app with email-token sign-in on SQLite, and the `howdy_admin`
development area mounted from `dev/`.

```sh
gleam dev
```

Open <http://localhost:8787/_howdy>. The admin shows the app's tables, users
and groups. Create a user, sign in as them, then `POST /notes` with
`{"title": "..."}` and watch the row appear in the `notes_notes` grid
without a reload. Edit the row in another SQLite client and the grid follows
within a second.

`gleam run` serves the app without hot reload or the admin: both are dev
dependencies and their entry point lives in `dev/`, which
`gleam export erlang-shipment` leaves out.
