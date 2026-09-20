# howdy_auth

Optional email-token and password authentication and separate role-based authorization for
Howdy. The package includes JSON endpoints, optional starter pages and headless
operations for applications supplying their own UI or transport.

This is an initial implementation, not the complete enterprise identity system.
It targets Erlang and accepts an **already-configured `gloo/repo.Repo`**, supporting
Gloo’s PostgreSQL and SQLite adapters. The application owns connection setup,
configuration and shutdown, and supplies email delivery. OIDC,
SAML, MFA, SCIM, invitations, tenant lifecycle management, a hosted management
dashboard and username login are not implemented yet. Do not advertise those capabilities.

## Install and migrate

In this repository, add the optional package using a path dependency:

```toml
[dependencies]
howdy_auth = { path = "../howdy-v2/auth" }
```

Build the native password dependency once before building or running the app:

```sh
make -C auth/vendor/jargon/c_src  # from the howdy-v2 repository root
```

This requires make, a C compiler and Erlang headers. Argus 2.0.0 uses Jargon
1.1.0, which has an incorrect Argon2 version constant. A local source copy fixes
that constant; see [the patch and build notes](vendor/jargon/README.md). The
problem is tracked in [Pevensie/jargon#9](https://github.com/Pevensie/jargon/issues/9); `vendor/jargon/verify.sh` proves the copy is the
published package plus the recorded version correction and build-selection patch. A corrected published dependency
is required before publishing this prototype to Hex. Existing builds switching from Hex Jargon need `gleam clean` once.

Run migrations explicitly during deployment, before starting the new version:

```gleam
import howdy/auth
import howdy/authorization
import howdy/migration

pub fn migrate(db) {
  let assert Ok(_) = migration.run(db, [
    auth.schema(),
    authorization.schema(),
  ])
}
```

Authentication can be installed alone: omit `authorization.schema()` and the
`authorization` runtime if the application does not need roles.

Migrations execute through Gloo transactions with a namespaced, checksummed
ledger. Package entries contain ordinary `gloo/migration.Migration` values,
so applications can reuse Gloo's migration constructors and DDL builders.
Howdy keeps its own package ledger rather than Gloo's global version ledger to
retain package ownership, checksums and schema-drift checks. Do not apply the
same module migrations separately through `gloo/runner`.

Concurrent PostgreSQL migrators serialize using a transaction-scoped advisory
lock. SQLite operations on the same Repo serialize in Howdy, and migration
transactions acquire the write lock before inspecting history. An entire batch
rolls back on failure. Versions are positive and strictly increasing within
each package; different packages may reuse the same version number.

Each package owns the schema namespace `<package name>_`; names must be nonempty
lowercase ASCII identifiers. Auth owns `howdy_auth_*`, and authorization owns
`howdy_authz_*`. Migration SQL is trusted code and must not contain transaction
control or mutate another package's namespace. As in Gloo's runner, batches use
semicolon-separated statements: embedded semicolons in SQL literals/procedural
bodies are not supported. The package list determines dependency order: auth
precedes authz. Auth's own DDL and parameterized queries work on both adapters.

To extend a package, append a Gloo migration with a higher version. Never edit a
published migration. Startup checks both migration history and a fingerprint
of the owned schema objects. SQLite uses its schema catalog; PostgreSQL checks
relations, columns, constraints, indexes, triggers and row-security policies in
the connection's current schema. Manual schema changes are rejected at startup
and before an upgrade. Application tables referencing auth user IDs are allowed;
adding application fields, unique indexes or triggers to auth tables is not.
Operators may add a plain (non-unique) index to an auth table, provided its
name is outside the package namespace, for example `ops_events_action`.

The fingerprint is built from database catalog output, which can change with
no real drift: a PostgreSQL major upgrade, or a dump and restore. When startup
reports that the schema changed outside its migrations and you have confirmed
by hand that it did not, accept the current shape from a deployment command:

```gleam
let assert Ok(_) = migration.rebaseline(db, auth.schema())
```

`rebaseline` refuses unless the recorded migration history exactly matches the
installed package, so it cannot hide missing or edited migrations. Never call
it at application startup.

Applications can join the same deployment transaction with their own package:

```gleam
import gloo/migration as gloo_migration

migration.run(db, [
  auth.schema(),
  authorization.schema(),
  migration.Package("app", [
    gloo_migration.new(1, "create_profiles", "CREATE TABLE app_profiles (
       user_id TEXT PRIMARY KEY REFERENCES howdy_auth_users(id),
       display_name TEXT NOT NULL
     )"),
  ]),
])
```

Back up the database before deployment. There are no down migrations, automatic
rollbacks across application versions, or rolling-upgrade compatibility guarantees
in this release. Stop old instances before migrating. Startup schema checks do
not continuously police changes made by another database writer; database access
belongs to trusted application/deployment code.

## Configure and mount

```gleam
import howdy
import howdy/auth
import howdy/auth/pages
import howdy/auth/routes
import howdy/auth/user
import howdy/controller

pub fn app(db, send_email) {
  let assert Ok(identity) = auth.new(
    repo: db,
    origin: "https://app.example.com",
    deliver: send_email,
  )
  let identity = auth.allow_registration(identity)
  // Optional: add email/password login alongside email tokens.
  let assert Ok(identity) = auth.with_passwords(identity)

  let account =
    controller.guarded("/account", auth.required(identity))
    |> controller.get("/me", fn(ctx) {
      controller.json(ctx, user.to_json(ctx.guard.user))
    })
    |> controller.build()

  howdy.new()
  |> howdy.controller(routes.api(identity, at: "/api/auth"))
  |> howdy.controller(pages.routes(
    identity, at: "/auth", api_at: "/api/auth",
  ))
  |> howdy.controller(account)
}
```

`send_email` has type `fn(auth.Delivery) -> Result(Nil, Nil)`. Send
`secret.reveal(delivery.token)` privately (import `howdy/auth/secret`) to `delivery.email`, with an instruction to paste it
into the sign-in/registration page. `delivery.purpose` says which email to
write: `SignIn`, `Registration`, or `AlreadyRegistered` when someone asked to
register an address that already has an account. That last one carries a
sign-in token and keeps no password from the request, so tell the reader they
already have an account rather than inviting them to make another. The reply to
whoever asked is the same in every case, so this tells only the inbox owner
anything. It is a 256-bit random, single-use token with
a ten-minute lifetime. Tokens are exchanged only through POST, never GET links.
Do not log tokens, place them in URLs, or include them in analytics. A delivery
error invalidates the challenge. An exchange spends the token even when it then
fails (user suspended, method disabled). Registration is disabled until explicitly
enabled and creates the user only after email verification.

A token request that finds a usable token already waiting for that address
sends no second email and still reports success: one is already in that inbox.
This is what stops a third party both flooding an inbox and locking its owner
out, because every request leaves the owner holding exactly one live token and
no request is ever refused. `policy.email_coalesce_margin_seconds` sets how
much life a token must have left to count; raising it sends more email and
allows a sooner resend, and setting it to `challenge_seconds` disables
coalescing entirely. Registration with a password cannot be answered from the
inbox, so that path keeps a per-address cooldown instead.

`auth.request_token_from` and `auth.register_password_from` take the requesting
client for throttling and audit; the shorter names share one headless bucket.

Email addresses are trimmed and lowercased as this version's explicit account
identifier policy. Email ownership is the recovery mechanism: a fresh
email-token session is what authorizes setting or resetting a password.

The runtime checks a fixed public origin rather than trusting Host/forwarded
headers. HTTPS is required except for loopback development origins such as
`http://localhost:8787`. Secure cookies use the `__Host-` prefix, HttpOnly,
SameSite=Lax and Path=/; development HTTP uses a different cookie name.
Sessions expire after 24 hours with no sliding renewal, and can additionally
expire when idle; see [Policy](#policy).

Construct the runtime and routes once in a long-lived startup process. HTTP
route limiters are owned by that process. Auth never opens, configures or closes
the supplied Repo. Pass the same Repo to `auth.new`, `authorization.new`, and
`migration.run`:

```gleam
let assert Ok(identity) = auth.new(
  repo: db, origin: "https://app.example.com", deliver: send_email,
)
let assert Ok(permissions) = authorization.new(db)
```

PostgreSQL can use the application's existing pooled Repo. SQLite can use either
an in-memory Repo or a file-backed one. Configure foreign keys and a suitable
busy timeout in the application, just as the Howdy template does.

**SQLite connection sharing:** Gloo 1.x exposes one connection per SQLite Repo.
Howdy serializes its own operations on that Repo, first come first served, but cannot serialize unrelated
application calls made directly through Gloo. If the application also performs
concurrent database operations, supply a dedicated configured SQLite Repo for
auth, pointing at the same database file. Pass that same auth Repo to both auth
and authorization. PostgreSQL's pool reserves transaction connections, so this
restriction does not apply there. Do not invoke auth operations inside a
caller-managed transaction; auth owns its operation transactions.

This is a pre-release schema revision of the earlier direct-SQLite prototype.
Existing prototype migration checksums will be rejected rather than silently
rewritten. Use a fresh development database or an explicit data migration if you
need to preserve prototype records; do not delete the ledger to bypass checks.

## Policy

Lifetimes and limits live in one record, `howdy/auth/policy.Policy`. Start from
the defaults and change what you need, once, at startup:

```gleam
import howdy/auth/policy

let assert Ok(identity) = auth.with_policy(
  identity,
  policy.Policy(
    ..policy.default(),
    session_seconds: 3600,
    session_idle_seconds: 900,
  ),
)
```

| Field | Default | Meaning |
| --- | --- | --- |
| `session_seconds` | 86 400 | Absolute session lifetime |
| `session_idle_seconds` | 0 (off) | Reject sessions unused this long; at least 300 when set |
| `email_coalesce_margin_seconds` | 300 | Life a live token must have left for a request to be answered by it rather than by sending another |
| `fresh_session_seconds` | 600 | Age limit of the email-token session that may set a password |
| `challenge_seconds` | 600 | Emailed token lifetime |
| `live_challenges` | 3 | Unexpired tokens kept per address; `1` makes each request replace the last |
| `email_cooldown_seconds` | 60 | Wait after the first email; doubles per further request |
| `email_cooldown_max_seconds` | 3 600 | Ceiling for that doubling |
| `email_quiet_seconds` | 900 | Doubling starts over after this long undisturbed |
| `password_attempts` | 5 | Initial guesses per client/address before back-off |
| `password_account_attempts` | 100 | Higher shared per-address ceiling per window |
| `password_backoff_max_seconds` | 3600 | Maximum client/address back-off |
| `password_quiet_seconds` | 86400 | Quiet time before client/address failure history expires |
| `password_window_seconds` | 60 | Shared-address window and initial client back-off |
| `password_min_length` | 15 | Minimum new password length in code points; at least 8 |

`with_policy` rejects nonsensical values. Last use of a session is recorded at
most once a minute, so authenticating a request is normally a single read.

## Optional passwords

`auth.with_passwords(identity)` enables email/password authentication. Without
it, password operations are forbidden and password pages are absent. Email-token
login remains available to password users; these are alternative methods, not
MFA. Passwords are never trimmed. New passwords are normalized to Unicode NFC
before checking and hashing, so canonically equivalent input works across keyboards.
Both original and normalized input must fit the length limits. New passwords need at least
15 Unicode code points (`policy.password_min_length`) and at most 1024 UTF-8 bytes.

`auth.register_password(identity, email, password)` sends an email verification
token. Only `auth.exchange(identity, token)` creates the account and installs its
password hash. Re-registering an existing email never replaces its password or
attaches a password to an email-only account. `auth.login_password(identity,
email, password)` returns the same session type as email-token exchange.

`auth.set_password(identity, principal, password)` sets, replaces or resets the
caller's password. One operation covers all three because the proof is the
same: the session must have been created by an **email-token exchange within
the last ten minutes** (`policy.fresh_session_seconds`). A password session, or
an older one, receives `Forbidden`. So to change or recover a password, or to
add one to an email-only account: request a login token, exchange it, then set
the password. Every other session of that user is revoked. Over HTTP this is
`POST /password`. A built-in common-password list rejects obvious compromised
choices (including the widely published “correct horse battery staple” example).
For a production breach corpus, configure `auth.with_password_check(identity,
check)` at startup. The callback receives the normalized **new** password and
returns `Ok(Nil)` or a service error; errors fail closed. Use a local corpus or
a privacy-preserving lookup, never plaintext remote queries or logging.
The built-in list and common-pattern checks are not a complete breach database.
To use a local corpus without writing your own callback:

```gleam
import howdy/auth/password_check

let identity = auth.with_password_check(identity, password_check.blocklist(corpus))
```

Build this once at startup. The checker holds normalized SHA-256 digests,
compares case-sensitively without trimming, and sends no password over the
network. Load an appropriate maintained corpus in the application.

Successful login upgrades older Argon2 parameters and pre-normalization hashes.
Migration 5 adds normalization metadata to credentials and pending registration
challenges. Existing rows start unknown, preserving normalized-first/exact-input
fallback. A successful login marks or rehashes them as NFC. New credentials and
dummy hashes use exactly one verification even for wrong decomposed Unicode
input. Unknown legacy hashes may still require two checks until successful login
or password reset; no forced password reset is required. Rehashing is
outside the transaction; the old credential is rechecked under the user lock
before replacement. Upgrades preserve higher existing costs and output lengths.
Existing passwords are not rejected by a newly configured breach checker during
login; apply that checker when setting or resetting credentials.

New passwords are screened for shapes a length minimum does not catch: a common
word however it is decorated, one unit repeated, a keyboard run, or very few
distinct characters. That is a shape check, not a breach corpus; supply one with
`auth.with_password_check` and `howdy/auth/password_check.blocklist`.

Passwords use Argus Argon2id v19 with a fresh random 16-byte salt, 19 MiB memory,
two iterations, one lane and a 32-byte hash. Only the encoded salted hash is
stored, including while email verification is pending. Hashing happens outside
database transactions. Missing, email-only and suspended accounts perform a
dummy hash verification and return the same unauthorized result as a wrong
password. `auth.login_password_from(identity, email, password, client)` uses a
persistent budget per normalized address and trusted client key. Five attempts
are initially allowed; subsequent failures require a 60-second wait that doubles
to one hour. Rejected attempts do not prolong the wait. A successful login clears
that pair's history, without clearing another client's failures. A higher shared
100/minute address ceiling limits attacks that rotate clients. All these limits
are policy fields. Resetting a password clears the address's client histories.
The compatibility `login_password` API uses one shared `headless` client key;
custom transports should use `login_password_from`. HTTP routes use the same
trusted key as `api_limited_by`; unknown clients share a fallback bucket.
Failed password attempts on real accounts record `login.failed` events.
Custom transports must also enforce client and overall load limits.

This protects stored passwords with one-way hashing. It does not encrypt user
emails, audit records, the database or backups. Those need separate storage
and key-management controls. Existing random tokens retain SHA-256 digests.

Auth migration 2 adds credentials, pending hashes and login attempt counters;
it preserves existing users and sessions. Migration 6 records the requesting
client on sessions and events and adds the throttle key table. Migration 3 adds session metadata,
the email back-off counter, audit actor/detail columns and indexes; existing
sessions are kept and treated as not freshly issued. Migration 4 adds indexed
client/address password back-off state. Migration 5 tracks normalization for
installed credentials and pending registration hashes. Authorization migration 2
adds an index. Deploy them with the same namespaced migration runner before
starting this version.

## Custom pages and API clients

Omit `pages.routes` to supply all your own pages. Mounting `routes.api` does not
install or redirect to a login page. Protected routes return JSON 401/403; the
application decides what to show. The starter pages are deliberately minimal,
require JavaScript, and display success without choosing an application redirect.

| Endpoint (relative to API mount) | Input | Result |
| --- | --- | --- |
| `POST /register` | `{"email":"ada@example.com"}` | 202; sends registration token |
| `POST /login` | `{"email":"ada@example.com"}` | 202; sends login token |
| `POST /session` | `{"token":"…"}` | User JSON and browser session cookie |
| `POST /token` | `{"token":"…"}` | Bearer access token, expiry and user JSON |
| `POST /password/register` | `{"email":"ada@example.com","password":"…"}` | 202; sends verification token |
| `POST /password/session` | Email and password | User JSON and browser session cookie |
| `POST /password/token` | Email and password | Bearer access token, expiry and user JSON |
| `POST /password` | Authentication from a fresh email-token session; `{"password":"…"}` | 204; sets or replaces the password, revokes other sessions |
| `GET /me` | Cookie or bearer authentication | User JSON |
| `GET /sessions` | Cookie or bearer authentication | The caller's live sessions: `id`, `method`, `created_at`, `last_seen_at`, `expires_at`, `current` |
| `POST /sessions/revoke` | Cookie or bearer authentication; `{"id":"…"}` | 204; revokes that session if it is the caller's |
| `POST /logout` | Cookie or bearer authentication; JSON body, e.g. `{}` | 204; revokes session |

`/register`, `/login` and the three `/password/…` sign-in endpoints accept an
optional `"group":"…"`; see [Groups](#groups). User JSON is `id`, `email` and
`group_id`.

Password starter pages are at `/password/register` and `/password/login`,
relative to the page mount. They use the same JSON API as custom pages. There
is also a session-protected `/account` page for setting/resetting passwords,
listing and revoking sessions, and signing out. For password recovery, use the
email-token sign-in page first, then open `/account`.

POST endpoints require `Content-Type: application/json`. Browser session exchange
and password cookie login require the exact configured Origin. Other endpoints allow absent Origin for
native clients but reject foreign or duplicate Origin headers. API responses
carry `Cache-Control: no-store`.

A custom browser page can use:

```javascript
await fetch('/api/auth/register', {
  method: 'POST',
  headers: {'Content-Type': 'application/json'},
  body: JSON.stringify({email}),
});

// After the user enters the emailed token:
const response = await fetch('/api/auth/session', {
  method: 'POST',
  credentials: 'same-origin',
  headers: {'Content-Type': 'application/json'},
  body: JSON.stringify({token}),
});
```

Browsers supply Origin automatically. Browser pages should use the HttpOnly
cookie flow rather than retain bearer tokens in JavaScript storage. Native
clients exchange at `/token` and send `Authorization: Bearer <access_token>`.
Requests carrying both a session cookie and Authorization are rejected, as are
duplicate credentials. `auth.required(identity)` works on both controller guards
and individual endpoints using `guard.require`.

For server-rendered forms or a completely different transport, call
`auth.request_token`, `auth.exchange`, `auth.register_password`,
`auth.login_password`, `auth.set_password`, `auth.authenticate`,
`auth.sessions`, `auth.revoke_session` and `auth.logout`
directly. Those functions return typed results without HTML, redirects or HTTP
responses. A custom transport is responsible for its CSRF protection, cookie
handling, response caching and client throttling. The provided guard requires
Origin on cookie-authenticated writes, including application routes. Applications
must not perform writes on GET routes.

## Groups

Every user belongs to exactly one group: a workspace, a tenant, an
organization. A group is an `id` and a `name`; anything more belongs in your own
tables keyed by the id. Choose how users relate to groups once, at startup:

```gleam
import howdy/auth
import howdy/auth/group

let assert Ok(identity) = auth.new(repo:, origin:, deliver:)
let assert Ok(identity) = auth.with_groups(identity, group.OneGroupPerUser)
```

| Mode | Groups | An email address has |
| --- | --- | --- |
| `group.Single` (default) | One, `group.default_id` | one account |
| `group.OneGroupPerUser` | Many | one account, in one group |
| `group.AccountPerGroup` | Many | at most one account *per group*, each with its own user id, credentials and sessions |

An application that never mentions groups gets `Single` and needs to do nothing:
everyone is in the group `default`, which migration 7 creates and puts existing
users in. `user.User` carries `group_id`, and so does the user JSON.

`auth.in_group(identity, id)` returns the same configuration acting in one
group. Requests made through it apply to that group, and it authenticates only
that group's users:

```gleam
let acme = auth.in_group(identity, "acme")
auth.request_token(acme, email, auth.Register)     // the new user joins acme
controller.guarded("/acme", auth.required(acme))   // only acme's users pass
```

- `OneGroupPerUser` needs a group to **register**, which is how a new user's
  group is chosen. Signing in works without one; with one, the account must be
  in it.
- `AccountPerGroup` needs a group for every token request, registration and
  password login, because an address alone does not name an account. Requests
  without one are `Invalid`.
- A group that does not exist is `NotFound("group")`. Under `Single`, that is
  every id but `default`.

The JSON endpoints that take an `email` also take an optional `"group"` id, and
the starter pages pass on a `?group=` query parameter. That value is the
client's claim about where it wants to sign in. After authentication, trust
`principal.user.group_id`, or guard with `auth.required(auth.in_group(…))`.
With public registration enabled, anyone who knows a group's id can register
into it; leave `allow_registration` off if membership is by invitation.

`howdy/auth/groups` manages groups. Like user administration, these are trusted
operations that take `by:` and are not exposed over HTTP:

```gleam
import howdy/auth/groups

let assert Ok(acme) = groups.create(identity, name: "Acme", by: user.System)
let assert Ok(_) =
  groups.create_with_id(identity, id: "globex", name: "Globex", by: user.System)
groups.list(identity)
groups.get(identity, "globex")
groups.rename(identity, acme.id, to: "Acme Ltd", by: user.Acting(principal))
groups.members(identity, acme.id)
groups.move(identity, user_id, to: "globex", by: user.Acting(principal))
groups.delete(identity, acme.id, by: user.System)  // Conflict while it has users
```

`create` generates the id; `create_with_id` takes one of 1 to 64 letters, digits,
hyphens and underscores, such as a tenant slug. `move` takes the user's sessions
and credentials with them, and is `Conflict` under `AccountPerGroup` when the
destination already has an account for the address. Groups are independent of
authorization scopes: to scope roles by group, use
`authorization.Organization(group_id)`, and revoke those roles yourself when
moving a user.

The mode is recorded in the database. `auth.new` adopts the recorded mode, and
`auth.with_groups` with a different one converts the installation in a single
transaction, or refuses with `Conflict` when the existing users do not fit:
`Single` needs everyone in `default`, and leaving `AccountPerGroup` needs no
address to have accounts in two groups. Sessions survive a conversion; emailed
tokens not yet redeemed do not. Convert with other nodes stopped, since a
running node keeps the mode it started with.

Uniqueness is enforced by the database through `howdy_auth_users.login_key`:
the address, or `group_id:address` under `AccountPerGroup`. Read
`howdy_auth_users.email` for the address, as before.

## Simple roles and permission-based RBAC

Authentication provides a user and verified session. Authorization separately
stores role definitions, permission grants and scoped user assignments:

```gleam
import howdy/authorization as access

let assert Ok(permissions) = access.new(db)

// Trusted provisioning/administration code, not a public request handler:
let assert Ok(_) = access.define_role(
  permissions, access.Global, "editor",
  ["articles.read", "articles.write"], by: user.System,
)
let assert Ok(_) = access.assign(
  permissions, user_id, "editor", access.Global, by: user.Acting(admin),
)
```

A simple role check inside an authenticated controller:

```gleam
use _ <- guard.require(
  ctx, access.require_role(permissions, "editor", access.Global),
)
```

Or check the operation the user may perform:

```gleam
use _ <- guard.require(
  ctx, access.require_permission(permissions, "articles.write", access.Global),
)
```

`access.has_role` and `access.allowed` expose the same checks as
`service.Result(Bool)` for application logic outside HTTP. Database failures
propagate as errors, not successful authorization decisions.

Multiple roles grant the union of their permissions. Names are literal strings:
there are no implicit `admin` privileges, wildcard permissions, role inheritance
or deny rules. Changing a role's permissions or revoking an assignment takes
effect on the next check, without waiting for the session to expire.

Use `access.Organization(organization_id)` instead of `Global` for organization
roles. Every grant is limited to exactly that scope; global roles do not bypass
organization checks. Organization IDs belong to the application's domain model.
Load/validate the target resource's organization and use that scope for checks
and data queries. An authorization result does not automatically filter SQL or
establish tenant membership. Object ownership and other business rules remain
application decisions.

## User administration and operational limits

`auth.suspend`, `auth.resume`, and `auth.revoke_sessions` are trusted management
operations. Pass `by: user.SystemFrom(client)` rather than `user.System` when an
operator request arrived over a transport of your own and you want it recorded. Suspending revokes sessions and pending challenges atomically;
resuming never restores old sessions. Role mutations and user administration
are **not exposed as unauthenticated HTTP routes**. Authorize a caller before
using them. Each takes `by:` — `user.Acting(principal)` for an administrator's
request or `user.System` for provisioning and scheduled code. The function
records who acted; deciding whether they may is still the application's job.

Users manage their own sessions with `auth.sessions` and `auth.revoke_session`
(`GET /sessions`, `POST /sessions/revoke`). Session ids are digests: they
identify a session but cannot authenticate as it.

Every event records the client the request came from, and every session records
the client it was created from. `auth.required` reads the socket address;
behind a proxy use `auth.required_from` and `routes.api_limited_by` with the
header your ingress sets, and the same identity then serves rate limiting,
throttling and audit. `auth.authenticate_from` and `auth.exchange_from` take it
for callers outside HTTP. A client string is whatever you pass; once it is an
address it is personal data, so it falls under the same retention as the rest
of `howdy_auth_events`, and passing an empty string records nothing.

The module records transactional lifecycle events in `howdy_auth_events`:
the affected user, the action, the acting user (`actor_id`, empty for system
or self-service by email proof), a `client`, and a `detail` such as the role
and scope or the login method. A token request for an address that has an
account is recorded as `token.requested` with its purpose, so someone asking
why they received an email can be answered. Failed password logins on real accounts are recorded too.
`auth.prune_events(identity, before: unix_seconds)` applies a retention period.
This is not yet an enterprise audit system: audit export, integrity protections
and a management API remain future work.

The default HTTP endpoints rate limit per client in-process: 30 requests per
minute to endpoints that send email, exchange tokens or hash passwords
(`routes.credential_limit`), and a separate 300 per minute to the signed-in
endpoints pages call routinely (`/me`, `/sessions`, `/logout`). `routes.api`
identifies clients by socket address. **Behind a reverse proxy that is the
proxy's address for everyone**, so use `routes.api_limited_by` with the header
your ingress sets:

```gleam
routes.api_limited_by(identity, at: "/api/auth", key: fn(ctx) {
  request.get_header(ctx.request, "fly-client-ip") |> option.from_result
})
```

Only trust a header your ingress overwrites. Across multiple instances these
limits are per process.

Token requests are bounded per address by coalescing rather than by refusing:
while a usable token is waiting, further requests send nothing and still report
success. A new request never invalidates tokens already sent; the three most
recent stay valid. So a third party requesting tokens for someone else's
address can neither flood that inbox, nor cancel the token its owner is about
to paste, nor stop the owner receiving one. This holds however many clients
they request from, because the limit is a property of the inbox and not of who
asked. Registration with a password is the one request that cannot be answered
from the inbox, so it backs off per address instead, in the database and shared
across instances: 60 seconds after the first, doubling up to an hour, starting
over after 15 quiet minutes or as soon as a token is exchanged.

Operators must also bound total outgoing mail volume through the
provider/ingress to control abuse across many addresses.

Rows recording which addresses have been asking are keyed with a random secret
created in the database on first use (`howdy_auth_keys`), so they cannot be
matched against a guessed address. Token and session digests are unkeyed:
those values are already random secrets.

Concurrent password hashing is bounded by the runtime rather than by this
package. Argon2 runs on the BEAM's dirty CPU schedulers, so at most that many
hashes are ever in flight whatever the request rate: a burst of 200 concurrent
logins on a six-core machine measured 120 MiB of hashing memory, not 200 x 19
MiB. Bound the arrival rate with the route limiter described above.

Token/session digests are stored instead of raw secrets. Expired rows are
pruned as a side effect of email requests and logins. For quiet installations
call `auth.prune_expired(identity)` from a scheduled job; nothing is scheduled
automatically.

See [the runnable example](../examples/auth/README.md). Run verification with:

```sh
cd auth
make -C vendor/jargon/c_src
gleam test                                      # Gloo SQLite, isolated in memory
HOWDY_AUTH_TEST_BACKEND=postgres gleam test      # same suite, real PostgreSQL
gleam format --check src test
node --test test/pages_client_test.mjs           # account-page interactions
```

PostgreSQL tests use localhost:5432 with a test-only `howdy_auth_test` role and
trust authentication. The role must be able to create temporary test databases.
Each case creates and drops its own uniquely named database. CI runs the same
suite against both adapters using a disposable PostgreSQL service.


## Follow-up API notes

`Delivery.token` and `Session.token` are now opaque `secret.Secret` values.
Call `secret.reveal(value)` explicitly at delivery or transport boundaries;
ordinary inspection of the enclosing record no longer prints the credential.
This prevents accidental logs, not deliberate access to process memory.
The example's local-only delivery output deliberately reveals the token.

Origin construction lowercases scheme/host and removes default ports, preserving
IPv6 brackets. Requests still require an exact canonical Origin for cookie writes.

Privileged `suspend`, `resume` and `revoke_sessions` return `NotFound("user")`
for missing users. Role assignment/revocation also return `NotFound("role")`
for a missing role. Revoking an absent assignment of an existing role is idempotent.
Applications remain responsible for authorizing callers of these headless APIs.

Authorization defaults to fresh database reads. Opt in with
`access.with_cache(permissions, seconds: 5)` (1–60 seconds) at application startup.
This bounded in-memory cache stores successful role/permission decisions, never
database errors. Only role definition/assignment/revocation, suspension/resume and data migrations
invalidate caches. Login, password, throttle and session transactions preserve
cache entries. Invalidation follows the outermost Howdy transaction, including
rollback; uncommitted changes bypass the cache. Use `access.with_changes(fn() {
... })` around application-owned grant SQL and its entire external transaction
when local invalidation is required. This wrapper does not make sharing SQLite
connections or invoking auth operations inside external transactions safe. A generation stamp prevents an older in-flight read
from repopulating the current generation after a write. Changes from another
BEAM node or direct SQL may remain stale until the TTL; use the default for
immediate distributed revocation. Always authenticate the session on every request:
this cache does not replace session validation or cache session secrets. If the
process owning the cache exits, authorization falls back to fresh reads.

The core reserves `howdy/auth`, `howdy/auth/*`, `howdy/authorization` and
`howdy/migration` for this optional package. The root CI namespace check enforces
this agreement, avoiding a package-wide breaking module rename.
