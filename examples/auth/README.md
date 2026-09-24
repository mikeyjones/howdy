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

`src/notes.gleam` is application-owned data beside auth's, built on
[`howdy_database`](../../database/README.md): its own `notes` migration package,
run by the same `migrate` command and checked at startup, and services that
work on either database. Signed in, `GET`, `POST {"title"}` and
`DELETE /:id` under `/account/notes` list, add and remove your notes; a
duplicate title is a 409. Deleting the account removes its notes in auth's own
transaction, through `auth.with_account_deletion`.

`data.sqlite` persists between runs. Schema migrations are a separate command
and are never automatically applied during application startup.

See [the package documentation](../../auth/README.md) for browser/native API
flows, headless operations, scoped RBAC and current limitations.

Google sign-in is enabled when `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` are
set in the process environment. Create a Google OAuth **Web application** client
and register this exact redirect URI:
`http://localhost:8787/auth/providers/google/callback`. Use OTP 27 or newer.
Run the migration command again before starting an existing demo database.

The login page will display **Continue with Google**. A first sign-in with a
Gmail/Workspace address creates an account. If that email already has a local
account, sign into it with an email token first and use **Link Google** on
`/auth/account`. Linking requires a session created within the last ten minutes.
Google accounts using third-party email addresses must register/verify locally
before linking. Google sign-in leaves existing RBAC permissions unchanged.

Passkeys are enabled in the demo. Sign in, then add a passkey on `/auth/account`;
subsequent logins can use the **Sign in with a passkey** button. Browsers permit
WebAuthn on localhost; deployments need HTTPS and a stable public origin.

To enable authenticator MFA, generate a key once and store it privately:

```sh
openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'
```

Supply that value as `HOWDY_AUTH_MFA_KEY` every time you start the example.
Do not generate a replacement on each startup. Run the migration command before
using an existing database. Enroll from `/auth/account`, copy the manual key into
your authenticator and verify its code. Save the recovery codes, then sign in
again and complete MFA. The demo does not configure delivered-code fallback.
