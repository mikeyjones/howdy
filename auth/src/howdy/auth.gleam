//// Email-token and optional password authentication. This package owns its tables; applications
//// extend profiles in their own tables. Authorization lives in howdy/authorization.

import howdy/auth/secret

import gleam/http
import gleam/http/request
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gloo/repo.{type Repo}
import howdy/auth/group.{type Mode, AccountPerGroup, OneGroupPerUser, Single}
import howdy/auth/internal/address
import howdy/auth/internal/cache
import howdy/auth/internal/database as db
import howdy/auth/internal/password as password_hash
import howdy/auth/internal/schema
import howdy/auth/internal/store
import howdy/auth/internal/token
import howdy/auth/policy.{type Policy}
import howdy/auth/user.{
  type Actor, type Principal, type User, Acting, Principal, System,
}
import howdy/context.{type Context}
import howdy/migration
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
}

/// Deliver the token privately. Never log it or expose it in a public response.
/// The token expires after `policy.challenge_seconds` (ten minutes by default)
/// and must be exchanged via POST.
pub type Delivery {
  Delivery(email: String, token: secret.Secret, purpose: Purpose)
}

pub opaque type Auth {
  Auth(
    repo: Repo,
    origin: String,
    deliver: fn(Delivery) -> Result(Nil, Nil),
    registration: Bool,
    passwords: Option(password_hash.Passwords),
    policy: Policy,
    password_check: fn(String) -> service.Result(Nil),
    throttle_key: String,
    groups: Mode,
    /// The group this value acts in, chosen with `in_group`.
    group: Option(String),
  )
}

/// How a session was authenticated.
pub type Method {
  EmailToken
  Password
}

/// Returned only by a successful token exchange or password login. Keep the token secret. Browser
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
    None,
    policy.default(),
    fn(_) { Ok(Nil) },
    throttle_key,
    groups,
    None,
  ))
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
}

fn request_challenge(
  auth: Auth,
  email: String,
  intent: Intent,
  client: String,
  preparation: Preparation,
) -> service.Result(Nil) {
  use email <- result.try(address.normalize_email(email))
  use _ <- result.try(case intent == Register && !auth.registration {
    True -> Error(service.Forbidden)
    False -> Ok(Nil)
  })
  use within <- result.try(target(auth, intent == Register))
  use _ <- result.try(existing(auth, within))
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
      send(auth, email, within, stored, purpose, None, now, client, owner)
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
      send(auth, email, within, stored, purpose, password, now, client, owner)
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
  now: Int,
  client: String,
  owner: Option(String),
) -> service.Result(Nil) {
  let secret = token.new()
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
      case auth.deliver(Delivery(email, secret.wrap(secret), purpose)) {
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
  }
}

fn method_from(name: String) -> Method {
  case name {
    "password" -> Password
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
  use _ <- result.try(valid_token(secret))
  use consumed <- result.try({
    use conn <- db.transaction(auth.repo)
    store.consume_challenge(conn, token.digest(secret), token.now())
  })
  use challenge <- result.try(case consumed {
    [value] -> Ok(value)
    _ -> Error(service.Unauthorized)
  })
  use intent <- result.try(intent_from(challenge.intent))
  use _ <- result.try(case challenge.group_id {
    Some(id) -> in_bound_group(auth, id)
    None -> Ok(Nil)
  })
  use _ <- result.try(case challenge.password_hash {
    Some(_) -> passwords(auth) |> result.map(fn(_) { Nil })
    None -> Ok(Nil)
  })
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use _ <- result.try(case intent {
    Register ->
      register(conn, auth, challenge.email, challenge.group_id, client)
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
  // Redeeming a token proves control of the address, so its back-off ends.
  use _ <- result.try(store.clear_email_throttle(
    conn,
    address_key(auth, Some(user.group_id), challenge.email),
  ))
  issue_session(conn, auth, user, EmailToken, client)
}

fn issue_session(
  conn: Repo,
  auth: Auth,
  user: User,
  method: Method,
  client: String,
) -> service.Result(Session) {
  let now = token.now()
  let session =
    Session(user, secret.wrap(token.new()), now + auth.policy.session_seconds)
  use _ <- result.try(store.insert_session(
    conn,
    digest: token.digest(secret.reveal(session.token)),
    user_id: user.id,
    method: method_name(method),
    now:,
    expires_at: session.expires_at,
    client:,
  ))
  use _ <- result.try(event_from(
    conn,
    user.id,
    "session.created",
    System,
    method_name(method),
    client,
  ))
  Ok(session)
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
      use user <- result.try(case users {
        [user] -> Ok(user)
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
    use fresh <- result.try(store.fresh_email_session(
      conn,
      principal.session_id,
      principal.user.id,
      now,
      now - auth.policy.fresh_session_seconds,
    ))
    case fresh {
      True -> Ok(Nil)
      False -> Error(service.Forbidden)
    }
  }
  // Refuse before paying for a hash, then check again under the row lock.
  use _ <- result.try(db.connect(auth.repo, fresh))
  use encoded <- result.try(password_hash.hash(hasher, password))
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
  event(conn, principal.user.id, "password.set", Acting(principal), "")
}

fn register(
  conn: Repo,
  auth: Auth,
  email: String,
  within: Option(String),
  client: String,
) -> service.Result(Nil) {
  use _ <- result.try(case auth.registration {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  })
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
  let id = token.new()
  use _ <- result.try(store.insert_user(
    conn,
    id:,
    email:,
    group_id:,
    login_key:,
  ))
  event_from(conn, id, "user.registered", System, group_id, client)
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
  use conn <- db.connect(auth.repo)
  let digest = token.digest(secret)
  let now = token.now()
  let seen_after = case auth.policy.session_idle_seconds {
    0 -> -1
    idle -> now - idle
  }
  use users <- result.try(store.session_user(conn, digest, now, seen_after))
  case users {
    [#(user, last_seen_at)] -> {
      use _ <- result.try(in_bound_group(auth, user.group_id))
      use _ <- result.try(case last_seen_at <= now - touch_seconds {
        True -> store.touch_session(conn, digest, now)
        False -> Ok(Nil)
      })
      Ok(Principal(user, digest, client))
    }
    _ -> Error(service.Unauthorized)
  }
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
  use conn <- db.connect(auth.repo)
  use rows <- result.try(store.sessions_for_user(
    conn,
    principal.user.id,
    token.now(),
  ))
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
  use <- cache.changing
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use _ <- result.try(store.require_user(conn, user_id))
  use _ <- result.try(store.set_suspended(conn, user_id, True))
  use _ <- result.try(store.delete_sessions(conn, user_id))
  use _ <- result.try(store.delete_challenges_for_user(conn, user_id))
  event(conn, user_id, "user.suspended", actor, "")
}

/// Privileged operation: authorize the caller before invoking it.
pub fn resume(
  auth: Auth,
  user_id: String,
  by actor: Actor,
) -> service.Result(Nil) {
  use <- cache.changing
  use conn <- db.write_transaction(auth.repo, touching: "howdy_auth_users")
  use _ <- result.try(store.require_user(conn, user_id))
  use _ <- result.try(store.set_suspended(conn, user_id, False))
  event(conn, user_id, "user.resumed", actor, "")
}

/// Housekeeping for a scheduled job. Expired rows are already removed as a
/// side effect of normal traffic; this covers quiet installations.
pub fn prune_expired(auth: Auth) -> service.Result(Nil) {
  use conn <- db.transaction(auth.repo)
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
