//// Email-token, password and built-in provider authentication. This package owns its tables; applications
//// keep small facts in `howdy/auth/field` and anything relational in their own tables.
//// Authorization lives in howdy/authorization.

import howdy/auth/secret

import gleam/bool
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/uri
import gloo/repo.{type Repo}
import howdy/auth/connection
import howdy/auth/field.{type Change}
import howdy/auth/group.{type Mode, AccountPerGroup, OneGroupPerUser, Single}
import howdy/auth/internal/account_store
import howdy/auth/internal/address
import howdy/auth/internal/cache
import howdy/auth/internal/connection_store
import howdy/auth/internal/database as db
import howdy/auth/internal/keyring
import howdy/auth/internal/password as password_hash
import howdy/auth/internal/provider_store
import howdy/auth/internal/rate_limit_store
import howdy/auth/internal/schema
import howdy/auth/internal/security_store
import howdy/auth/internal/sso_oidc
import howdy/auth/internal/sso_saml
import howdy/auth/internal/store
import howdy/auth/internal/token
import howdy/auth/mfa
import howdy/auth/passkey
import howdy/auth/policy.{type Policy}
import howdy/auth/provider
import howdy/auth/session_store.{type Entry, type SessionStore, Entry}
import howdy/auth/user.{
  type Actor, type Principal, type User, Acting, Principal, System,
}
import howdy/context.{type Context}
import howdy/migration
import howdy/rate_limit
import howdy/service

pub type Intent {
  Login
  Register
}

/// What the email should tell its reader. Derived from the request and from
/// whether the address already has an account; the HTTP response is the same
/// either way, so this reveals nothing to anyone but the inbox owner.
pub type Purpose {
  /// Sign in to the account that already owns this address.
  SignIn
  /// Create the account that redeeming this token will verify.
  Registration
  /// Someone asked to register an address that already has an account. Say so
  /// rather than inviting them to register again: redeeming the token signs
  /// that existing account in, and no password from the request was kept.
  AlreadyRegistered
  /// Confirm a change of the signed-in account’s email, not a login token.
  EmailChange
  /// Sent to the CURRENT address when `with_email_change_approval` is on:
  /// someone signed in asked to move the account to another address. The token
  /// approves that on the account page; it cannot sign in. Tell a reader who
  /// did not ask to ignore it and secure the account.
  EmailChangeApproval
  /// A notice to the OLD address: the account now signs in with a different
  /// one. `token` is empty. Tell a reader who did not do this to contact
  /// support, because this mailbox can no longer recover the account.
  EmailChanged
  /// A notice, not a request: the account's password was just replaced using
  /// its current password. `token` is empty. Tell the reader to reset the
  /// password from a fresh email login if this was not them.
  PasswordChanged
}

/// Deliver the token privately. Never log it or expose it in a public response.
/// The token expires after `policy.challenge_seconds` (ten minutes by default)
/// and must be exchanged via POST.
pub type Delivery {
  Delivery(
    email: String,
    token: secret.Secret,
    purpose: Purpose,
    /// With `with_email_links`, a page URL that fills in `token` for its
    /// reader to confirm. `None` for notices, which carry no token.
    link: Option(secret.Secret),
    /// With `with_email_codes`, a six-digit code that signs in like `token`
    /// when entered with this address. Only for `SignIn`, `Registration` and
    /// `AlreadyRegistered`, and only until three wrong guesses.
    code: Option(secret.Secret),
  )
}

pub opaque type Auth {
  Auth(
    repo: Repo,
    origin: String,
    deliver: fn(Delivery) -> Result(Nil, Nil),
    registration: Bool,
    email_tokens: Bool,
    providers: List(provider.Provider),
    passwords: Option(password_hash.Passwords),
    policy: Policy,
    password_check: fn(String) -> service.Result(Nil),
    throttle_key: String,
    groups: Mode,
    /// The group this value acts in, chosen with `in_group`.
    group: Option(String),
    sessions: Sessions,
    before_delete: Option(fn(Repo, User) -> service.Result(Nil)),
    mfa: Option(mfa.Config),
    passkeys: Option(PasskeySetup),
    sso: Option(connection.Config),
    email_change_approval: Bool,
    multi_session: Option(Int),
    email_links: Option(String),
    email_codes: Bool,
    rate_limits: Option(rate_limit.Store),
  )
}

/// The database keeps sessions in the transactions that create and revoke
/// them. An external store cannot join one, so it is written after the
/// database commits; see `with_session_store` for what that changes.
type Sessions {
  InDatabase
  External(SessionStore)
}

/// How a session was authenticated.
pub type Method {
  EmailToken
  Password
  Provider(id: String)
  Passkey
  /// Issued by `impersonate` for an operator, never by a credential.
  Impersonation
}

/// Returned by a successful sign-in. Keep the token secret. Browser
/// routes put it in an HttpOnly cookie; native API clients use Bearer auth.
pub type Session {
  Session(user: User, token: secret.Secret, expires_at: Int)
}

/// One of a user's live sessions. `id` identifies it for `revoke_session`;
/// it is a digest and cannot be used to authenticate.
pub type SessionInfo {
  SessionInfo(
    id: String,
    method: Method,
    created_at: Int,
    last_seen_at: Int,
    expires_at: Int,
    current: Bool,
    /// Where the session was created from, as the transport reported it.
    /// Empty when it did not report one.
    client: String,
  )
}

/// Emailed tokens and session tokens are 32 random bytes, base64url encoded.
const token_bytes = 43

/// Last use is recorded at most this often, keeping reads read-only.
const touch_seconds = 60

pub fn schema() -> migration.Package {
  schema.authentication()
}

/// Accept an already-configured Gloo Repo; the application owns its lifecycle.
/// Construct once after running migrations. HTTPS is required except for
/// loopback development origins. Origin must contain only scheme/host/port.
pub fn new(
  repo repo: Repo,
  origin origin: String,
  deliver deliver: fn(Delivery) -> Result(Nil, Nil),
) -> service.Result(Auth) {
  use origin <- result.try(address.canonical_origin(origin))
  use _ <- result.try(migration.check(repo, schema()))
  use throttle_key <- result.try(db.transaction(repo, store.throttle_key))
  use groups <- result.try(db.connect(repo, stored_groups))
  Ok(Auth(
    repo,
    origin,
    deliver,
    False,
    True,
    [],
    None,
    policy.default(),
    fn(_) { Ok(Nil) },
    throttle_key,
    groups,
    None,
    InDatabase,
    None,
    None,
    None,
    None,
    False,
    None,
    None,
    False,
    None,
  ))
}

/// Keep sessions in a store of your own instead of the auth database; see
/// `howdy/auth/session_store`. Construct once at startup. Sessions are not
/// copied between stores, so changing store signs everyone out.
///
/// Users, credentials and suspension stay in the database, and every request
/// still confirms there that the session's user is active, so a suspended
/// user is refused even if the store still holds their sessions. What changes
/// is atomicity. The database commits first and the store is written second,
/// so if the store fails in between, the operation returns its error with
/// the database change already made: a registration or sign-in without a
/// session (request another token), or a suspension, `revoke_sessions` or
/// `set_password` whose sessions are not yet removed (call it again, or
/// `revoke_sessions`).
pub fn with_session_store(auth: Auth, store: SessionStore) -> Auth {
  Auth(..auth, sessions: External(store))
}

/// Choose how users relate to groups; see `howdy/auth/group`. Construct once
/// at startup, like the rest of the configuration:
///
/// ```gleam
/// let assert Ok(identity) = auth.new(repo:, origin:, deliver:)
/// let assert Ok(identity) = auth.with_groups(identity, group.OneGroupPerUser)
/// ```
///
/// The choice is recorded in the database, and an installation that never
/// calls this keeps whatever was recorded, `Single` to begin with. Choosing a
/// different mode converts the installation in one transaction, or refuses
/// with Conflict when the users already there do not fit it: `Single` needs
/// everyone in the default group, and leaving `AccountPerGroup` needs no
/// address to have accounts in two groups. Sessions survive a conversion;
/// emailed tokens not yet redeemed do not. Change modes with every other
/// node stopped, since a running node keeps the mode it started with.
pub fn with_groups(auth: Auth, mode: Mode) -> service.Result(Auth) {
  use _ <- result.try({
    use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
    use stored <- result.try(stored_groups(conn))
    case stored == mode {
      True -> Ok(Nil)
      False -> convert_groups(conn, stored, mode)
    }
  })
  Ok(Auth(..auth, groups: mode))
}

fn stored_groups(conn: Repo) -> service.Result(Mode) {
  use stored <- result.try(store.setting(conn, "groups"))
  case stored {
    [] -> Ok(Single)
    [name] ->
      group.mode_from(name)
      |> result.replace_error(service.Internal(
        "auth database records a group mode this version does not know",
      ))
    _ -> Error(service.Internal("auth database operation failed"))
  }
}

fn convert_groups(conn: Repo, from: Mode, to: Mode) -> service.Result(Nil) {
  use _ <- result.try(case to {
    Single -> {
      use outside <- result.try(store.users_outside_group(
        conn,
        group.default_id,
      ))
      case outside {
        False -> Ok(Nil)
        True ->
          Error(service.Conflict(
            "users exist outside the default group; move them before choosing group.Single",
          ))
      }
    }
    _ -> Ok(Nil)
  })
  use _ <- result.try(case from, to {
    AccountPerGroup, _ -> {
      use shared <- result.try(store.shared_addresses(conn))
      case shared {
        False -> store.rekey_users(conn, False)
        True ->
          Error(service.Conflict(
            "an email address has accounts in more than one group; only group.AccountPerGroup allows that",
          ))
      }
    }
    _, AccountPerGroup -> store.rekey_users(conn, True)
    _, _ -> Ok(Nil)
  })
  use _ <- result.try(provider_store.invalidate(conn))
  use _ <- result.try(account_store.invalidate_email_changes(conn))
  use _ <- result.try(security_store.invalidate(conn))
  use _ <- result.try(store.set_setting(conn, "groups", group.mode_name(to)))
  event(conn, "", "groups.mode", System, group.mode_name(to))
}

pub fn group_mode(auth: Auth) -> Mode {
  auth.groups
}

/// The same configuration, acting in one group. Token requests, registration
/// and password login made through the returned value apply to that group,
/// and it authenticates only that group's users, so
/// `auth.required(auth.in_group(identity, id))` guards a group's routes.
///
/// `AccountPerGroup` needs this for every sign-in and registration, because
/// an address alone does not name an account. `OneGroupPerUser` needs it to
/// register, which is how a new user's group is chosen; signing in works
/// without it. `Single` never needs it. It costs nothing: call it per request.
pub fn in_group(auth: Auth, group_id: String) -> Auth {
  Auth(..auth, group: Some(group_id))
}

@internal
pub fn repo(auth: Auth) -> Repo {
  auth.repo
}

/// The group chosen with `in_group`, if any.
@internal
pub fn bound_group(auth: Auth) -> Option(String) {
  auth.group
}

/// The group a sign-in or registration applies to, `None` for whichever group
/// holds the address.
fn target(auth: Auth, registering: Bool) -> service.Result(Option(String)) {
  case auth.groups, auth.group {
    Single, None -> Ok(Some(group.default_id))
    Single, Some(id) if id == group.default_id -> Ok(Some(id))
    Single, Some(_) -> Error(service.NotFound("group"))
    AccountPerGroup, None ->
      Error(service.Invalid(
        "accounts belong to a group here; choose one with auth.in_group",
      ))
    OneGroupPerUser, None if registering ->
      Error(service.Invalid(
        "registration needs a group; choose one with auth.in_group",
      ))
    _, within -> Ok(within)
  }
}

/// Refuse a group that does not exist rather than email a token that can
/// never be redeemed.
fn existing(auth: Auth, within: Option(String)) -> service.Result(Nil) {
  case within {
    None -> Ok(Nil)
    Some(id) -> {
      use found <- result.try(db.connect(auth.repo, store.find_group(_, id)))
      case found {
        [_] -> Ok(Nil)
        _ -> Error(service.NotFound("group"))
      }
    }
  }
}

fn in_bound_group(auth: Auth, group_id: String) -> service.Result(Nil) {
  case auth.group {
    Some(id) if id != group_id -> Error(service.Unauthorized)
    _ -> Ok(Nil)
  }
}

/// Enable password registration and login. Construct once at startup. Email
/// tokens remain available; this is an additional method, not a second factor.
pub fn with_passwords(auth: Auth) -> service.Result(Auth) {
  use passwords <- result.try(password_hash.new())
  Ok(Auth(..auth, passwords: Some(passwords)))
}

/// Replace the default limits and lifetimes. See `howdy/auth/policy`.
pub fn with_policy(auth: Auth, policy: Policy) -> service.Result(Auth) {
  use policy <- result.try(policy.validate(policy))
  Ok(Auth(..auth, policy:))
}

pub fn policy(auth: Auth) -> Policy {
  auth.policy
}

/// Supplement the built-in common-password check with a local breached-password
/// corpus or a privacy-preserving service. Receives NFC-normalized new passwords
/// only. Errors fail closed; never log this argument or send plaintext remotely.
pub fn with_password_check(
  auth: Auth,
  check: fn(String) -> service.Result(Nil),
) -> Auth {
  Auth(..auth, password_check: check)
}

fn validate_new_password(auth: Auth, password: String) -> service.Result(Nil) {
  use _ <- result.try(password_hash.validate(
    password,
    auth.policy.password_min_length,
  ))
  let normalized = password_hash.normalize(password)
  use _ <- result.try(password_hash.validate(
    normalized,
    auth.policy.password_min_length,
  ))
  use _ <- result.try(password_hash.common_check(normalized))
  auth.password_check(normalized)
}

pub fn passwords_enabled(auth: Auth) -> Bool {
  auth.passwords != None
}

fn passwords(auth: Auth) -> service.Result(password_hash.Passwords) {
  case auth.passwords {
    Some(value) -> Ok(value)
    None -> Error(service.Forbidden)
  }
}

/// Public registration is disabled unless explicitly enabled.
pub fn allow_registration(auth: Auth) -> Auth {
  Auth(..auth, registration: True)
}

pub fn registration_enabled(auth: Auth) -> Bool {
  auth.registration
}

pub fn origin(auth: Auth) -> String {
  auth.origin
}

pub fn secure(auth: Auth) -> Bool {
  string.starts_with(auth.origin, "https://")
}

/// Max-Age for the session cookie. Without renewal it matches the session. With
/// it the cookie must outlive any one expiry, so it lasts to
/// `policy.session_max_seconds`, or the 400 days browsers allow when there is
/// no ceiling. The cookie only carries the token; expiry is decided here.
pub fn session_cookie_seconds(auth: Auth) -> Int {
  case auth.policy.session_renew_seconds, auth.policy.session_max_seconds {
    0, _ -> auth.policy.session_seconds
    _, 0 -> 34_560_000
    _, max -> int.min(max, 34_560_000)
  }
}

/// Let one browser hold several signed-in accounts and switch between them.
/// Signing in while signed in then adds an account instead of replacing the
/// session; signing out returns to another account that is still signed in.
/// `max` accounts per browser, from 2 to 10: signing in to one more signs the
/// oldest out. Only the cookie transport changes. Every account remains an
/// ordinary session that is listed, renewed, expired and revoked as any other,
/// and bearer clients are unaffected.
pub fn with_multi_session(auth: Auth, max max: Int) -> service.Result(Auth) {
  case max >= 2 && max <= 10 {
    True -> Ok(Auth(..auth, multi_session: Some(max)))
    False ->
      Error(service.Invalid("multi-session allows 2 to 10 accounts per browser"))
  }
}

/// The most accounts one browser may hold, when multi-session is on.
pub fn multi_session(auth: Auth) -> Option(Int) {
  auth.multi_session
}

/// The second cookie of a multi-session browser: every session token it holds,
/// the active one included, joined by `.`. It is as sensitive as the session
/// cookie and takes the same options.
pub fn accounts_cookie_name(auth: Auth) -> String {
  case secure(auth) {
    True -> "__Host-howdy_accounts"
    False -> "howdy_dev_accounts"
  }
}

/// The session tokens that still authenticate, in the order given, each with
/// its principal. Anything else is dropped without error: expired, revoked,
/// suspended or malformed entries are what a long-lived cookie accumulates.
pub fn device_sessions(
  auth: Auth,
  tokens: List(String),
  client: String,
) -> List(#(String, Principal)) {
  list.unique(tokens)
  |> list.take(10)
  |> list.filter_map(fn(secret) {
    authenticate_from(auth, secret, client)
    |> result.map(fn(principal) { #(secret, principal) })
  })
}

/// The tokens a browser should hold after signing in to `session`: the live
/// ones it had, then the new one. An earlier session of the same user is
/// revoked and replaced, and so are the oldest beyond the configured maximum.
pub fn add_device_session(
  auth: Auth,
  tokens: List(String),
  session: Session,
  client: String,
) -> List(String) {
  let new = secret.reveal(session.token)
  let #(replaced, others) =
    device_sessions(auth, tokens, client)
    |> list.filter(fn(entry) { entry.0 != new })
    |> list.partition(fn(entry) { { entry.1 }.user.id == session.user.id })
  let room = option.unwrap(auth.multi_session, 1) - 1
  let evicted = list.take(others, int.max(0, list.length(others) - room))
  list.each(list.append(replaced, evicted), fn(entry) { logout(auth, entry.1) })
  list.drop(others, list.length(evicted))
  |> list.map(fn(entry) { entry.0 })
  |> list.append([new])
}

pub fn cookie_name(auth: Auth) -> String {
  case secure(auth) {
    True -> "__Host-howdy_session"
    False -> "howdy_dev_session"
  }
}

/// Headless operation for custom UI or another transport. Delivery is
/// identical for known and unknown addresses; account eligibility is checked
/// at exchange. This shares one client bucket with every other headless
/// caller; pass the request's client to `request_token_from` instead.
pub fn request_token(
  auth: Auth,
  email: String,
  intent: Intent,
) -> service.Result(Nil) {
  request_token_from(auth, email, intent, "headless")
}

/// As `request_token`, with the requesting client for throttling and audit.
///
/// A request that finds a usable token already waiting for that address sends
/// no second email and still reports success, because one is already in the
/// inbox. That is deliberate: it means a third party asking for tokens can
/// neither flood the inbox nor stop its owner from receiving one, since every
/// request leaves the owner holding exactly one live token. Tune the window
/// with `policy.email_coalesce_margin_seconds`.
pub fn request_token_from(
  auth: Auth,
  email: String,
  intent: Intent,
  client: String,
) -> service.Result(Nil) {
  request_challenge(auth, email, intent, client, TokenOnly)
}

/// Register with an email address and password. The email challenge must be
/// exchanged before the account or credential becomes usable. Never replaces
/// an existing user's credential or attaches one based only on email equality.
/// Shares one headless client bucket; prefer `register_password_from`.
pub fn register_password(
  auth: Auth,
  email: String,
  password: String,
) -> service.Result(Nil) {
  register_password_from(auth, email, password, "headless")
}

/// As `register_password`, with the requesting client for throttling and audit.
pub fn register_password_from(
  auth: Auth,
  email: String,
  password: String,
  client: String,
) -> service.Result(Nil) {
  use hasher <- result.try(passwords(auth))
  use _ <- result.try(validate_new_password(auth, password))
  request_challenge(
    auth,
    email,
    Register,
    client,
    WithPassword(fn() { password_hash.hash(hasher, password) }),
  )
}

/// How the request supplies the credential to store with the challenge.
/// A token-only request can be answered by a token already sent; one that
/// carries a password cannot, so only that path pays a cooldown.
type Preparation {
  TokenOnly
  WithPassword(fn() -> service.Result(String))
  /// An encoded passkey whose attestation has already been verified.
  WithPasskey(String)
}

fn request_challenge(
  auth: Auth,
  email: String,
  intent: Intent,
  client: String,
  preparation: Preparation,
) -> service.Result(Nil) {
  use _ <- result.try(require_email_tokens(auth))
  use email <- result.try(address.normalize_email(email))
  use _ <- result.try(case intent == Register && !auth.registration {
    True -> Error(service.Forbidden)
    False -> Ok(Nil)
  })
  use within <- result.try(target(auth, intent == Register))
  use _ <- result.try(existing(auth, within))
  // A covered member's token could never be redeemed. The reply is the same
  // as for any other address; the sign-in page routes them by `sso_for_email`.
  use enforcing <- result.try(
    db.connect(auth.repo, connection_store.enforcing(_, email, within)),
  )
  use <- bool.guard(option.is_some(enforcing), Ok(Nil))
  let now = token.now()
  // What the token will actually do, and so what the email must say. Asking to
  // register an address that already has an account sends a sign-in token and
  // keeps no password from the request. The reply to the caller is unchanged,
  // so this tells only the inbox owner anything.
  // Registering collides with an account anywhere the address is unique,
  // which under `OneGroupPerUser` is every group, not just the one asked for.
  let domain = case auth.groups, intent {
    OneGroupPerUser, Register -> None
    _, _ -> within
  }
  use owner <- result.try(
    db.connect(auth.repo, store.user_id_for_email(_, email, domain)),
  )
  let #(stored, purpose, within) = case intent, owner {
    // The token signs in the account that exists, wherever it is.
    Register, Some(_) -> #(Login, AlreadyRegistered, domain)
    Register, None -> #(Register, Registration, within)
    Login, _ -> #(Login, SignIn, within)
  }
  case preparation {
    // A usable token already in that inbox answers the request: sending a
    // second one would let a third party fill the inbox, and refusing would
    // let them stop its owner receiving anything.
    TokenOnly ->
      send(auth, email, within, stored, purpose, None, None, now, client, owner)
    WithPasskey(key) -> {
      use _ <- result.try({
        use conn <- db.transaction(auth.repo)
        store.reserve_email(
          conn,
          address_key(auth, within, email),
          now,
          auth.policy,
        )
      })
      // As with a password: an existing account keeps nothing from the request.
      let key = case purpose {
        AlreadyRegistered -> None
        _ -> Some(key)
      }
      send(auth, email, within, stored, purpose, None, key, now, client, owner)
    }
    WithPassword(hash) -> {
      // Reserve the cooldown before hashing, and keep it even if hashing or
      // delivery then fails. Hashing must not hold a transaction open.
      use _ <- result.try({
        use conn <- db.transaction(auth.repo)
        store.reserve_email(
          conn,
          address_key(auth, within, email),
          now,
          auth.policy,
        )
      })
      // Hash before deciding to discard it, so the time taken cannot tell a
      // caller whether the address already has an account.
      use encoded <- result.try(hash())
      let password = case purpose {
        AlreadyRegistered -> None
        _ -> Some(encoded)
      }
      send(
        auth,
        email,
        within,
        stored,
        purpose,
        password,
        None,
        now,
        client,
        owner,
      )
    }
  }
}

fn send(
  auth: Auth,
  email: String,
  within: Option(String),
  intent: Intent,
  purpose: Purpose,
  password: Option(String),
  passkey: Option(String),
  now: Int,
  client: String,
  owner: Option(String),
) -> service.Result(Nil) {
  let secret = token.new()
  let code = case auth.email_codes {
    True -> Some(token.code())
    False -> None
  }
  use sending <- result.try({
    use conn <- db.transaction(auth.repo)
    use sending <- result.try(store.claim_challenge(
      conn,
      address_key: address_key(auth, within, email),
      digest: token.digest(secret),
      email:,
      intent: intent_name(intent),
      group_id: within,
      now:,
      expires_at: now + auth.policy.challenge_seconds,
      live_after: now + auth.policy.email_coalesce_margin_seconds,
      password_hash: password,
      passkey:,
      code_digest: option.map(code, email_code_digest(auth, email, _)),
      keep: auth.policy.live_challenges,
    ))
    // Attributable only when the address has an account. Someone investigating
    // unexpected email can see which requests caused it and where from.
    case owner, sending {
      Some(id), True ->
        event_from(
          conn,
          id,
          "token.requested",
          System,
          purpose_name(purpose),
          client,
        )
      _, _ -> Ok(Nil)
    }
    |> result.map(fn(_) { sending })
  })
  case sending {
    False -> Ok(Nil)
    True ->
      case auth.deliver(delivery(auth, email, secret, purpose, code)) {
        Ok(Nil) -> Ok(Nil)
        Error(Nil) -> {
          let _ =
            db.connect(auth.repo, store.delete_challenge(
              _,
              token.digest(secret),
            ))
          Error(service.Internal("auth email delivery failed"))
        }
      }
  }
}

/// Throttle rows are keyed with the installation secret so they do not reveal
/// which addresses have been asking for tokens. They follow the login key, so
/// accounts sharing an address across groups are throttled apart.
fn address_key(auth: Auth, within: Option(String), email: String) -> String {
  token.keyed_digest(auth.throttle_key, account_key(auth, within, email))
}

fn account_key(auth: Auth, within: Option(String), email: String) -> String {
  group.login_key(auth.groups, option.unwrap(within, ""), email)
}

fn purpose_name(purpose: Purpose) -> String {
  case purpose {
    SignIn -> "sign-in"
    Registration -> "registration"
    AlreadyRegistered -> "already-registered"
    EmailChange -> "email-change"
    EmailChangeApproval -> "email-change-approval"
    EmailChanged -> "email-changed"
    PasswordChanged -> "password-changed"
  }
}

fn intent_name(intent: Intent) -> String {
  case intent {
    Login -> "login"
    Register -> "register"
  }
}

fn intent_from(name: String) -> service.Result(Intent) {
  case name {
    "login" -> Ok(Login)
    "register" -> Ok(Register)
    _ -> Error(service.Internal("unknown auth challenge intent"))
  }
}

fn method_name(method: Method) -> String {
  case method {
    EmailToken -> "email"
    Password -> "password"
    Provider(id) -> "provider:" <> id
    Passkey -> "passkey"
    Impersonation -> "impersonation"
  }
}

fn method_from(name: String) -> Method {
  case name {
    "mfa:" <> base -> method_from(base)
    "passkey" -> Passkey
    "impersonation" -> Impersonation
    "password" -> Password
    "provider:" <> id -> Provider(id)
    _ -> EmailToken
  }
}

/// Consume a challenge, verify/create the account and issue a session. The
/// token is spent first, in its own transaction: it can create at most one
/// session even under concurrency, and an exchange that then fails (account
/// exists, suspended, method disabled) does not leave it usable.
pub fn exchange(auth: Auth, secret: String) -> service.Result(Session) {
  exchange_from(auth, secret, "")
}

/// As `exchange`, recording the requesting client on the new session and on
/// the audit events the exchange writes.
pub fn exchange_from(
  auth: Auth,
  secret: String,
  client: String,
) -> service.Result(Session) {
  redeem(auth, secret, client) |> result.try(publish(auth, _))
}

fn redeem(
  auth: Auth,
  secret: String,
  client: String,
) -> service.Result(Issued) {
  use _ <- result.try(valid_token(secret))
  use consumed <- result.try({
    use conn <- db.transaction(auth.repo)
    store.consume_challenge(conn, token.digest(secret), token.now())
  })
  redeem_challenge(auth, consumed, client)
}

/// A code is tried against the address it was sent to. Every guess spends the
/// same budgets as a password guess first, so codes add no guessing capacity
/// of their own beyond the three each emailed code allows.
fn redeem_code(
  auth: Auth,
  email: String,
  code: String,
  client: String,
) -> service.Result(Issued) {
  use _ <- result.try(case email_codes_enabled(auth) {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  })
  use email <- result.try(
    address.normalize_email(email)
    |> result.replace_error(service.Unauthorized),
  )
  let code = string.trim(code)
  use _ <- result.try(
    case
      string.length(code) == 6
      && list.all(string.to_graphemes(code), string.contains("0123456789", _))
    {
      True -> Ok(Nil)
      False -> Error(service.Unauthorized)
    },
  )
  use within <- result.try(target(auth, False))
  let address_key = address_key(auth, within, email)
  let client_key =
    token.keyed_digest(
      auth.throttle_key,
      account_key(auth, within, email) <> "\u{0}" <> client,
    )
  use _ <- result.try(password_attempt(auth, address_key, client_key))
  use consumed <- result.try({
    use conn <- db.transaction(auth.repo)
    store.take_code(
      conn,
      email,
      email_code_digest(auth, email, code),
      token.now(),
    )
  })
  use issued <- result.try(redeem_challenge(auth, consumed, client))
  let _ =
    db.transaction(auth.repo, fn(conn) {
      use _ <- result.try(store.clear_password_attempts(conn, address_key))
      store.clear_password_client(conn, client_key)
    })
  Ok(issued)
}

fn redeem_challenge(
  auth: Auth,
  consumed: List(store.Challenge),
  client: String,
) -> service.Result(Issued) {
  use challenge <- result.try(case consumed {
    [value] -> Ok(value)
    _ -> Error(service.Unauthorized)
  })
  use _ <- result.try(require_email_tokens(auth))
  use intent <- result.try(intent_from(challenge.intent))
  use _ <- result.try(case challenge.group_id {
    Some(id) -> in_bound_group(auth, id)
    None -> Ok(Nil)
  })
  use _ <- result.try(case challenge.password_hash {
    Some(_) -> passwords(auth) |> result.map(fn(_) { Nil })
    None -> Ok(Nil)
  })
  // Only a registration carries a passkey. Its WebAuthn user handle is the id
  // the ceremony chose, so the account has to be created under that id.
  use key <- result.try(case challenge.passkey, intent {
    Some(encoded), Register -> {
      use _ <- result.try(passkey_config(auth))
      passkey.decode(encoded) |> result.map(Some)
    }
    _, _ -> Ok(None)
  })
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use _ <- result.try(case intent {
    Register ->
      register(
        conn,
        auth,
        option.map(key, fn(key) { key.user_id }),
        challenge.email,
        challenge.group_id,
        client,
      )
    Login -> Ok(Nil)
  })
  use users <- result.try(store.active_user_by_email(
    conn,
    challenge.email,
    challenge.group_id,
  ))
  use user <- result.try(case users {
    [value] -> Ok(value)
    _ -> Error(service.Unauthorized)
  })
  use _ <- result.try(in_bound_group(auth, user.group_id))
  use _ <- result.try(case challenge.password_hash {
    Some(encoded) ->
      store.insert_password(conn, user.id, encoded, challenge.normalized)
    None -> Ok(Nil)
  })
  use _ <- result.try(case key {
    Some(key) if key.user_id == user.id -> {
      use _ <- result.try(security_store.add_passkey(conn, key))
      event_from(
        conn,
        user.id,
        "passkey.registered",
        System,
        key.info.id,
        client,
      )
    }
    Some(_) -> Error(service.Unauthorized)
    None -> Ok(Nil)
  })
  // Redeeming a token proves control of the address, so its back-off ends.
  use _ <- result.try(store.clear_email_throttle(
    conn,
    address_key(auth, Some(user.group_id), challenge.email),
  ))
  issue_session(conn, auth, user, EmailToken, client)
}

/// A session the database has committed to, and the entry an external store
/// has yet to be given.
type Issued {
  Issued(session: Session, entry: Entry)
  Pending(challenge: MfaChallenge)
}

fn issue_session(
  conn: Repo,
  auth: Auth,
  user: User,
  method: Method,
  client: String,
) -> service.Result(Issued) {
  use _ <- result.try(sso_permits(conn, user, method_name(method)))
  use factor <- result.try(security_store.factor(conn, user.id))
  case factor {
    None ->
      issue_verified_session(conn, auth, user, method_name(method), client)
    Some(_) -> {
      use _ <- result.try(mfa_config(auth))
      let challenge = token.new()
      use version <- result.try(account_store.version(conn, user.id))
      use _ <- result.try(security_store.add_pending(
        conn,
        token.digest(challenge),
        security_store.Pending(
          user.id,
          version,
          user.group_id,
          method_name(method),
          client,
          "",
          0,
        ),
      ))
      Ok(Pending(MfaChallenge(secret.wrap(challenge))))
    }
  }
}

/// A session for a connection whose provider's MFA is trusted. The method is
/// the provider alone, never "mfa:": the Howdy factor was not proven, so the
/// session cannot manage it. Skipping a factor the user has is audited.
fn issue_trusting_provider(
  conn: Repo,
  auth: Auth,
  user: User,
  id: String,
  client: String,
) -> service.Result(Issued) {
  use factor <- result.try(security_store.factor(conn, user.id))
  use _ <- result.try(case factor {
    None -> Ok(Nil)
    Some(_) ->
      event_from(conn, user.id, "mfa.provider_trusted", System, id, client)
  })
  issue_verified_session(conn, auth, user, method_name(Provider(id)), client)
}

/// A member covered by an enforced SSO connection signs in through it and no
/// other way. Every sign-in ends at a session, so this is the one gate. The
/// refusal is Unauthorized, as for a wrong credential: a right password must
/// not be distinguishable from a wrong one by an account that may not use it.
/// It reads no SSO configuration, so enforcement holds (and covered members
/// are locked out, visibly) if a deployment forgets `with_sso`.
fn sso_permits(conn: Repo, user: User, method: String) -> service.Result(Nil) {
  use enforcing <- result.try(connection_store.enforcing(
    conn,
    user.email,
    Some(user.group_id),
  ))
  case enforcing {
    None -> Ok(Nil)
    Some(id) -> {
      // After a second factor the method is recorded as "mfa:" <> the first.
      let first = case method {
        "mfa:" <> first -> first
        first -> first
      }
      case first == method_name(Provider(connection.identity_issuer(id))) {
        True -> Ok(Nil)
        False -> Error(service.Unauthorized)
      }
    }
  }
}

fn issue_verified_session(
  conn: Repo,
  auth: Auth,
  user: User,
  method: String,
  client: String,
) -> service.Result(Issued) {
  // Again here: a second factor may finish after enforcement began.
  use _ <- result.try(sso_permits(conn, user, method))
  create_session(conn, auth, user, method, client)
}

/// Record a session for a user whose right to one has been established.
fn create_session(
  conn: Repo,
  auth: Auth,
  user: User,
  method: String,
  client: String,
) -> service.Result(Issued) {
  let now = token.now()
  let session =
    Session(user, secret.wrap(token.new()), now + auth.policy.session_seconds)
  use version <- result.try(account_store.version(conn, user.id))
  let entry =
    Entry(
      digest: token.digest(secret.reveal(session.token)),
      user_id: user.id,
      method: method,
      created_at: now,
      last_seen_at: now,
      expires_at: session.expires_at,
      client:,
      version:,
    )
  use _ <- result.try(case auth.sessions {
    InDatabase ->
      store.insert_session(
        conn,
        digest: entry.digest,
        user_id: entry.user_id,
        method: entry.method,
        now:,
        expires_at: entry.expires_at,
        client:,
      )
    External(_) -> Ok(Nil)
  })
  use _ <- result.try(event_from(
    conn,
    user.id,
    "session.created",
    System,
    method,
    client,
  ))
  Ok(Issued(session, entry))
}

/// Hand a committed session to the external store, if there is one.
fn publish(auth: Auth, issued: Issued) -> service.Result(Session) {
  case issued {
    Pending(_) -> Error(service.Forbidden)
    Issued(session, entry) ->
      case auth.sessions {
        InDatabase -> Ok(session)
        External(external) -> external.insert(entry) |> result.replace(session)
      }
  }
}

fn publish_step(auth: Auth, issued: Issued) -> service.Result(LoginStep) {
  case issued {
    Pending(challenge) -> Ok(SecondFactor(challenge))
    Issued(_, _) -> publish(auth, issued) |> result.map(SignedIn)
  }
}

/// Run against the external store, if there is one.
fn externally(
  auth: Auth,
  run: fn(SessionStore) -> service.Result(Nil),
) -> service.Result(Nil) {
  case auth.sessions {
    InDatabase -> Ok(Nil)
    External(external) -> run(external)
  }
}

/// Commit a database change, then revoke in the external store. In that
/// order, so a session revoked because a credential or suspension changed
/// cannot be recreated under the old rules in between.
fn after_commit(
  auth: Auth,
  revoke: fn(SessionStore) -> service.Result(Nil),
  commit: fn() -> service.Result(Nil),
) -> service.Result(Nil) {
  use _ <- result.try(commit())
  externally(auth, revoke)
}

/// Authenticate by email and password. Wrong, unknown, email-only and suspended
/// accounts all receive Unauthorized. This compatibility entry point uses a
/// shared headless client bucket. Custom transports should isolate clients with
/// `login_password_from` and enforce their own overall client/load limits.
pub fn login_password(
  auth: Auth,
  email: String,
  password: String,
) -> service.Result(Session) {
  login_password_from(auth, email, password, "headless")
}

/// Use a trusted, stable client identity (normally the socket IP or an ingress
/// header) to isolate password back-off. The compatibility wrapper shares a
/// headless bucket; custom transports should call this operation instead.
pub fn login_password_from(
  auth: Auth,
  email: String,
  password: String,
  client: String,
) -> service.Result(Session) {
  verify_password(auth, email, password, client)
  |> result.try(publish(auth, _))
}

fn verify_password(
  auth: Auth,
  email: String,
  password: String,
  client: String,
) -> service.Result(Issued) {
  use hasher <- result.try(passwords(auth))
  use email <- result.try(
    address.normalize_email(email)
    |> result.map_error(fn(_) { service.Unauthorized }),
  )
  use _ <- result.try(
    case
      string.byte_size(password) > 0
      && string.byte_size(password) <= policy.password_max_bytes
    {
      True -> Ok(Nil)
      False -> Error(service.Unauthorized)
    },
  )
  use within <- result.try(target(auth, False))
  let address_key = address_key(auth, within, email)
  let client_key =
    token.keyed_digest(
      auth.throttle_key,
      account_key(auth, within, email) <> "\u{0}" <> client,
    )
  use _ <- result.try(password_attempt(auth, address_key, client_key))
  use found <- result.try(
    db.connect(auth.repo, store.password_candidates(_, email, within)),
  )
  let #(encoded, normalized) = case found {
    [#(_, encoded, normalized)] -> #(encoded, normalized)
    _ -> #(password_hash.dummy(hasher), True)
  }
  // Argus verification runs outside the transaction and performs the same
  // expensive work for missing accounts, avoiding a fast unknown-user path.
  use #(valid, legacy_input) <- result.try(password_hash.verify(
    encoded,
    password,
    normalized,
  ))
  case valid, found {
    True, [#(candidate, _, _)] -> {
      use upgraded <- result.try(
        case password_hash.needs_rehash(encoded) || legacy_input {
          True ->
            password_hash.rehash(hasher, encoded, password) |> result.map(Some)
          False -> Ok(None)
        },
      )
      use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
      // Recheck the credential and lock the account after hashing, so
      // suspension or a concurrent credential replacement cannot issue a
      // stale session.
      use users <- result.try(store.active_user_with_password(
        conn,
        candidate.id,
        encoded,
        normalized,
      ))
      // The login identifier may have changed while Argon2 was running.
      use user <- result.try(case users {
        [user] if user.email == email && user.group_id == candidate.group_id ->
          Ok(user)
        _ -> Error(service.Unauthorized)
      })
      use _ <- result.try(store.clear_password_attempts(conn, address_key))
      use _ <- result.try(store.clear_password_client(conn, client_key))
      use _ <- result.try(case upgraded {
        Some(hash) -> store.replace_password(conn, user.id, hash)
        None ->
          case normalized {
            True -> Ok(Nil)
            False -> store.mark_password_normalized(conn, user.id)
          }
      })
      issue_session(conn, auth, user, Password, client)
    }
    False, [#(candidate, _, _)] -> {
      // Committed on its own: there is no surrounding transaction to roll back.
      let _ =
        db.connect(auth.repo, event_from(
          _,
          candidate.id,
          "login.failed",
          System,
          "",
          client,
        ))
      Error(service.Unauthorized)
    }
    _, _ -> Error(service.Unauthorized)
  }
}

fn password_attempt(
  auth: Auth,
  address_key: String,
  client_key: String,
) -> service.Result(Nil) {
  // Pair reservation and address ceiling each commit before verification.
  use _ <- result.try({
    use conn <- db.transaction(auth.repo)
    store.reserve_password_client(
      conn,
      client_key,
      address_key,
      token.now(),
      auth.policy,
    )
  })
  // Commit the attempt counter independently, including failed logins.
  use attempts <- result.try({
    use conn <- db.transaction(auth.repo)
    store.count_password_attempt(conn, address_key, token.now(), auth.policy)
  })
  case attempts {
    [n] if n <= auth.policy.password_account_attempts -> Ok(Nil)
    _ -> Error(service.TooManyRequests(auth.policy.password_window_seconds))
  }
}

/// Set, replace or reset the caller's password. One operation covers all three
/// because the proof is the same: the session must have been created by an
/// email-token exchange within `policy.fresh_session_seconds`. A password
/// session or an older session receives Forbidden; request a login token,
/// exchange it, then call this. Every other session of the user is revoked.
pub fn set_password(
  auth: Auth,
  principal: Principal,
  password: String,
) -> service.Result(Nil) {
  use hasher <- result.try(passwords(auth))
  use _ <- result.try(validate_new_password(auth, password))
  let fresh = fn(conn) {
    let now = token.now()
    let created_after = now - auth.policy.fresh_session_seconds
    use fresh <- result.try(case auth.sessions {
      InDatabase ->
        store.fresh_email_session(
          conn,
          principal.session_id,
          principal.user.id,
          now,
          created_after,
        )
      External(external) -> {
        use entry <- result.try(external.get(principal.session_id))
        use users <- result.try(store.active_user(
          conn,
          principal.user.id,
          locking: True,
        ))
        use version <- result.try(account_store.version(conn, principal.user.id))
        Ok(case entry, users {
          Some(entry), [_] ->
            entry.version == version
            && entry.user_id == principal.user.id
            && method_from(entry.method) == EmailToken
            && entry.expires_at > now
            && entry.created_at > created_after
          _, _ -> False
        })
      }
    })
    case fresh {
      True -> Ok(Nil)
      False -> Error(service.Forbidden)
    }
  }
  // Refuse before paying for a hash, then check again under the row lock.
  use _ <- result.try(db.connect(auth.repo, fresh))
  use encoded <- result.try(password_hash.hash(hasher, password))
  // Revoked after the commit: from then on the old password opens no more.
  use <- after_commit(auth, fn(external) {
    external.delete_for_user(principal.user.id, Some(principal.session_id))
  })
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use _ <- result.try(fresh(conn))
  use _ <- result.try(store.replace_password(conn, principal.user.id, encoded))
  use _ <- result.try(store.delete_other_sessions(
    conn,
    principal.user.id,
    principal.session_id,
  ))
  use _ <- result.try(store.clear_password_attempts(
    conn,
    address_key(auth, Some(principal.user.group_id), principal.user.email),
  ))
  use _ <- result.try(store.clear_password_clients(
    conn,
    address_key(auth, Some(principal.user.group_id), principal.user.email),
  ))
  use _ <- result.try(security_store.clear(conn, principal.user.id))
  event(conn, principal.user.id, "password.set", Acting(principal), "")
}

/// Replace the caller's password by proving the current one. Unlike
/// `set_password` this needs no fresh email login, so it also serves
/// deployments without email tokens. A wrong current password is Invalid, not
/// Unauthorized: the session itself is still good. Guesses spend the same
/// per-client and per-address budget as password logins, so a borrowed session
/// cannot search for the password faster than the login form could. An account
/// without a password receives Forbidden and must use `set_password`.
///
/// Every other session and remembered device of the user is revoked, and the
/// address is sent a `PasswordChanged` notice on a best-effort basis.
pub fn change_password(
  auth: Auth,
  principal: Principal,
  current current: String,
  new new: String,
) -> service.Result(Nil) {
  change_password_from(auth, principal, current, new, "headless")
}

/// As `change_password`, isolating back-off by a trusted client identity; see
/// `login_password_from`.
pub fn change_password_from(
  auth: Auth,
  principal: Principal,
  current current: String,
  new new: String,
  client client: String,
) -> service.Result(Nil) {
  use hasher <- result.try(passwords(auth))
  let wrong = service.Invalid("current password is incorrect")
  use _ <- result.try(
    case
      string.byte_size(current) > 0
      && string.byte_size(current) <= policy.password_max_bytes
    {
      True -> Ok(Nil)
      False -> Error(wrong)
    },
  )
  use _ <- result.try(case current == new {
    True -> Error(service.Invalid("new password must differ from the current"))
    False -> Ok(Nil)
  })
  use _ <- result.try(validate_new_password(auth, new))
  let user = principal.user
  let within = Some(user.group_id)
  let address_key = address_key(auth, within, user.email)
  let client_key =
    token.keyed_digest(
      auth.throttle_key,
      account_key(auth, within, user.email) <> "\u{0}" <> client,
    )
  use found <- result.try(
    db.connect(auth.repo, store.password_candidates(_, user.email, within)),
  )
  use #(encoded, normalized) <- result.try(case found {
    [#(candidate, encoded, normalized)] if candidate.id == user.id ->
      Ok(#(encoded, normalized))
    _ -> Error(service.Forbidden)
  })
  use _ <- result.try(password_attempt(auth, address_key, client_key))
  use #(valid, _) <- result.try(password_hash.verify(
    encoded,
    current,
    normalized,
  ))
  use _ <- result.try(case valid {
    True -> Ok(Nil)
    False -> {
      let _ =
        db.connect(auth.repo, event_from(
          _,
          user.id,
          "password.change_failed",
          Acting(principal),
          "",
          client,
        ))
      Error(wrong)
    }
  })
  use replacement <- result.try(password_hash.hash(hasher, new))
  // The notice follows the commit even when external session cleanup fails.
  use <- after_commit(auth, fn(external) {
    external.delete_for_user(user.id, Some(principal.session_id))
  })
  use _ <- result.try({
    use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
    // Lock the account and recheck both proofs after hashing: the session may
    // have been revoked, or the password replaced, while Argon2 was running.
    use _ <- result.try(current_account(conn, auth, principal, False))
    use users <- result.try(store.active_user_with_password(
      conn,
      user.id,
      encoded,
      normalized,
    ))
    use _ <- result.try(case users {
      [_] -> Ok(Nil)
      _ -> Error(wrong)
    })
    use _ <- result.try(store.replace_password(conn, user.id, replacement))
    use _ <- result.try(store.delete_other_sessions(
      conn,
      user.id,
      principal.session_id,
    ))
    use _ <- result.try(store.clear_password_attempts(conn, address_key))
    use _ <- result.try(store.clear_password_clients(conn, address_key))
    use _ <- result.try(security_store.clear(conn, user.id))
    event_from(conn, user.id, "password.changed", Acting(principal), "", client)
  })
  let _ = auth.deliver(delivery(auth, user.email, "", PasswordChanged, None))
  Ok(Nil)
}

fn register(
  conn: Repo,
  auth: Auth,
  id: Option(String),
  email: String,
  within: Option(String),
  client: String,
) -> service.Result(Nil) {
  use _ <- result.try(case auth.registration {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  })
  enroll_as(
    conn,
    auth,
    option.lazy_unwrap(id, token.new),
    email,
    within,
    client,
  )
}

/// Registration itself, once the caller has decided it is allowed.
fn enroll(
  conn: Repo,
  auth: Auth,
  email: String,
  within: Option(String),
  client: String,
) -> service.Result(Nil) {
  enroll_as(conn, auth, token.new(), email, within, client)
}

fn enroll_as(
  conn: Repo,
  auth: Auth,
  id: String,
  email: String,
  within: Option(String),
  client: String,
) -> service.Result(Nil) {
  // A token from before groups existed names none.
  use group_id <- result.try(case auth.groups, within {
    _, Some(id) -> Ok(id)
    Single, None -> Ok(group.default_id)
    _, None -> Error(service.Unauthorized)
  })
  // Locked, so the group cannot be deleted before the user is in it.
  use found <- result.try(store.find_group(conn, group_id))
  use _ <- result.try(case found {
    [_] -> Ok(Nil)
    _ -> Error(service.Unauthorized)
  })
  let login_key = group.login_key(auth.groups, group_id, email)
  use taken <- result.try(store.login_key_taken(conn, login_key))
  use _ <- result.try(case taken {
    False -> Ok(Nil)
    True -> Error(service.Unauthorized)
  })
  use _ <- result.try(store.insert_user(
    conn,
    id:,
    email:,
    group_id:,
    login_key:,
  ))
  event_from(conn, id, "user.registered", System, group_id, client)
}

/// Privileged operation: create a user without asking them, for an
/// invitation, an import or a directory sync. Authorize the caller first. It
/// works whether or not public registration is enabled, and sends nothing:
/// the user signs in with a login token when they are ready, which is also
/// what proves the address is theirs. The group is chosen as for
/// registration, so outside `Single` use `auth.in_group`:
///
/// ```gleam
/// auth.provision(auth.in_group(identity, "acme"), email, by: user.System)
/// ```
///
/// Conflict when the address already has an account where it must be unique.
pub fn provision(
  auth: Auth,
  email: String,
  by actor: Actor,
) -> service.Result(User) {
  provision_with(auth, email, fields: [], by: actor)
}

/// As `provision`, setting fields on the new user in the same transaction;
/// see `howdy/auth/field`. Conflict when a unique value is taken.
pub fn provision_with(
  auth: Auth,
  email: String,
  fields changes: List(Change),
  by actor: Actor,
) -> service.Result(User) {
  use email <- result.try(address.normalize_email(email))
  use within <- result.try(target(auth, True))
  let group_id = option.unwrap(within, group.default_id)
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  // Locked, so the group cannot be deleted before the user is in it.
  use found <- result.try(store.find_group(conn, group_id))
  use _ <- result.try(case found {
    [_] -> Ok(Nil)
    _ -> Error(service.NotFound("group"))
  })
  let login_key = group.login_key(auth.groups, group_id, email)
  use taken <- result.try(store.login_key_taken(conn, login_key))
  use _ <- result.try(case taken {
    False -> Ok(Nil)
    True ->
      Error(service.Conflict("an account already exists for this address"))
  })
  use writes <- result.try(field.writes(changes, Some(group_id)))
  let id = token.new()
  use created <- result.try(store.insert_user(
    conn,
    id:,
    email:,
    group_id:,
    login_key:,
  ))
  use _ <- result.try(case writes {
    [] -> Ok(Nil)
    _ ->
      store.write_fields(conn, store.of_user, id, writes)
      |> result.replace(Nil)
  })
  use _ <- result.try(event(conn, id, "user.provisioned", actor, group_id))
  Ok(created)
}

fn valid_token(secret: String) -> service.Result(Nil) {
  case string.byte_size(secret) == token_bytes {
    True -> Ok(Nil)
    False -> Error(service.Unauthorized)
  }
}

/// Verify a session token. The returned principal records no client, so audit
/// events it causes do not say where the request came from; prefer
/// `authenticate_from`, or `required`, which reads it from the request.
pub fn authenticate(auth: Auth, secret: String) -> service.Result(Principal) {
  authenticate_from(auth, secret, "")
}

/// As `authenticate`, recording the requesting client on the principal so the
/// operations it performs are audited with it.
pub fn authenticate_from(
  auth: Auth,
  secret: String,
  client: String,
) -> service.Result(Principal) {
  use _ <- result.try(valid_token(secret))
  authenticate_digest(auth, token.digest(secret), client)
}

fn authenticate_digest(
  auth: Auth,
  digest: String,
  client: String,
) -> service.Result(Principal) {
  let now = token.now()
  let seen_after = case auth.policy.session_idle_seconds {
    0 -> -1
    idle -> now - idle
  }
  let touch_due = fn(last_seen_at) { last_seen_at <= now - touch_seconds }
  // Renewal rides on the throttled touch, so it costs no further writes. The
  // expiry was last set `session_seconds` before it falls due; one that is
  // already later than renewal would make it (a lowered policy) is kept.
  let renewed = fn(created_at, expires_at) {
    let policy = auth.policy
    let due =
      policy.session_renew_seconds > 0
      && expires_at - now
      <= policy.session_seconds - policy.session_renew_seconds
    let target = case policy.session_max_seconds {
      0 -> now + policy.session_seconds
      max -> int.min(now + policy.session_seconds, created_at + max)
    }
    case due {
      True -> int.max(expires_at, target)
      False -> expires_at
    }
  }
  use user <- result.try(case auth.sessions {
    InDatabase -> {
      use conn <- db.connect(auth.repo)
      use found <- result.try(store.session_user(conn, digest, now, seen_after))
      case found {
        [#(user, last_seen_at, created_at, expires_at)] ->
          case touch_due(last_seen_at) {
            True ->
              store.touch_session(
                conn,
                digest,
                now,
                renewed(created_at, expires_at),
              )
            False -> Ok(Nil)
          }
          |> result.replace(user)
        _ -> Error(service.Unauthorized)
      }
    }
    External(external) -> {
      use entry <- result.try(external.get(digest))
      use entry <- result.try(case entry {
        Some(entry)
          if entry.expires_at > now && entry.last_seen_at > seen_after
        -> Ok(entry)
        _ -> Error(service.Unauthorized)
      })
      // The store says who; the database says whether they still may.
      use users <- result.try(
        db.connect(auth.repo, store.active_user(
          _,
          entry.user_id,
          locking: False,
        )),
      )
      use version <- result.try(
        db.connect(auth.repo, account_store.version(_, entry.user_id)),
      )
      use _ <- result.try(case version == entry.version {
        True -> Ok(Nil)
        False -> Error(service.Unauthorized)
      })
      case users {
        [user] ->
          case touch_due(entry.last_seen_at) {
            True ->
              external.touch(
                digest,
                now,
                renewed(entry.created_at, entry.expires_at),
              )
            False -> Ok(Nil)
          }
          |> result.replace(user)
        _ -> Error(service.Unauthorized)
      }
    }
  })
  use _ <- result.try(in_bound_group(auth, user.group_id))
  Ok(Principal(user, digest, client))
}

/// A typed controller/endpoint guard. Ambiguous credentials are rejected.
/// Cookie-authenticated writes require the configured Origin, protecting
/// application routes as well as the module's own routes against CSRF.
/// Audit events record the socket address; behind a proxy that is the proxy
/// for everyone, so use `required_from` with the header your ingress sets.
pub fn required(auth: Auth) -> fn(Context(a)) -> service.Result(Principal) {
  required_from(auth, fn(ctx: Context(a)) { context.client_ip(ctx.request) })
}

/// As `required`, identifying the client with `key`. Only read a header your
/// ingress overwrites; a client-supplied value can claim to be anyone.
pub fn required_from(
  auth: Auth,
  key: fn(Context(a)) -> Option(String),
) -> fn(Context(a)) -> service.Result(Principal) {
  fn(ctx: Context(a)) {
    let client = option.unwrap(key(ctx), "")
    let headers =
      list.filter(ctx.request.headers, fn(h) {
        string.lowercase(h.0) == "authorization"
      })
    let cookies =
      request.get_cookies(ctx.request)
      |> list.filter(fn(c) { c.0 == cookie_name(auth) })
    case headers, cookies {
      [#(_, "Bearer " <> secret)], [] -> authenticate_from(auth, secret, client)
      [], [#(_, secret)] -> {
        use _ <- result.try(case ctx.request.method {
          http.Get | http.Head | http.Options -> Ok(Nil)
          _ -> check_origin(auth, ctx)
        })
        authenticate_from(auth, secret, client)
      }
      _, _ -> Error(service.Unauthorized)
    }
  }
}

/// Require an exact, single Origin. The configured origin is never inferred
/// from Host or forwarded headers.
pub fn check_origin(auth: Auth, ctx: Context(a)) -> service.Result(Nil) {
  case
    list.filter(ctx.request.headers, fn(h) { string.lowercase(h.0) == "origin" })
  {
    [#(_, value)] if value == auth.origin -> Ok(Nil)
    _ -> Error(service.Forbidden)
  }
}

pub fn logout(auth: Auth, principal: Principal) -> service.Result(Nil) {
  use _ <- result.try(
    externally(auth, fn(external) {
      external.delete(principal.session_id, principal.user.id)
    }),
  )
  use conn <- db.transaction(auth.repo)
  use _ <- result.try(store.delete_session(
    conn,
    principal.session_id,
    principal.user.id,
  ))
  event(conn, principal.user.id, "session.revoked", Acting(principal), "")
}

/// The caller's own live sessions, newest first.
pub fn sessions(
  auth: Auth,
  principal: Principal,
) -> service.Result(List(SessionInfo)) {
  let now = token.now()
  use rows <- result.try(case auth.sessions {
    InDatabase ->
      db.connect(auth.repo, store.sessions_for_user(_, principal.user.id, now))
    External(external) -> {
      use entries <- result.try(external.list(principal.user.id))
      use version <- result.try(
        db.connect(auth.repo, account_store.version(_, principal.user.id)),
      )
      entries
      |> list.filter(fn(entry) {
        entry.expires_at > now && entry.version == version
      })
      |> list.sort(fn(a, b) {
        int.compare(b.created_at, a.created_at)
        |> order.break_tie(string.compare(a.digest, b.digest))
      })
      |> list.map(fn(entry) {
        store.SessionRow(
          digest: entry.digest,
          method: entry.method,
          created_at: entry.created_at,
          last_seen_at: entry.last_seen_at,
          expires_at: entry.expires_at,
          client: entry.client,
        )
      })
      |> Ok
    }
  })
  Ok(
    list.map(rows, fn(row) {
      SessionInfo(
        id: row.digest,
        method: method_from(row.method),
        created_at: row.created_at,
        last_seen_at: row.last_seen_at,
        expires_at: row.expires_at,
        current: row.digest == principal.session_id,
        client: row.client,
      )
    }),
  )
}

/// Revoke one of the caller's own sessions by `SessionInfo.id`. Another
/// user's session is never affected; an unknown id is not an error.
pub fn revoke_session(
  auth: Auth,
  principal: Principal,
  session_id: String,
) -> service.Result(Nil) {
  use _ <- result.try(
    externally(auth, fn(external) {
      external.delete(session_id, principal.user.id)
    }),
  )
  use conn <- db.transaction(auth.repo)
  use _ <- result.try(store.delete_session(conn, session_id, principal.user.id))
  event(conn, principal.user.id, "session.revoked", Acting(principal), "")
}

/// Privileged operation: authorize the caller before invoking it.
pub fn revoke_sessions(
  auth: Auth,
  user_id: String,
  by actor: Actor,
) -> service.Result(Nil) {
  use <- after_commit(auth, fn(external) {
    external.delete_for_user(user_id, None)
  })
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use _ <- result.try(store.require_user(conn, user_id))
  use _ <- result.try(store.delete_sessions(conn, user_id))
  event(conn, user_id, "sessions.revoked", actor, "")
}

/// Privileged operation. Suspension revokes all sessions atomically; resuming
/// the user never restores old sessions.
pub fn suspend(
  auth: Auth,
  user_id: String,
  by actor: Actor,
) -> service.Result(Nil) {
  use <- after_commit(auth, fn(external) {
    external.delete_for_user(user_id, None)
  })
  use <- cache.changing
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use _ <- result.try(store.require_user(conn, user_id))
  use _ <- result.try(store.set_suspended(conn, user_id, True))
  use _ <- result.try(store.delete_sessions(conn, user_id))
  use _ <- result.try(store.delete_challenges_for_user(conn, user_id))
  use _ <- result.try(account_store.clear_pending(conn, user_id))
  event(conn, user_id, "user.suspended", actor, "")
}

/// Privileged operation: authorize the caller before invoking it.
pub fn resume(
  auth: Auth,
  user_id: String,
  by actor: Actor,
) -> service.Result(Nil) {
  // A suspension whose external revocation failed must not come back to life.
  use _ <- result.try(
    externally(auth, fn(external) { external.delete_for_user(user_id, None) }),
  )
  use <- cache.changing
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use _ <- result.try(store.require_user(conn, user_id))
  use _ <- result.try(store.set_suspended(conn, user_id, False))
  event(conn, user_id, "user.resumed", actor, "")
}

/// A session for `user_id` without a credential, for operators and
/// development tooling that act as a user. Privileged: authorize the caller
/// before invoking it, and never expose it over an unauthenticated route.
/// The session's method is `Impersonation`, and the audit trail records
/// `session.impersonated` with the actor. It skips second factors and SSO
/// enforcement, which is why it must not be reachable by the user. Suspended
/// users cannot be impersonated.
pub fn impersonate(
  auth: Auth,
  user_id: String,
  by actor: Actor,
) -> service.Result(Session) {
  use issued <- result.try({
    use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
    use users <- result.try(store.active_user(conn, user_id, locking: True))
    use user <- result.try(case users {
      [value] -> Ok(value)
      _ -> Error(service.NotFound("user"))
    })
    use _ <- result.try(in_bound_group(auth, user.group_id))
    use _ <- result.try(event(conn, user.id, "session.impersonated", actor, ""))
    create_session(
      conn,
      auth,
      user,
      method_name(Impersonation),
      user.actor_client(actor),
    )
  })
  publish(auth, issued)
}

/// Count the per-client limits of every auth route (`routes.api`,
/// `routes.providers`, `routes.sso`) in the auth database, so that nodes
/// behind a load balancer share them and a restart does not reset them. Each
/// limited request then costs one write. Without this, each node counts on
/// its own. Needs migration **17**. Password, code and second-factor guessing
/// limits are always shared; this is the coarser per-client ceiling in front.
pub fn with_shared_rate_limits(auth: Auth) -> Auth {
  Auth(..auth, rate_limits: Some(rate_limit_store(auth)))
}

/// As `with_shared_rate_limits`, counting in a store of your own, such as
/// Redis, instead of the auth database.
pub fn with_rate_limit_store(auth: Auth, store: rate_limit.Store) -> Auth {
  Auth(..auth, rate_limits: Some(store))
}

/// The auth database as a `rate_limit.Store`, for sharing the application's
/// own limiters between nodes too. Give each `rate_limit.shared` limiter a
/// name not starting `howdy_auth.`.
pub fn rate_limit_store(auth: Auth) -> rate_limit.Store {
  rate_limit_store.new(auth.repo)
}

/// A limiter for the auth routes: shared when configured, else this node's.
@internal
pub fn limiter(
  auth: Auth,
  name: String,
  limit: Int,
  per_seconds: Int,
) -> rate_limit.Limiter {
  case auth.rate_limits {
    Some(store) ->
      rate_limit.shared(
        limit:,
        per_seconds:,
        name: "howdy_auth." <> name,
        store:,
      )
    None -> rate_limit.fixed_window(limit:, per_seconds:)
  }
}

/// Housekeeping for a scheduled job. Expired rows are already removed as a
/// side effect of normal traffic; this covers quiet installations.
pub fn prune_expired(auth: Auth) -> service.Result(Nil) {
  use _ <- result.try(
    externally(auth, fn(external) { external.prune(token.now()) }),
  )
  use conn <- db.transaction(auth.repo)
  use _ <- result.try(rate_limit_store.delete_expired(conn, token.now() * 1000))
  store.delete_expired(conn, token.now(), auth.policy)
}

/// Apply an audit retention period: delete events that occurred before the
/// given Unix time in seconds. Export them first if they must be kept.
pub fn prune_events(auth: Auth, before before: Int) -> service.Result(Nil) {
  use conn <- db.transaction(auth.repo)
  store.delete_events_before(conn, before)
}

/// Record an audit event on the caller's connection, so it commits or rolls
/// back with the change it describes. The client is taken from the actor,
/// which for `Acting` is the principal's own request.
@internal
pub fn event(
  conn: Repo,
  user_id: String,
  action: String,
  actor: Actor,
  detail: String,
) -> service.Result(Nil) {
  event_from(conn, user_id, action, actor, detail, user.actor_client(actor))
}

/// As `event`, for the self-service flows that know the request's client
/// before there is a principal to carry it.
@internal
pub fn event_from(
  conn: Repo,
  user_id: String,
  action: String,
  actor: Actor,
  detail: String,
  client: String,
) -> service.Result(Nil) {
  store.insert_event(
    conn,
    user_id:,
    action:,
    actor_id: user.actor_id(actor),
    detail:,
    client:,
  )
}

/// Construct auth without email tokens. Add built-in providers with
/// `with_provider`. Registration remains disabled until explicitly enabled.
pub fn new_without_email(
  repo repo: Repo,
  origin origin: String,
) -> service.Result(Auth) {
  use auth <- result.try(new(repo, origin, fn(_) { Error(Nil) }))
  Ok(Auth(..auth, email_tokens: False))
}

/// Enable email tokens on a runtime constructed without email.
pub fn with_email_tokens(
  auth: Auth,
  deliver deliver: fn(Delivery) -> Result(Nil, Nil),
) -> Auth {
  Auth(..auth, deliver:, email_tokens: True)
}

pub fn email_tokens_enabled(auth: Auth) -> Bool {
  auth.email_tokens
}

/// Put a link in each emailed token's `Delivery`, beside the token, to the
/// starter pages mounted `at` this path, such as "/auth". A sign-in link opens
/// `<path>/login`; an email-change link opens `<path>/account`. The token
/// travels in the URL fragment (`#token=`, `#email-confirm=` or
/// `#email-approve=`), which browsers never send to a server, so it stays out
/// of access logs and `Referer` headers. The pages fill it in and wait for a
/// click, so a mail scanner that opens links spends nothing. Custom pages at
/// that path can read the same fragments.
pub fn with_email_links(auth: Auth, at path: String) -> service.Result(Auth) {
  case
    string.starts_with(path, "/")
    && !string.ends_with(path, "/")
    && list.all(string.to_graphemes(path), fn(c) {
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-_",
        c,
      )
    })
  {
    True -> Ok(Auth(..auth, email_links: Some(path)))
    False ->
      Error(service.Invalid(
        "email link path must be absolute, without a trailing slash, using letters, digits, '/', '-' and '_'",
      ))
  }
}

/// Email a six-digit code beside each sign-in or registration token, for a
/// reader who would rather type than paste; see `exchange_code_step`. A code
/// is weaker than a token, so it only works with its address, dies after
/// three wrong guesses, and every guess counts against the same per-address
/// and per-client limits as a password. Anyone who can read the auth database
/// can recover a live code from its digest by trying all million, which a
/// token's digest does not allow; leave codes off if that matters.
pub fn with_email_codes(auth: Auth) -> Auth {
  Auth(..auth, email_codes: True)
}

pub fn email_codes_enabled(auth: Auth) -> Bool {
  auth.email_tokens && auth.email_codes
}

fn delivery(
  auth: Auth,
  email: String,
  token: String,
  purpose: Purpose,
  code: Option(String),
) -> Delivery {
  let page = case purpose {
    SignIn | Registration | AlreadyRegistered -> Some("/login#token=")
    EmailChange -> Some("/account#email-confirm=")
    EmailChangeApproval -> Some("/account#email-approve=")
    EmailChanged | PasswordChanged -> None
  }
  let link = case auth.email_links, page {
    Some(path), Some(page) ->
      Some(secret.wrap(auth.origin <> path <> page <> token))
    _, _ -> None
  }
  Delivery(
    email,
    secret.wrap(token),
    purpose,
    link,
    option.map(code, secret.wrap),
  )
}

fn email_code_digest(auth: Auth, email: String, code: String) -> String {
  token.keyed_digest(
    auth.throttle_key,
    "email-code\u{0}" <> email <> "\u{0}" <> code,
  )
}

fn require_email_tokens(auth: Auth) -> service.Result(Nil) {
  case auth.email_tokens {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  }
}

/// Install a built-in provider once at startup. Duplicate IDs are rejected.
pub fn with_provider(
  auth: Auth,
  provider: provider.Provider,
) -> service.Result(Auth) {
  use _ <- result.try(provider.validate(provider))
  let issuer = provider.issuer(provider)
  case
    list.any(auth.providers, fn(p) { provider.id(p) == provider.id(provider) }),
    option.is_some(issuer)
    && list.any(auth.providers, fn(p) { provider.issuer(p) == issuer })
  {
    True, _ -> Error(service.Invalid("provider is already configured"))
    _, True ->
      Error(service.Invalid("another provider already uses this issuer"))
    False, False ->
      Ok(Auth(..auth, providers: list.append(auth.providers, [provider])))
  }
}

/// The enabled provider IDs and display names, for custom sign-in pages.
pub fn providers(auth: Auth) -> List(#(String, String)) {
  list.map(auth.providers, fn(p) { #(provider.id(p), provider.name(p)) })
}

fn configured_provider(
  auth: Auth,
  id: String,
) -> service.Result(provider.Provider) {
  list.find(auth.providers, fn(p) { provider.id(p) == id })
  |> result.replace_error(service.NotFound("provider"))
}

/// Store `browser_token` in a Secure, HttpOnly, SameSite=Lax cookie before
/// redirecting to `url`. Prefer `routes.providers`, which owns these details.
pub type ProviderStart {
  ProviderStart(url: String, browser_token: secret.Secret)
}

pub type ProviderOutcome {
  ProviderSession(Session)
  ProviderLinked
  ProviderSecondFactor(MfaChallenge)
}

/// Begin browser sign-in. `callback_path` is trusted application configuration,
/// never a request parameter. The attempt captures the current group selection.
pub fn begin_provider(
  auth: Auth,
  id: String,
  callback_path: String,
  client: String,
) -> service.Result(ProviderStart) {
  use provider <- result.try(configured_provider(auth, id))
  begin_provider_attempt(auth, provider, callback_path, client, None)
}

/// Linking requires a live, recently created session. The callback must present
/// that same session as well as the browser token and Google's response.
pub fn begin_provider_link(
  auth: Auth,
  principal: Principal,
  id: String,
  callback_path: String,
) -> service.Result(ProviderStart) {
  use principal <- result.try(fresh_provider_principal(auth, principal))
  use provider <- result.try(configured_provider(auth, id))
  begin_provider_attempt(
    in_group(auth, principal.user.group_id),
    provider,
    callback_path,
    principal.client,
    Some(principal),
  )
}

fn fresh_provider_principal(
  auth: Auth,
  principal: Principal,
) -> service.Result(Principal) {
  use current <- result.try(authenticate_digest(
    auth,
    principal.session_id,
    principal.client,
  ))
  use sessions <- result.try(sessions(auth, current))
  case
    current.user.id == principal.user.id
    && list.any(sessions, fn(s) {
      s.current
      && s.created_at >= token.now() - auth.policy.fresh_session_seconds
    })
  {
    True -> Ok(current)
    False -> Error(service.Forbidden)
  }
}

fn begin_provider_attempt(
  auth: Auth,
  provider: provider.Provider,
  callback_path: String,
  client: String,
  linking: Option(Principal),
) -> service.Result(ProviderStart) {
  let id = provider.id(provider)
  use _ <- result.try(case provider_path(callback_path) {
    True -> Ok(Nil)
    False -> Error(service.Invalid("invalid provider callback path"))
  })
  use within <- result.try(target(auth, False))
  use _ <- result.try(existing(auth, within))
  let state = token.new()
  let browser = token.new()
  let nonce = token.new()
  let verifier = token.new()
  let redirect_uri = auth.origin <> callback_path
  let #(link_user, link_session) = case linking {
    Some(principal) -> #(principal.user.id, principal.session_id)
    None -> #("", "")
  }
  let attempt =
    provider_store.Attempt(
      id,
      token.digest(nonce),
      secret.wrap(verifier),
      redirect_uri,
      within,
      group.mode_name(auth.groups),
      link_user,
      link_session,
      client,
    )
  // Built first: a provider configured by discovery can fail here, and then
  // no attempt should be left behind.
  use url <- result.try(provider.authorization_url(
    provider,
    provider.Authorization(redirect_uri, state, nonce, token.digest(verifier)),
  ))
  use _ <- result.try({
    use conn <- db.write_transaction(
      auth.repo,
      touching: "howdy_auth_provider_attempts",
    )
    provider_store.insert(conn, state, browser, attempt)
  })
  Ok(ProviderStart(url, secret.wrap(browser)))
}

/// Consume a browser-bound attempt, verify the external identity, and apply
/// local policy. `None` code means cancelled/denied consent and still spends the
/// attempt. Custom transports must enforce request limits. No Google token is
/// returned. Linking never changes the current session.
pub fn finish_provider(
  auth: Auth,
  id: String,
  callback_path: String,
  state: String,
  browser_token: String,
  code: Option(String),
  principal: Option(Principal),
) -> service.Result(ProviderOutcome) {
  use provider <- result.try(configured_provider(auth, id))
  use attempt <- result.try(consume_attempt(
    auth,
    id,
    callback_path,
    state,
    browser_token,
  ))
  use code <- result.try(case code {
    Some(code) if code != "" -> Ok(code)
    _ -> Error(service.Unauthorized)
  })
  use identity <- result.try(provider.exchange(
    provider,
    provider.Exchange(
      secret.wrap(code),
      attempt.redirect_uri,
      attempt.verifier,
      attempt.nonce_digest,
    ),
  ))
  complete_identity(auth, id, attempt, identity, principal, Public)
}

/// Spend the browser-bound attempt, whatever happens next, and confirm it was
/// begun under the group configuration that is finishing it.
fn consume_attempt(
  auth: Auth,
  id: String,
  callback_path: String,
  state: String,
  browser_token: String,
) -> service.Result(provider_store.Attempt) {
  use _ <- result.try(valid_token(state))
  use _ <- result.try(valid_token(browser_token))
  use attempt <- result.try({
    use conn <- db.transaction(auth.repo)
    provider_store.consume(
      conn,
      state,
      browser_token,
      id,
      auth.origin <> callback_path,
    )
  })
  use _ <- result.try(case attempt.mode == group.mode_name(auth.groups) {
    True -> Ok(Nil)
    False -> Error(service.Unauthorized)
  })
  use _ <- result.try(case attempt.group_id {
    Some(g) -> in_bound_group(auth, g)
    None -> Ok(Nil)
  })
  Ok(attempt)
}

/// Apply local account policy to an identity the external party has already
/// proven. Nothing here depends on how it was proven, so every sign-in
/// protocol ends in this one place.
fn complete_identity(
  auth: Auth,
  id: String,
  attempt: provider_store.Attempt,
  identity: provider.Identity,
  principal: Option(Principal),
  admission: Admission,
) -> service.Result(ProviderOutcome) {
  // Revalidate after the network request: revocation while at Google must not
  // authorize linking, nor may another browser session take over.
  use linking <- result.try(case attempt.link_user, principal {
    "", _ -> Ok(None)
    user_id, Some(p)
      if p.user.id == user_id && p.session_id == attempt.link_session
    -> fresh_provider_principal(auth, p) |> result.map(Some)
    _, _ -> Error(service.Unauthorized)
  })
  let scope = case auth.groups {
    AccountPerGroup -> option.unwrap(attempt.group_id, "")
    _ -> ""
  }
  use completed <- result.try({
    use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
    use owner <- result.try(provider_store.owner(
      conn,
      identity.issuer,
      identity.subject,
      scope,
    ))
    case linking {
      Some(p) -> {
        use users <- result.try(store.active_user(
          conn,
          p.user.id,
          locking: True,
        ))
        use user <- result.try(case users {
          [u] if u.group_id == p.user.group_id -> Ok(u)
          _ -> Error(service.Unauthorized)
        })
        use _ <- result.try(case attempt.group_id {
          Some(g) if g == user.group_id -> Ok(Nil)
          _ -> Error(service.Unauthorized)
        })
        use _ <- result.try(current_account(conn, auth, p, True))
        use _ <- result.try(provider_store.attach(
          conn,
          identity.issuer,
          identity.subject,
          scope,
          user.id,
          id,
        ))
        use _ <- result.try(event(
          conn,
          user.id,
          "provider.linked",
          Acting(p),
          id,
        ))
        Ok(None)
      }
      None -> {
        use user <- result.try(case owner {
          Some(user_id) -> {
            use users <- result.try(store.active_user(
              conn,
              user_id,
              locking: True,
            ))
            // Unlink may have won the user lock after the first owner lookup.
            // Never recreate a link from a callback that observed its old owner.
            use still_owner <- result.try(provider_store.owner(
              conn,
              identity.issuer,
              identity.subject,
              scope,
            ))
            case users, still_owner {
              [u], Some(current) if current == user_id -> Ok(u)
              _, _ -> Error(service.Unauthorized)
            }
          }
          None ->
            admit_provider_user(conn, auth, attempt, identity, admission, id)
        })
        use _ <- result.try(in_bound_group(auth, user.group_id))
        use _ <- result.try(case attempt.group_id {
          Some(g) if g != user.group_id -> Error(service.Unauthorized)
          _ -> Ok(Nil)
        })
        use _ <- result.try(provider_store.attach(
          conn,
          identity.issuer,
          identity.subject,
          scope,
          user.id,
          id,
        ))
        case admission {
          Connection(trusts_mfa: True) ->
            issue_trusting_provider(conn, auth, user, id, attempt.client)
          _ -> issue_session(conn, auth, user, Provider(id), attempt.client)
        }
        |> result.map(Some)
      }
    }
  })
  case completed {
    Some(Pending(challenge)) -> Ok(ProviderSecondFactor(challenge))
    Some(issued) -> publish(auth, issued) |> result.map(ProviderSession)
    None -> Ok(ProviderLinked)
  }
}

/// What an identity nobody owns yet may become.
type Admission {
  /// A built-in provider: a new account if public registration is open, and
  /// never an existing one. Equal addresses alone attach nothing.
  Public
  /// An SSO connection, believed only about its own domains and group, which
  /// the attempt is already bound to. There it is the authority on who holds
  /// an address: the customer's administrator can read that mailbox anyway.
  /// So it takes up the existing account, and otherwise creates one whether
  /// or not registration is public. Without this, turning enforcement on, or
  /// moving to another provider, would lock out everyone who had not linked.
  /// `trusts_mfa` is whether its sign-ins stand without Howdy's second factor.
  Connection(trusts_mfa: Bool)
}

fn admit_provider_user(
  conn: Repo,
  auth: Auth,
  attempt: provider_store.Attempt,
  identity: provider.Identity,
  admission: Admission,
  id: String,
) -> service.Result(User) {
  // Third-party Google addresses first register/verify by email, then link.
  let open = case admission {
    Public -> auth.registration
    Connection(_) -> True
  }
  use _ <- result.try(case identity.email_authoritative {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  })
  use email <- result.try(address.normalize_email(identity.email))
  use existing <- result.try(case admission {
    Public -> Ok([])
    Connection(_) -> store.active_user_by_email(conn, email, attempt.group_id)
  })
  case existing, open {
    [user], _ -> {
      use _ <- result.try(event_from(
        conn,
        user.id,
        "provider.linked",
        System,
        id,
        attempt.client,
      ))
      Ok(user)
    }
    [], True -> {
      use _ <- result.try(enroll(
        conn,
        auth,
        email,
        attempt.group_id,
        attempt.client,
      ))
      use users <- result.try(store.active_user_by_email(
        conn,
        email,
        attempt.group_id,
      ))
      case users {
        [user] -> Ok(user)
        _ -> Error(service.Unauthorized)
      }
    }
    _, _ -> Error(service.Forbidden)
  }
}

/// Enable enterprise single sign-on connections; see `howdy/auth/connection`.
/// Construct once at startup, then manage them with `howdy/auth/connections`.
pub fn with_sso(auth: Auth, config: connection.Config) -> Auth {
  Auth(..auth, sso: Some(config))
}

pub fn sso_enabled(auth: Auth) -> Bool {
  option.is_some(auth.sso)
}

@internal
pub fn sso_config(auth: Auth) -> service.Result(connection.Config) {
  option.to_result(auth.sso, service.Forbidden)
}

/// Sign out every member a newly enforced connection covers, in the caller's
/// transaction and then in an external session store. Their next sign-in is
/// through the connection.
@internal
pub fn end_covered_sessions(
  auth: Auth,
  connection_id: String,
  commit: fn(Repo) -> service.Result(a),
) -> service.Result(a) {
  use #(value, users) <- result.try({
    use conn <- db.write_transaction(
      auth.repo,
      touching: "howdy_auth_sso_connections",
    )
    use value <- result.try(commit(conn))
    use users <- result.try(connection_store.covered(conn, connection_id))
    use _ <- result.try(list.try_each(users, store.delete_sessions(conn, _)))
    Ok(#(value, users))
  })
  use _ <- result.try(
    externally(auth, fn(external) {
      list.try_each(users, external.delete_for_user(_, None))
    }),
  )
  Ok(value)
}

/// Whether a session's provider method can still sign in: a built-in provider
/// that is configured, or an SSO connection that exists and is enabled.
fn provider_enabled(
  conn: Repo,
  auth: Auth,
  id: String,
) -> service.Result(Bool) {
  case id, auth.sso {
    "sso:" <> connection_id, Some(config) ->
      connection_store.find(conn, config, connection_id)
      |> result.map(fn(found) {
        case found {
          Some(c) -> c.enabled
          None -> False
        }
      })
    "sso:" <> _, None -> Ok(False)
    _, _ -> Ok(list.any(auth.providers, fn(p) { provider.id(p) == id }))
  }
}

fn sso_connection(
  auth: Auth,
  id: String,
) -> service.Result(#(connection.Config, connection.Connection)) {
  use config <- result.try(sso_config(auth))
  use found <- result.try(
    db.connect(auth.repo, connection_store.find(_, config, id)),
  )
  case found {
    Some(c) if c.enabled -> Ok(#(config, c))
    _ -> Error(service.NotFound("SSO connection"))
  }
}

fn sso_provider(
  config: connection.Config,
  conn: connection.Connection,
) -> service.Result(provider.Provider) {
  case conn.protocol {
    connection.Oidc(issuer, client_id, client_secret) ->
      sso_oidc.provider(config, conn, issuer, client_id, client_secret)
    connection.Saml(entity_id, sso_url, certificates) ->
      Ok(sso_saml.provider(conn, entity_id, sso_url, certificates))
  }
}

/// The enabled connection that serves an address's domain, for a sign-in page
/// that asks for the address first. Which domains use SSO is not a secret: the
/// redirect that follows reveals it to anyone who asks.
pub fn sso_for_email(
  auth: Auth,
  email: String,
) -> service.Result(Option(String)) {
  use _ <- result.try(sso_config(auth))
  use email <- result.try(address.normalize_email(email))
  let assert [_, domain] = string.split(email, "@")
  db.connect(auth.repo, connection_store.id_for_domain(_, domain))
}

/// Begin browser sign-in through an SSO connection, as `begin_provider` does
/// for a built-in provider. The user signs in to the connection's group.
pub fn begin_sso(
  auth: Auth,
  connection_id: String,
  callback_path: String,
  client: String,
) -> service.Result(ProviderStart) {
  use #(config, conn) <- result.try(sso_connection(auth, connection_id))
  use _ <- result.try(in_bound_group(auth, conn.group_id))
  use provider <- result.try(sso_provider(config, conn))
  begin_provider_attempt(
    in_group(auth, conn.group_id),
    provider,
    callback_path,
    client,
    None,
  )
}

/// As `begin_provider_link`. Only a member of the connection's group can link
/// to it.
pub fn begin_sso_link(
  auth: Auth,
  principal: Principal,
  connection_id: String,
  callback_path: String,
) -> service.Result(ProviderStart) {
  use principal <- result.try(fresh_provider_principal(auth, principal))
  use #(config, conn) <- result.try(sso_connection(auth, connection_id))
  use _ <- result.try(case conn.group_id == principal.user.group_id {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  })
  use provider <- result.try(sso_provider(config, conn))
  begin_provider_attempt(
    in_group(auth, conn.group_id),
    provider,
    callback_path,
    principal.client,
    Some(principal),
  )
}

/// As `finish_provider`. An identity the connection has not seen before
/// becomes a new account in the connection's group when its address is in the
/// connection's domains, whether or not public registration is enabled. It is
/// never attached to an existing account: that takes `begin_sso_link`.
pub fn finish_sso(
  auth: Auth,
  connection_id: String,
  callback_path: String,
  state: String,
  browser_token: String,
  code: Option(String),
  principal: Option(Principal),
) -> service.Result(ProviderOutcome) {
  let id = connection.identity_issuer(connection_id)
  use attempt <- result.try(consume_attempt(
    auth,
    id,
    callback_path,
    state,
    browser_token,
  ))
  use #(config, conn) <- result.try(sso_connection(auth, connection_id))
  // The connection may have moved group while the user was at the provider.
  use _ <- result.try(case attempt.group_id == Some(conn.group_id) {
    True -> Ok(Nil)
    False -> Error(service.Unauthorized)
  })
  use code <- result.try(case code {
    Some(code) if code != "" -> Ok(code)
    _ -> Error(service.Unauthorized)
  })
  use provider <- result.try(sso_provider(config, conn))
  use identity <- result.try(provider.exchange(
    provider,
    provider.Exchange(
      secret.wrap(code),
      attempt.redirect_uri,
      attempt.verifier,
      attempt.nonce_digest,
    ),
  ))
  complete_identity(
    auth,
    id,
    attempt,
    identity,
    principal,
    Connection(conn.trusts_provider_mfa),
  )
}

/// Conservative paths for callback mounts and fixed post-login destinations.
@internal
pub fn provider_path(path: String) -> Bool {
  string.starts_with(path, "/")
  && !string.starts_with(path, "//")
  && list.all(string.to_graphemes(path), fn(c) {
    string.contains(
      "/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
      c,
    )
  })
}

/// Enable self-service deletion. The callback runs inside the deletion
/// transaction with its Repo and current user. Clean up application-owned rows
/// there, or return an error to veto deletion. Use only that Repo, not another
/// auth operation or external side effect. Foreign-key failures roll back all
/// database changes. Auth audit events are retained under the retention policy.
pub fn with_account_deletion(
  auth: Auth,
  before_delete: fn(Repo, User) -> service.Result(Nil),
) -> Auth {
  Auth(..auth, before_delete: Some(before_delete))
}

pub fn account_deletion_enabled(auth: Auth) -> Bool {
  option.is_some(auth.before_delete)
}

/// Require the CURRENT mailbox to approve an email change before the new one
/// is asked to confirm it. Without this, a hijacked fresh session can move the
/// account to a mailbox the attacker controls; with it, they also need the
/// owner's inbox. `request_email_change` then emails an `EmailChangeApproval`
/// token to the current address, and `approve_email_change` continues to the
/// usual `EmailChange` token. A user who has lost the old mailbox cannot change
/// address by themselves; trusted administration still can.
pub fn with_email_change_approval(auth: Auth) -> Auth {
  Auth(..auth, email_change_approval: True)
}

pub fn email_change_approval_enabled(auth: Auth) -> Bool {
  auth.email_change_approval
}

// Approval tokens live in the same table as confirmation tokens. Hashing them
// under a prefix keeps the two apart: neither can be redeemed as the other.
fn approval_digest(secret: String) -> String {
  token.digest("email-change-approval:" <> secret)
}

/// Request proof of the new mailbox, or first of the current one under
/// `with_email_change_approval`. Requires an enabled email delivery flow and a
/// recent, live sign-in. Every later step must use the same session.
/// Only a digest is stored; the email change token cannot sign anyone in.
pub fn request_email_change(
  auth: Auth,
  principal: Principal,
  email: String,
) -> service.Result(Nil) {
  use _ <- result.try(require_email_tokens(auth))
  use email <- result.try(address.normalize_email(email))
  let secret = token.new()
  let digest = case auth.email_change_approval {
    True -> approval_digest(secret)
    False -> token.digest(secret)
  }
  use user <- result.try({
    use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
    use #(user, _) <- result.try(current_account(conn, auth, principal, True))
    use _ <- result.try(available_email(conn, auth, user, email))
    // Bound both a caller changing destinations and many callers targeting one
    // mailbox. Reservations and the pending change commit together.
    use _ <- result.try(store.reserve_email(
      conn,
      token.keyed_digest(auth.throttle_key, "email-change-user:" <> user.id),
      token.now(),
      auth.policy,
    ))
    use _ <- result.try(store.reserve_email(
      conn,
      token.keyed_digest(auth.throttle_key, "email-change-target:" <> email),
      token.now(),
      auth.policy,
    ))
    use _ <- result.try(account_store.request_email(
      conn,
      user.id,
      principal.session_id,
      digest,
      account_store.EmailChange(
        user.email,
        email,
        user.group_id,
        group.mode_name(auth.groups),
      ),
      token.now() + auth.policy.challenge_seconds,
    ))
    use _ <- result.try(event(
      conn,
      user.id,
      "email.change_requested",
      Acting(principal),
      "",
    ))
    Ok(user)
  })
  deliver_email_change(auth, digest, case auth.email_change_approval {
    True -> delivery(auth, user.email, secret, EmailChangeApproval, None)
    False -> delivery(auth, email, secret, EmailChange, None)
  })
}

fn deliver_email_change(
  auth: Auth,
  digest: String,
  delivery: Delivery,
) -> service.Result(Nil) {
  case auth.deliver(delivery) {
    Ok(Nil) -> Ok(Nil)
    Error(Nil) -> {
      let _ = db.connect(auth.repo, account_store.discard_email(_, digest))
      Error(service.Internal("auth email delivery failed"))
    }
  }
}

/// Redeem the token sent to the current address, from the requesting session,
/// then email the confirmation token to the new one. Single-use even on a later
/// failure. Forbidden unless `with_email_change_approval` is configured.
pub fn approve_email_change(
  auth: Auth,
  principal: Principal,
  secret: String,
) -> service.Result(Nil) {
  use _ <- result.try(require_email_tokens(auth))
  use _ <- result.try(case auth.email_change_approval {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  })
  use _ <- result.try(valid_token(secret))
  use change <- result.try({
    use conn <- db.transaction(auth.repo)
    account_store.consume_email(
      conn,
      principal.user.id,
      principal.session_id,
      approval_digest(secret),
    )
  })
  let confirmation = token.new()
  use _ <- result.try({
    use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
    use #(user, _) <- result.try(current_account(conn, auth, principal, True))
    use _ <- result.try(unchanged_since(auth, user, change))
    use _ <- result.try(available_email(conn, auth, user, change.new_email))
    use _ <- result.try(account_store.request_email(
      conn,
      user.id,
      principal.session_id,
      token.digest(confirmation),
      change,
      token.now() + auth.policy.challenge_seconds,
    ))
    event(conn, user.id, "email.change_approved", Acting(principal), "")
  })
  deliver_email_change(
    auth,
    token.digest(confirmation),
    delivery(auth, change.new_email, confirmation, EmailChange, None),
  )
}

fn unchanged_since(
  auth: Auth,
  user: User,
  change: account_store.EmailChange,
) -> service.Result(Nil) {
  case
    user.email == change.old_email
    && user.group_id == change.group_id
    && group.mode_name(auth.groups) == change.mode
  {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  }
}

fn available_email(
  conn: Repo,
  auth: Auth,
  user: User,
  email: String,
) -> service.Result(Nil) {
  use _ <- result.try(case user.email == email {
    True -> Error(service.Invalid("choose a different email address"))
    False -> Ok(Nil)
  })
  use taken <- result.try(store.login_key_taken(
    conn,
    group.login_key(auth.groups, user.group_id, email),
  ))
  case taken {
    True -> Error(service.Conflict("email address is unavailable"))
    False -> Ok(Nil)
  }
}

/// Confirm the new mailbox from the requesting session. Revalidates freshness,
/// account/group state and uniqueness, then signs out every session, including
/// this one. A correctly bound token is single-use even on a later failure.
/// The old address is sent an `EmailChanged` notice on a best-effort basis.
pub fn confirm_email_change(
  auth: Auth,
  principal: Principal,
  secret: String,
) -> service.Result(Nil) {
  use _ <- result.try(require_email_tokens(auth))
  use _ <- result.try(valid_token(secret))
  use change <- result.try({
    use conn <- db.transaction(auth.repo)
    account_store.consume_email(
      conn,
      principal.user.id,
      principal.session_id,
      token.digest(secret),
    )
  })
  // The notice follows the commit even when external session cleanup fails.
  use <- after_commit(auth, fn(external) {
    external.delete_for_user(principal.user.id, None)
  })
  use _ <- result.try({
    use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
    use #(user, _) <- result.try(current_account(conn, auth, principal, True))
    use _ <- result.try(unchanged_since(auth, user, change))
    use _ <- result.try(available_email(conn, auth, user, change.new_email))
    use _ <- result.try(store.delete_challenges_for_user(conn, user.id))
    use _ <- result.try(account_store.change_email(
      conn,
      user.id,
      change.new_email,
      group.login_key(auth.groups, user.group_id, change.new_email),
    ))
    // Challenges for the new address may predate this change too.
    use _ <- result.try(store.delete_challenges_for_user(conn, user.id))
    use _ <- result.try(account_store.clear_pending(conn, user.id))
    use _ <- result.try(account_store.revoke(conn, user.id))
    event(conn, user.id, "email.changed", Acting(principal), "")
  })
  let _ = auth.deliver(delivery(auth, change.old_email, "", EmailChanged, None))
  Ok(Nil)
}

/// The caller's linked providers as #(provider id, issuer). Subjects and
/// provider tokens are not disclosed. Also includes disabled providers so
/// obsolete links can be removed using a different enabled sign-in method.
pub fn linked_providers(
  auth: Auth,
  principal: Principal,
) -> service.Result(List(#(String, String))) {
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use #(user, _) <- result.try(current_account(conn, auth, principal, False))
  account_store.linked(conn, user.id)
}

/// Remove a provider by issuer. First sign in recently with a DIFFERENT enabled
/// method; that proves an alternative works, and prevents last-method lockout.
/// All sessions are revoked, including this one. A missing own link is NotFound.
pub fn unlink_provider(
  auth: Auth,
  principal: Principal,
  issuer: String,
) -> service.Result(Nil) {
  use <- after_commit(auth, fn(external) {
    external.delete_for_user(principal.user.id, None)
  })
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use #(user, method) <- result.try(current_account(conn, auth, principal, True))
  use links <- result.try(account_store.linked(conn, user.id))
  use removed <- result.try(
    list.find(links, fn(link) { link.1 == issuer })
    |> result.replace_error(service.NotFound("provider link")),
  )
  use _ <- result.try(case method == Provider(removed.0) {
    True -> Error(service.Forbidden)
    False -> Ok(Nil)
  })
  use _ <- result.try(account_store.unlink(conn, user.id, issuer))
  use _ <- result.try(account_store.clear_pending(conn, user.id))
  use _ <- result.try(account_store.revoke(conn, user.id))
  event(conn, user.id, "provider.unlinked", Acting(principal), removed.0)
}

/// Delete the caller after a recent sign-in and explicit confirmation of their
/// current address. Disabled until `with_account_deletion` is configured.
/// Credentials, fields, provider links, sessions and authz assignments cascade;
/// pending challenges are removed, and audit records follow their own retention.
pub fn delete_account(
  auth: Auth,
  principal: Principal,
  confirm_email confirm_email: String,
) -> service.Result(Nil) {
  use cleanup <- result.try(case auth.before_delete {
    Some(cleanup) -> Ok(cleanup)
    None -> Error(service.Forbidden)
  })
  use confirm_email <- result.try(address.normalize_email(confirm_email))
  use <- after_commit(auth, fn(external) {
    external.delete_for_user(principal.user.id, None)
  })
  use <- cache.changing
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use #(user, _) <- result.try(current_account(conn, auth, principal, True))
  use _ <- result.try(case user.email == confirm_email {
    True -> Ok(Nil)
    False -> Error(service.Invalid("confirm your current email address"))
  })
  use _ <- result.try(cleanup(conn, user))
  use _ <- result.try(store.delete_challenges_for_user(conn, user.id))
  use _ <- result.try(account_store.clear_pending(conn, user.id))
  use _ <- result.try(account_store.delete(conn, user.id))
  event(conn, user.id, "user.deleted", Acting(principal), "")
}

/// Re-read the account under its row lock, then check the exact session against
/// current state. A Principal is a snapshot, not authority to mutate forever.
fn current_account(
  conn: Repo,
  auth: Auth,
  principal: Principal,
  fresh: Bool,
) -> service.Result(#(User, Method)) {
  use users <- result.try(store.active_user(
    conn,
    principal.user.id,
    locking: True,
  ))
  use user <- result.try(case users {
    [user] -> Ok(user)
    _ -> Error(service.Unauthorized)
  })
  use _ <- result.try(in_bound_group(auth, user.group_id))
  let now = token.now()
  use row <- result.try(case auth.sessions {
    InDatabase -> {
      use rows <- result.try(store.sessions_for_user(conn, user.id, now))
      list.find(rows, fn(row) { row.digest == principal.session_id })
      |> result.replace_error(service.Unauthorized)
    }
    External(external) -> {
      use found <- result.try(external.get(principal.session_id))
      use version <- result.try(account_store.version(conn, user.id))
      case found {
        Some(entry) if entry.user_id == user.id && entry.version == version ->
          Ok(store.SessionRow(
            entry.digest,
            entry.method,
            entry.created_at,
            entry.last_seen_at,
            entry.expires_at,
            entry.client,
          ))
        _ -> Error(service.Unauthorized)
      }
    }
  })
  use _ <- result.try(
    case
      row.expires_at > now
      && {
        auth.policy.session_idle_seconds == 0
        || row.last_seen_at > now - auth.policy.session_idle_seconds
      }
    {
      True -> Ok(Nil)
      False -> Error(service.Unauthorized)
    },
  )
  use _ <- result.try(
    case !fresh || row.created_at > now - auth.policy.fresh_session_seconds {
      True -> Ok(Nil)
      False -> Error(service.Forbidden)
    },
  )
  let method = method_from(row.method)
  use enabled <- result.try(case method {
    Passkey ->
      case auth.passkeys {
        None -> Ok(False)
        Some(_) ->
          security_store.passkeys(conn, user.id)
          |> result.map(fn(keys) { keys != [] })
      }
    EmailToken -> Ok(auth.email_tokens)
    Impersonation -> Ok(False)
    Password ->
      case auth.passwords {
        None -> Ok(False)
        Some(_) -> account_store.has_password(conn, user.id)
      }
    Provider(id) -> {
      use links <- result.try(account_store.linked(conn, user.id))
      use enabled <- result.try(provider_enabled(conn, auth, id))
      Ok(enabled && list.any(links, fn(link) { link.0 == id }))
    }
  })
  case enabled {
    True -> Ok(#(user, method))
    False -> Error(service.Forbidden)
  }
}

// --- Passkeys and second factors --------------------------------------------

pub type MfaChallenge {
  MfaChallenge(token: secret.Secret)
}

pub type LoginStep {
  SignedIn(Session)
  SecondFactor(MfaChallenge)
}

pub type MfaMethod {
  Totp
  DeliveredCode
  RecoveryCode
}

pub type MfaSetup {
  MfaSetup(
    challenge: secret.Secret,
    key: Option(secret.Secret),
    uri: Option(secret.Secret),
    /// `uri` as a standalone SVG QR code for an authenticator app to scan.
    /// It contains the key: show it only to the user enrolling, never cache it.
    qr_code: Option(secret.Secret),
  )
}

pub type MfaSession {
  MfaSession(session: Session, trusted_device: Option(secret.Secret))
}

pub type PasskeyChallenge {
  PasskeyChallenge(challenge: secret.Secret, options: json.Json)
}

/// All nodes need the same stable encryption key. Removing this configuration
/// never bypasses MFA for an enrolled account; those sign-ins fail closed.
pub fn with_mfa(auth: Auth, config: mfa.Config) -> Auth {
  Auth(..auth, mfa: Some(config))
}

pub fn mfa_enabled(auth: Auth) -> Bool {
  option.is_some(auth.mfa)
}

/// Remembered-device lifetime in seconds, for transports setting the cookie.
pub fn mfa_trust_seconds(auth: Auth) -> Int {
  case auth.mfa {
    Some(config) -> mfa.trust_seconds(config)
    None -> mfa.default_trust_seconds
  }
}

/// Whether using a remembered device restarts its lifetime; a transport then
/// re-sets the device cookie with a fresh `mfa_trust_seconds` max-age.
pub fn mfa_trust_renewal(auth: Auth) -> Bool {
  case auth.mfa {
    Some(config) -> mfa.trust_renewal(config)
    None -> False
  }
}

pub fn mfa_delivery_enabled(auth: Auth) -> Bool {
  case auth.mfa {
    Some(config) -> mfa.can_deliver(config)
    None -> False
  }
}

type PasskeySetup {
  PasskeySetup(name: String, rp: Option(String), origins: List(String))
}

/// Passkeys use the exact public-origin hostname as RP ID unless
/// `with_passkey_relying_party` says otherwise, and require user verification
/// (PIN/biometric). Enable once at startup with the displayed name.
pub fn with_passkeys(
  auth: Auth,
  relying_party_name: String,
) -> service.Result(Auth) {
  case
    string.trim(relying_party_name) != ""
    && string.byte_size(relying_party_name) <= 128
  {
    True ->
      Ok(
        Auth(..auth, passkeys: Some(PasskeySetup(relying_party_name, None, []))),
      )
    False ->
      Error(service.Invalid(
        "passkey relying-party name must contain 1 to 128 bytes",
      ))
  }
}

pub fn passkeys_enabled(auth: Auth) -> Bool {
  option.is_some(auth.passkeys)
}

/// Re-encrypt every stored authenticator secret, and every enrollment still in
/// progress, with the key given to `mfa.new`: the last step of a rotation (see
/// `mfa.with_decryption_keys`). Returns how many needed it; once every node
/// seals with the new key, a rerun returns 0 and the old key can be dropped.
/// Safe to run while serving. A secret no configured key opens stops it with
/// an error naming the user, since dropping any key would not change that.
pub fn reseal_mfa(auth: Auth) -> service.Result(Int) {
  use config <- result.try(mfa_config(auth))
  let keys = mfa.keys(config)
  let unreadable = fn(id) {
    service.Internal("MFA secret could not be decrypted: " <> id)
  }
  use conn <- db.connect(auth.repo)
  use factors <- result.try(keyring.reseal_all(
    keys,
    conn,
    page: security_store.sealed_factors,
    replace: security_store.reseal_factor,
    unreadable:,
  ))
  use setups <- result.try(
    keyring.reseal_all(
      keys,
      conn,
      page: security_store.sealed_setups,
      replace: security_store.reseal_setup,
      unreadable: fn(_) { unreadable("an enrollment in progress") },
    ),
  )
  Ok(factors + setups)
}

fn mfa_config(auth: Auth) -> service.Result(mfa.Config) {
  case auth.mfa {
    Some(config) -> Ok(config)
    None -> Error(service.Forbidden)
  }
}

/// Share passkeys across subdomains. `id` is the RP ID: the public origin's
/// hostname or a parent domain of it, such as `example.com` for
/// `https://app.example.com`. `origins` lists further HTTPS origins under that
/// domain whose ceremonies `finish_passkey_registration` and
/// `finish_passkey_login` also accept; the public origin always is. Call after
/// `with_passkeys`.
///
/// Browsers refuse a public suffix (`com`, `co.uk`) as RP ID; that is not
/// checked here. A passkey is bound to the RP ID it was created under, so
/// changing it later strands every existing passkey: choose it before launch.
/// The bundled JSON routes still answer only the public origin, so another
/// origin needs its own deployment or transport calling these functions.
pub fn with_passkey_relying_party(
  auth: Auth,
  id id: String,
  origins origins: List(String),
) -> service.Result(Auth) {
  use setup <- result.try(case auth.passkeys {
    Some(setup) -> Ok(setup)
    None -> Error(service.Invalid("enable passkeys before their relying party"))
  })
  let id = string.lowercase(string.trim(id))
  use origins <- result.try(list.try_map(origins, address.canonical_origin))
  let origins =
    list.unique(origins) |> list.filter(fn(origin) { origin != auth.origin })
  let within = fn(origin) {
    case uri.parse(origin) {
      Ok(uri.Uri(host: Some(host), ..)) ->
        host == id || string.ends_with(host, "." <> id)
      _ -> False
    }
  }
  case
    id != ""
    && !string.starts_with(id, ".")
    && list.length(origins) <= 16
    && list.all([auth.origin, ..origins], within)
  {
    True ->
      Ok(
        Auth(
          ..auth,
          passkeys: Some(PasskeySetup(..setup, rp: Some(id), origins:)),
        ),
      )
    False ->
      Error(service.Invalid(
        "passkey RP ID must be the hostname of the public origin and of at most 16 further origins, or a parent domain of them all",
      ))
  }
}

fn passkey_config(
  auth: Auth,
) -> service.Result(#(String, String, List(String))) {
  use setup <- result.try(case auth.passkeys {
    Some(setup) -> Ok(setup)
    None -> Error(service.Forbidden)
  })
  case setup.rp {
    Some(rp) -> Ok(#(rp, setup.name, setup.origins))
    None -> {
      use parsed <- result.try(
        uri.parse(auth.origin) |> result.replace_error(service.Forbidden),
      )
      case parsed.host {
        Some(host) -> Ok(#(host, setup.name, []))
        None -> Error(service.Forbidden)
      }
    }
  }
}

/// MFA-aware replacements for transports that previously called exchange_from
/// and login_password_from. A SecondFactor token is NOT a session credential.
pub fn exchange_step(
  auth: Auth,
  token: String,
  client: String,
) -> service.Result(LoginStep) {
  redeem(auth, token, client) |> result.try(publish_step(auth, _))
}

/// As `exchange_step`, redeeming the six-digit code from `Delivery.code`
/// with the address it was sent to. Forbidden unless `with_email_codes`.
/// A wrong code, or one already retired by three wrong guesses, is
/// Unauthorized; too many guesses at an address or from a client are
/// TooManyRequests, as for passwords. The emailed token still works.
pub fn exchange_code_step(
  auth: Auth,
  email: String,
  code: String,
  client: String,
) -> service.Result(LoginStep) {
  redeem_code(auth, email, code, client) |> result.try(publish_step(auth, _))
}

pub fn login_password_step(
  auth: Auth,
  email: String,
  password: String,
  client: String,
) -> service.Result(LoginStep) {
  verify_password(auth, email, password, client)
  |> result.try(publish_step(auth, _))
}

pub fn passkeys(
  auth: Auth,
  principal: Principal,
) -> service.Result(List(passkey.Passkey)) {
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use #(user, _) <- result.try(current_account(conn, auth, principal, False))
  security_store.passkeys(conn, user.id)
  |> result.map(list.map(_, fn(key) { key.info }))
}

fn key_name(name: String) -> service.Result(String) {
  let name = string.trim(name)
  case name != "" && string.byte_size(name) <= 100 {
    True -> Ok(name)
    False -> Error(service.Invalid("passkey name must contain 1 to 100 bytes"))
  }
}

pub fn begin_passkey_registration(
  auth: Auth,
  principal: Principal,
  name: String,
) -> service.Result(PasskeyChallenge) {
  use #(rp, rp_name, origins) <- result.try(passkey_config(auth))
  use name <- result.try(key_name(name))
  let challenge = token.new()
  use options <- result.try({
    use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
    use #(user, _) <- result.try(current_account(conn, auth, principal, True))
    use keys <- result.try(security_store.passkeys(conn, user.id))
    use _ <- result.try(case list.length(keys) < 20 {
      True -> Ok(Nil)
      False -> Error(service.Conflict("at most 20 passkeys per account"))
    })
    let #(options, state) =
      passkey.registration_options(
        rp,
        rp_name,
        auth.origin,
        origins,
        user.id,
        user.email,
        keys,
      )
    use version <- result.try(account_store.version(conn, user.id))
    use _ <- result.try(security_store.ceremony(
      conn,
      token.digest(challenge),
      "passkey-register",
      security_store.Ceremony(
        Some(user.id),
        principal.session_id,
        user.group_id,
        version,
        state,
        name,
      ),
    ))
    Ok(options)
  })
  Ok(PasskeyChallenge(secret.wrap(challenge), options))
}

pub fn finish_passkey_registration(
  auth: Auth,
  principal: Principal,
  challenge: String,
  credential: String,
) -> service.Result(Nil) {
  use _ <- result.try(passkey_config(auth))
  use ceremony <- result.try(consume_ceremony(
    auth,
    challenge,
    "passkey-register",
    credential,
  ))
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use #(user, _) <- result.try(current_account(conn, auth, principal, True))
  use _ <- result.try(bound_ceremony(conn, ceremony, user, principal))
  use keys <- result.try(security_store.passkeys(conn, user.id))
  use _ <- result.try(case list.length(keys) < 20 {
    True -> Ok(Nil)
    False -> Error(service.Conflict("at most 20 passkeys per account"))
  })
  use key <- result.try(passkey.register(
    ceremony.payload,
    credential,
    user.id,
    ceremony.label,
    token.now(),
  ))
  use _ <- result.try(security_store.add_passkey(conn, key))
  event(conn, user.id, "passkey.registered", Acting(principal), key.info.id)
}

fn consume_ceremony(
  auth: Auth,
  challenge: String,
  kind: String,
  response: String,
) -> service.Result(security_store.Ceremony) {
  use _ <- result.try(valid_token(challenge))
  use _ <- result.try(case string.byte_size(response) <= 65_536 {
    True -> Ok(Nil)
    False -> Error(service.Invalid("credential response is too large"))
  })
  db.transaction(auth.repo, security_store.consume(
    _,
    token.digest(challenge),
    kind,
  ))
}

fn bound_ceremony(
  conn: Repo,
  ceremony: security_store.Ceremony,
  user: User,
  principal: Principal,
) -> service.Result(Nil) {
  use version <- result.try(account_store.version(conn, user.id))
  case
    ceremony.user_id == Some(user.id)
    && ceremony.session_id == principal.session_id
    && ceremony.group_id == user.group_id
    && ceremony.version == version
  {
    True -> Ok(Nil)
    False -> Error(service.Unauthorized)
  }
}

/// Whether `begin_passkey_signup` is available: passkeys, registration and
/// email tokens must all be enabled.
pub fn passkey_signup_enabled(auth: Auth) -> Bool {
  option.is_some(auth.passkeys) && auth.registration && auth.email_tokens
}

/// Register a new account with a passkey and no password. The ceremony runs
/// first, signed out; `finish_passkey_signup` then emails a `Registration`
/// token, and the account and its passkey are created together when that token
/// is exchanged. As everywhere else, no account exists before its address is
/// verified, and the reply never says whether the address already has one.
/// Nothing is excluded from the ceremony, for the same reason.
pub fn begin_passkey_signup(
  auth: Auth,
  email: String,
  name: String,
) -> service.Result(PasskeyChallenge) {
  use #(rp, rp_name, origins) <- result.try(passkey_config(auth))
  use _ <- result.try(case passkey_signup_enabled(auth) {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  })
  use email <- result.try(address.normalize_email(email))
  use name <- result.try(key_name(name))
  // The WebAuthn user handle, and so the id the account will be created under.
  let id = token.new()
  let #(options, state) =
    passkey.registration_options(
      rp,
      rp_name,
      auth.origin,
      origins,
      id,
      email,
      [],
    )
  let challenge = token.new()
  use _ <- result.try(
    db.transaction(auth.repo, security_store.ceremony(
      _,
      token.digest(challenge),
      "passkey-signup",
      security_store.Ceremony(
        None,
        "",
        option.unwrap(auth.group, ""),
        0,
        // An email address holds no newline, nor does a token.
        id <> "\n" <> email <> "\n" <> state,
        name,
      ),
    )),
  )
  Ok(PasskeyChallenge(secret.wrap(challenge), options))
}

/// Verify the new credential, then send the registration token. The passkey
/// works only after that token is exchanged; for an address that already has an
/// account it is discarded and the email says `AlreadyRegistered`. Subject to
/// the same per-address cooldown as password registration.
pub fn finish_passkey_signup(
  auth: Auth,
  challenge: String,
  credential: String,
  client: String,
) -> service.Result(Nil) {
  use _ <- result.try(passkey_config(auth))
  use ceremony <- result.try(consume_ceremony(
    auth,
    challenge,
    "passkey-signup",
    credential,
  ))
  // Register into the group the ceremony began in, never a different one.
  use auth <- result.try(case auth.group, ceremony.group_id {
    None, "" -> Ok(auth)
    None, id -> Ok(in_group(auth, id))
    Some(bound), id if bound == id -> Ok(auth)
    Some(_), _ -> Error(service.Unauthorized)
  })
  use #(id, email, state) <- result.try(
    case string.split_once(ceremony.payload, "\n") {
      Ok(#(id, rest)) ->
        case string.split_once(rest, "\n") {
          Ok(#(email, state)) -> Ok(#(id, email, state))
          Error(_) -> Error(service.Unauthorized)
        }
      Error(_) -> Error(service.Unauthorized)
    },
  )
  use key <- result.try(passkey.register(
    state,
    credential,
    id,
    ceremony.label,
    token.now(),
  ))
  request_challenge(
    auth,
    email,
    Register,
    client,
    WithPasskey(passkey.encode(key)),
  )
}

pub fn begin_passkey_login(auth: Auth) -> service.Result(PasskeyChallenge) {
  use #(rp, _, origins) <- result.try(passkey_config(auth))
  let #(options, state) =
    passkey.authentication_options(rp, auth.origin, origins)
  let challenge = token.new()
  use _ <- result.try(
    db.transaction(auth.repo, security_store.ceremony(
      _,
      token.digest(challenge),
      "passkey-login",
      security_store.Ceremony(
        None,
        "",
        option.unwrap(auth.group, ""),
        0,
        state,
        "",
      ),
    )),
  )
  Ok(PasskeyChallenge(secret.wrap(challenge), options))
}

pub fn finish_passkey_login(
  auth: Auth,
  challenge: String,
  credential: String,
  client: String,
) -> service.Result(LoginStep) {
  use _ <- result.try(passkey_config(auth))
  use ceremony <- result.try(consume_ceremony(
    auth,
    challenge,
    "passkey-login",
    credential,
  ))
  use id <- result.try(passkey.credential_id(credential))
  use issued <- result.try({
    use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
    use initial <- result.try(security_store.passkey(conn, id))
    use users <- result.try(store.active_user(
      conn,
      initial.user_id,
      locking: True,
    ))
    use user <- result.try(case users {
      [user] -> Ok(user)
      _ -> Error(service.Unauthorized)
    })
    use _ <- result.try(in_bound_group(auth, user.group_id))
    use _ <- result.try(
      case ceremony.group_id == "" || ceremony.group_id == user.group_id {
        True -> Ok(Nil)
        False -> Error(service.Unauthorized)
      },
    )
    // Re-read after acquiring the user lock, including the signature counter.
    use stored <- result.try(security_store.passkey(conn, id))
    use verified <- result.try(passkey.verify(
      ceremony.payload,
      credential,
      stored,
    ))
    use _ <- result.try(security_store.update_passkey(conn, verified))
    issue_session(conn, auth, user, Passkey, client)
  })
  publish_step(auth, issued)
}

pub fn rename_passkey(
  auth: Auth,
  principal: Principal,
  id: String,
  name: String,
) -> service.Result(Nil) {
  use name <- result.try(key_name(name))
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use #(user, _) <- result.try(current_account(conn, auth, principal, True))
  use _ <- result.try(own_passkey(conn, user.id, id))
  use _ <- result.try(security_store.rename_passkey(conn, user.id, id, name))
  event(conn, user.id, "passkey.renamed", Acting(principal), id)
}

fn own_passkey(
  conn: Repo,
  user_id: String,
  id: String,
) -> service.Result(passkey.Stored) {
  use key <- result.try(
    security_store.passkey(conn, id)
    |> result.replace_error(service.NotFound("passkey")),
  )
  case key.user_id == user_id {
    True -> Ok(key)
    False -> Error(service.NotFound("passkey"))
  }
}

pub fn delete_passkey(
  auth: Auth,
  principal: Principal,
  id: String,
) -> service.Result(Nil) {
  use <- after_commit(auth, fn(store) {
    store.delete_for_user(principal.user.id, None)
  })
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use #(user, method) <- result.try(current_account(conn, auth, principal, True))
  use _ <- result.try(own_passkey(conn, user.id, id))
  // Conservative removal: prove a separate login method, not the key being deleted.
  use _ <- result.try(case method {
    Passkey -> Error(service.Forbidden)
    _ -> Ok(Nil)
  })
  use _ <- result.try(security_store.delete_passkey(conn, user.id, id))
  use _ <- result.try(account_store.clear_pending(conn, user.id))
  use _ <- result.try(account_store.revoke(conn, user.id))
  event(conn, user.id, "passkey.deleted", Acting(principal), id)
}

pub fn mfa_status(
  auth: Auth,
  principal: Principal,
) -> service.Result(Option(String)) {
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use #(user, _) <- result.try(current_account(conn, auth, principal, False))
  security_store.factor(conn, user.id)
  |> result.map(option.map(_, fn(f) { f.method }))
}

/// Begin enrollment; it is NOT enabled until the code is confirmed. The key
/// and URI are secrets; render locally, never through a third-party QR service.
pub fn begin_mfa(
  auth: Auth,
  principal: Principal,
  method: MfaMethod,
) -> service.Result(MfaSetup) {
  use config <- result.try(mfa_config(auth))
  let challenge = token.new()
  let seed = case method {
    Totp -> mfa.new_secret()
    _ -> mfa.otp()
  }
  use #(user, setup) <- result.try({
    use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
    use #(user, login_method) <- result.try(current_account(
      conn,
      auth,
      principal,
      True,
    ))
    use factor <- result.try(security_store.factor(conn, user.id))
    use _ <- result.try(case factor {
      None -> Ok(Nil)
      Some(_) -> Error(service.Conflict("MFA is already enabled"))
    })
    use kind <- result.try(case method {
      Totp -> Ok("totp")
      DeliveredCode if login_method != EmailToken ->
        case mfa.can_deliver(config) {
          True -> Ok("otp")
          False -> Error(service.Forbidden)
        }
      _ -> Error(service.Forbidden)
    })
    use _ <- result.try(store.reserve_email(
      conn,
      token.keyed_digest(auth.throttle_key, "mfa-enroll:" <> user.id),
      token.now(),
      auth.policy,
    ))
    use payload <- result.try(case method {
      Totp -> mfa.seal(config, user.id, seed)
      _ -> Ok(code_digest(auth, user.id, seed))
    })
    use version <- result.try(account_store.version(conn, user.id))
    use _ <- result.try(security_store.ceremony(
      conn,
      token.digest(challenge),
      "mfa-setup",
      security_store.Ceremony(
        Some(user.id),
        principal.session_id,
        user.group_id,
        version,
        payload,
        kind,
      ),
    ))
    let setup = case method {
      Totp -> {
        let uri =
          "otpauth://totp/"
          <> uri.percent_encode(mfa.issuer(config) <> ":" <> user.email)
          <> "?secret="
          <> seed
          <> "&issuer="
          <> uri.percent_encode(mfa.issuer(config))
          <> "&algorithm=SHA1&digits=6&period=30"
        MfaSetup(
          secret.wrap(challenge),
          Some(secret.wrap(seed)),
          Some(secret.wrap(uri)),
          mfa.qr_code(uri) |> option.from_result |> option.map(secret.wrap),
        )
      }
      _ -> MfaSetup(secret.wrap(challenge), None, None, None)
    }
    Ok(#(user, setup))
  })
  case method {
    DeliveredCode ->
      case mfa.deliver(config, user, secret.wrap(seed)) {
        Ok(_) -> Ok(setup)
        Error(error) -> {
          let _ =
            db.connect(auth.repo, security_store.discard(
              _,
              token.digest(challenge),
            ))
          Error(error)
        }
      }
    _ -> Ok(setup)
  }
}

fn code_digest(auth: Auth, user_id: String, code: String) -> String {
  token.keyed_digest(auth.throttle_key, "mfa-code:" <> user_id <> ":" <> code)
}

fn security_attempt(auth: Auth, user_id: String) -> service.Result(Nil) {
  use attempts <- result.try(
    db.transaction(auth.repo, security_store.reserve_attempt(_, user_id)),
  )
  case attempts <= 5 {
    True -> Ok(Nil)
    False -> Error(service.TooManyRequests(300))
  }
}

fn new_recovery_codes(
  conn: Repo,
  auth: Auth,
  user_id: String,
) -> service.Result(List(secret.Secret)) {
  use config <- result.try(mfa_config(auth))
  let codes =
    list.map(list.repeat(Nil, mfa.recovery_codes(config)), fn(_) {
      mfa.backup()
    })
  use _ <- result.try(security_store.recovery_codes(
    conn,
    user_id,
    list.map(codes, code_digest(auth, user_id, _)),
  ))
  Ok(list.map(codes, secret.wrap))
}

/// Successful enrollment revokes all sessions. Save the returned recovery
/// codes once, then sign in again using the new second factor.
pub fn confirm_mfa(
  auth: Auth,
  principal: Principal,
  challenge: String,
  code: String,
) -> service.Result(List(secret.Secret)) {
  use config <- result.try(mfa_config(auth))
  use _ <- result.try(
    db.write_transaction(auth.repo, "howdy_auth_users", fn(conn) {
      current_account(conn, auth, principal, True) |> result.map(fn(_) { Nil })
    }),
  )
  use _ <- result.try(security_attempt(auth, principal.user.id))
  use ceremony <- result.try(consume_ceremony(
    auth,
    challenge,
    "mfa-setup",
    code,
  ))
  use codes <- result.try({
    use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
    use #(user, _) <- result.try(current_account(conn, auth, principal, True))
    use _ <- result.try(bound_ceremony(conn, ceremony, user, principal))
    use existing <- result.try(security_store.factor(conn, user.id))
    use _ <- result.try(case existing {
      None -> Ok(Nil)
      _ -> Error(service.Conflict("MFA is already enabled"))
    })
    use factor <- result.try(case ceremony.label {
      "totp" -> {
        use seed <- result.try(mfa.open(config, user.id, ceremony.payload))
        use step <- result.try(
          mfa.verify_totp(seed, code, -1, token.now())
          |> result.replace_error(service.Unauthorized),
        )
        Ok(security_store.Factor("totp", ceremony.payload, step))
      }
      "otp" if code != "" ->
        case code_digest(auth, user.id, code) == ceremony.payload {
          True -> Ok(security_store.Factor("otp", "", -1))
          False -> Error(service.Unauthorized)
        }
      _ -> Error(service.Unauthorized)
    })
    use _ <- result.try(security_store.enable(conn, user.id, factor))
    use codes <- result.try(new_recovery_codes(conn, auth, user.id))
    use _ <- result.try(account_store.clear_pending(conn, user.id))
    use _ <- result.try(account_store.revoke(conn, user.id))
    use _ <- result.try(security_store.reset_attempts(conn, user.id))
    use _ <- result.try(event(
      conn,
      user.id,
      "mfa.enabled",
      Acting(principal),
      factor.method,
    ))
    Ok(codes)
  })
  // Database generation makes old external sessions inert even if cleanup fails.
  let _ =
    externally(auth, fn(store) {
      store.delete_for_user(principal.user.id, None)
    })
  Ok(codes)
}

fn pending_user(
  conn: Repo,
  auth: Auth,
  digest: String,
) -> service.Result(#(security_store.Pending, User, security_store.Factor)) {
  use initial <- result.try(security_store.pending(conn, digest))
  use users <- result.try(store.active_user(
    conn,
    initial.user_id,
    locking: True,
  ))
  use user <- result.try(case users {
    [u] -> Ok(u)
    _ -> Error(service.Unauthorized)
  })
  use pending <- result.try(security_store.pending(conn, digest))
  use version <- result.try(account_store.version(conn, user.id))
  use _ <- result.try(in_bound_group(auth, user.group_id))
  use _ <- result.try(
    case pending.group_id == user.group_id && pending.version == version {
      True -> Ok(Nil)
      False -> Error(service.Unauthorized)
    },
  )
  use factor <- result.try(security_store.factor(conn, user.id))
  use factor <- result.try(case factor {
    Some(factor) -> Ok(factor)
    None -> Error(service.Unauthorized)
  })
  // Configuration changes cannot promote proof from a disabled login method.
  use _ <- result.try(case method_from(pending.method) {
    EmailToken -> require_email_tokens(auth)
    // An impersonated session never reaches a second factor.
    Impersonation -> Error(service.Unauthorized)
    Password -> passwords(auth) |> result.map(fn(_) { Nil })
    Passkey -> passkey_config(auth) |> result.map(fn(_) { Nil })
    Provider(id) -> {
      use enabled <- result.try(provider_enabled(conn, auth, id))
      case enabled {
        True -> Ok(Nil)
        False -> Error(service.NotFound("provider"))
      }
    }
  })
  Ok(#(pending, user, factor))
}

/// Optional delivered-code fallback. Refused after email-token primary proof,
/// so the same inbox cannot serve as both authentication factors.
pub fn send_mfa_code(auth: Auth, challenge: String) -> service.Result(Nil) {
  use config <- result.try(mfa_config(auth))
  use _ <- result.try(valid_token(challenge))
  let code = mfa.otp()
  let digest = token.digest(challenge)
  use user <- result.try({
    use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
    use #(pending, user, _) <- result.try(pending_user(conn, auth, digest))
    use _ <- result.try(
      case pending.method != "email" && mfa.can_deliver(config) {
        True -> Ok(Nil)
        False -> Error(service.Forbidden)
      },
    )
    use _ <- result.try(store.reserve_email(
      conn,
      token.keyed_digest(auth.throttle_key, "mfa-send:" <> user.id),
      token.now(),
      auth.policy,
    ))
    use _ <- result.try(security_store.send_otp(
      conn,
      digest,
      code_digest(auth, user.id, code),
    ))
    Ok(user)
  })
  case mfa.deliver(config, user, secret.wrap(code)) {
    Ok(_) -> Ok(Nil)
    Error(error) -> {
      let _ = db.connect(auth.repo, security_store.spend_pending(_, digest))
      Error(error)
    }
  }
}

pub fn verify_mfa(
  auth: Auth,
  challenge: String,
  method: MfaMethod,
  code: String,
  remember: Bool,
) -> service.Result(MfaSession) {
  use config <- result.try(mfa_config(auth))
  use _ <- result.try(valid_token(challenge))
  let digest = token.digest(challenge)
  use initial <- result.try(
    db.connect(auth.repo, security_store.pending(_, digest)),
  )
  use _ <- result.try(security_attempt(auth, initial.user_id))
  let trusted = case remember {
    True -> Some(secret.wrap(token.new()))
    False -> None
  }
  use issued <- result.try({
    use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
    use #(pending, user, factor) <- result.try(pending_user(conn, auth, digest))
    use _ <- result.try(case method {
      Totp if factor.method == "totp" -> {
        use seed <- result.try(mfa.open(config, user.id, factor.secret))
        use step <- result.try(
          mfa.verify_totp(seed, code, factor.last_step, token.now())
          |> result.replace_error(service.Unauthorized),
        )
        security_store.step(conn, user.id, step)
      }
      RecoveryCode ->
        security_store.recover(
          conn,
          user.id,
          code_digest(auth, user.id, string.uppercase(string.trim(code))),
        )
      DeliveredCode
        if pending.method != "email" && pending.otp_digest != "" && code != ""
      ->
        case
          mfa.can_deliver(config)
          && code_digest(auth, user.id, code) == pending.otp_digest
        {
          True -> Ok(Nil)
          False -> Error(service.Unauthorized)
        }
      _ -> Error(service.Unauthorized)
    })
    use _ <- result.try(security_store.spend_pending(conn, digest))
    use _ <- result.try(security_store.reset_attempts(conn, user.id))
    use _ <- result.try(case trusted {
      Some(value) ->
        security_store.add_trusted(
          conn,
          user.id,
          pending.version,
          token.digest(secret.reveal(value)),
          mfa.trust_seconds(config),
        )
      None -> Ok(Nil)
    })
    use _ <- result.try(event_from(
      conn,
      user.id,
      "mfa.verified",
      System,
      case method {
        RecoveryCode -> "recovery"
        Totp -> "totp"
        DeliveredCode -> "otp"
      },
      pending.client,
    ))
    issue_verified_session(
      conn,
      auth,
      user,
      "mfa:" <> pending.method,
      pending.client,
    )
  })
  use session <- result.try(publish(auth, issued))
  Ok(MfaSession(session, trusted))
}

/// Redeem a remembered device only AFTER a successful primary login challenge.
/// Tokens are user- and generation-bound and last as long as
/// `mfa.with_device_trust` says (30 days by default), restarting on each use
/// only when renewal is enabled.
pub fn use_trusted_device(
  auth: Auth,
  challenge: String,
  device: String,
) -> service.Result(Session) {
  use config <- result.try(mfa_config(auth))
  use _ <- result.try(valid_token(challenge))
  use _ <- result.try(valid_token(device))
  use issued <- result.try({
    use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
    use #(pending, user, _) <- result.try(pending_user(
      conn,
      auth,
      token.digest(challenge),
    ))
    use trusted <- result.try(security_store.trusted(
      conn,
      token.digest(device),
      user.id,
      pending.version,
    ))
    use _ <- result.try(case trusted, mfa.trust_renewal(config) {
      True, True ->
        security_store.renew_trusted(
          conn,
          token.digest(device),
          mfa.trust_seconds(config),
        )
      True, False -> Ok(Nil)
      False, _ -> Error(service.Unauthorized)
    })
    use _ <- result.try(security_store.spend_pending(
      conn,
      token.digest(challenge),
    ))
    issue_verified_session(
      conn,
      auth,
      user,
      "mfa:" <> pending.method,
      pending.client,
    )
  })
  publish(auth, issued)
}

fn require_mfa_session(
  conn: Repo,
  auth: Auth,
  principal: Principal,
) -> service.Result(User) {
  use #(user, _) <- result.try(current_account(conn, auth, principal, True))
  use method <- result.try(case auth.sessions {
    InDatabase -> {
      use rows <- result.try(store.sessions_for_user(conn, user.id, token.now()))
      list.find(rows, fn(row) { row.digest == principal.session_id })
      |> result.map(fn(row) { row.method })
      |> result.replace_error(service.Unauthorized)
    }
    External(store) -> {
      use entry <- result.try(store.get(principal.session_id))
      case entry {
        Some(entry) -> Ok(entry.method)
        None -> Error(service.Unauthorized)
      }
    }
  })
  case string.starts_with(method, "mfa:") {
    True -> Ok(user)
    False -> Error(service.Forbidden)
  }
}

pub fn disable_mfa(auth: Auth, principal: Principal) -> service.Result(Nil) {
  use _ <- result.try(mfa_config(auth))
  use <- after_commit(auth, fn(store) {
    store.delete_for_user(principal.user.id, None)
  })
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use user <- result.try(require_mfa_session(conn, auth, principal))
  use _ <- result.try(security_store.disable(conn, user.id))
  use _ <- result.try(account_store.clear_pending(conn, user.id))
  use _ <- result.try(account_store.revoke(conn, user.id))
  event(conn, user.id, "mfa.disabled", Acting(principal), "")
}

pub fn regenerate_recovery_codes(
  auth: Auth,
  principal: Principal,
) -> service.Result(List(secret.Secret)) {
  use _ <- result.try(mfa_config(auth))
  use codes <- result.try({
    use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
    use user <- result.try(require_mfa_session(conn, auth, principal))
    use codes <- result.try(new_recovery_codes(conn, auth, user.id))
    use _ <- result.try(account_store.clear_pending(conn, user.id))
    use _ <- result.try(account_store.revoke(conn, user.id))
    use _ <- result.try(event(
      conn,
      user.id,
      "mfa.recovery_regenerated",
      Acting(principal),
      "",
    ))
    Ok(codes)
  })
  let _ =
    externally(auth, fn(store) {
      store.delete_for_user(principal.user.id, None)
    })
  Ok(codes)
}

pub fn trusted_devices(
  auth: Auth,
  principal: Principal,
) -> service.Result(List(#(String, Int, Int))) {
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use #(user, _) <- result.try(current_account(conn, auth, principal, False))
  security_store.trusted_devices(conn, user.id)
}

pub fn revoke_trusted_device(
  auth: Auth,
  principal: Principal,
  id: String,
) -> service.Result(Nil) {
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use #(user, _) <- result.try(current_account(conn, auth, principal, True))
  use _ <- result.try(security_store.delete_trusted(conn, user.id, id))
  event(conn, user.id, "mfa.device_revoked", Acting(principal), "")
}
