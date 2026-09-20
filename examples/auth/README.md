# Authentication example

A loopback-only demo of optional auth pages, JSON endpoints and separate RBAC.
Email delivery prints tokens in the terminal **for this local demonstration
only**. Configure a private email delivery callback for real applications.

```sh
make -C ../../auth/vendor/jargon/c_src
gleam run -m migrate
gleam run
```

Open <http://localhost:8787/auth/register>, enter an email address, then paste
the token printed in the terminal. Visit `/account/me` to see the authenticated
user. `/account/reports` returns 403 until trusted administration code assigns
the existing `reader` role to that user. There is deliberately no public role
assignment endpoint or automatic first-user administrator.

Password registration is at `/auth/password/register`; verify the email using
the printed token, then sign in at `/auth/password/login`. Password support is
explicitly enabled by `auth.with_passwords` in the example. Existing email-only
accounts cannot add a password by registering again; sign in with an email
token and open `/auth/account` within ten minutes instead. That page lets you
set/reset a password, list or revoke sessions, and sign out. Custom clients can
call `POST /api/auth/password` directly.

Existing users can also sign in with email tokens at `/auth/login`. The JSON API is mounted at `/api/auth`.
Omit `pages.routes` in `src/howdy_auth_example.gleam` to supply your own pages;
the JSON endpoints and account guards still work.

`src/database.gleam` owns the Gloo connection and its configuration; auth receives
only the resulting Repo. This example chooses SQLite, but replacing that setup
with a configured Gloo PostgreSQL Repo leaves the auth/routes/RBAC code unchanged.

`data.sqlite` persists between runs. Schema migrations are a separate command
and are never automatically applied during application startup.

See [the package documentation](../../auth/README.md) for browser/native API
flows, headless operations, scoped RBAC and current limitations.
