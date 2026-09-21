//// Optional accessible starter pages. Omit this controller when bringing your
//// own UI; the JSON routes and headless operations remain available.

import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import howdy/auth.{type Auth}
import howdy/auth/internal/token
import howdy/controller
import howdy/guard
import howdy/query

pub fn routes(
  identity: Auth,
  at prefix: String,
  api_at api: String,
) -> controller.Controller {
  // Restrict mount paths so they can safely appear in HTML attributes.
  let assert True = safe_path(prefix) && safe_path(api)
    as "auth pages require absolute paths containing letters, numbers, slash, hyphen or underscore"
  let script_path = prefix <> "/client.js"
  controller.new(prefix)
  |> controller.middleware(fn(ctx, next) {
    let answer = next(ctx)
    // Pages carry credentials in their responses; the script is a constant
    // and sets its own validator, so it is the one thing worth storing.
    case ctx.request.path == script_path {
      True -> answer
      False -> response.set_header(answer, "cache-control", "no-store")
    }
    |> response.set_header(
      "content-security-policy",
      "default-src 'none'; script-src 'self'; connect-src 'self'; form-action 'self' https://accounts.google.com; base-uri 'none'; frame-ancestors 'none'",
    )
    |> response.set_header("referrer-policy", "no-referrer")
    |> response.set_header("x-content-type-options", "nosniff")
  })
  |> controller.get("/login", fn(ctx) {
    login_page(ctx, identity, prefix, api, TokenLogin)
  })
  |> controller.get("/register", fn(ctx) {
    case auth.registration_enabled(identity) {
      True -> login_page(ctx, identity, prefix, api, TokenRegister)
      False -> controller.status(ctx, 404)
    }
  })
  |> controller.get("/password/login", fn(ctx) {
    case auth.passwords_enabled(identity) {
      True -> login_page(ctx, identity, prefix, api, PasswordLogin)
      False -> controller.status(ctx, 404)
    }
  })
  |> controller.get("/password/register", fn(ctx) {
    case
      auth.passwords_enabled(identity)
      && auth.registration_enabled(identity)
      && auth.email_tokens_enabled(identity)
    {
      True -> login_page(ctx, identity, prefix, api, PasswordRegister)
      False -> controller.status(ctx, 404)
    }
  })
  |> controller.get("/mfa", fn(ctx) {
    controller.html(
      ctx,
      "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Verify sign-in</title><script src=\""
        <> escape(prefix)
        <> "/client.js\" defer></script></head><body><main><h1>Verify sign-in</h1>"
        <> mfa_login(identity, api, False)
        <> "<p id=\"status\" role=\"status\" aria-live=\"polite\"></p><a href=\""
        <> escape(prefix)
        <> "/account\">Your account</a></main></body></html>",
    )
  })
  |> controller.get("/account", fn(ctx) {
    use _ <- guard.require(ctx, auth.required(identity))
    controller.html(ctx, account_page(identity, prefix, api))
  })
  |> controller.get("/client.js", fn(ctx) {
    // Revalidate rather than expire: an upgraded package must never be served
    // an older script, and a matching validator costs an empty 304.
    let tag = script_tag()
    case request.get_header(ctx.request, "if-none-match") == Ok(tag) {
      True -> controller.status(ctx, 304)
      False ->
        controller.text(ctx, script)
        |> response.set_header("content-type", "text/javascript; charset=utf-8")
    }
    |> response.set_header("cache-control", "no-cache")
    |> response.set_header("etag", tag)
  })
}

fn safe_path(path: String) -> Bool {
  string.starts_with(path, "/")
  && !string.ends_with(path, "/")
  && list.all(string.to_graphemes(path), fn(c) {
    string.contains(
      "/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
      c,
    )
  })
}

/// Escape a value for an HTML text node or a double-quoted attribute. Every
/// value these pages interpolate is validated or constant today; escaping is
/// what keeps that true of edits made later.
/// The script is a constant per release, so its digest identifies the version
/// a browser already holds.
fn script_tag() -> String {
  "\"" <> token.digest(script) <> "\""
}

fn escape(value: String) -> String {
  value
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&#39;")
}

type Page {
  TokenLogin
  TokenRegister
  PasswordLogin
  PasswordRegister
}

fn login_page(ctx, identity, prefix, api, kind) {
  use group <- query.optional_string(ctx, "group")
  controller.html(ctx, page(identity, prefix, api, kind, group))
}

fn provider_forms(
  identity: Auth,
  prefix: String,
  action: String,
  group: option.Option(String),
) -> String {
  list.map(auth.providers(identity), fn(p) {
    let #(id, name) = p
    let query = case group {
      Some(g) -> "?" <> uri.query_to_string([#("group", g)])
      None -> ""
    }
    "<form method=\"post\" action=\""
    <> escape(prefix <> "/providers/" <> id <> "/" <> action <> query)
    <> "\"><button>"
    <> case action {
      "link" -> "Link "
      _ -> "Continue with "
    }
    <> escape(name)
    <> "</button></form>"
  })
  |> string.join("")
}

fn page(
  identity: Auth,
  prefix: String,
  api: String,
  page: Page,
  group: option.Option(String),
) -> String {
  // The mount paths are the only values here the application supplies.
  let prefix = escape(prefix)
  let api = escape(api)
  let #(register, password) = case page {
    TokenLogin -> #(False, False)
    TokenRegister -> #(True, False)
    PasswordLogin -> #(False, True)
    PasswordRegister -> #(True, True)
  }
  let title = case register {
    True -> "Create an account"
    False -> "Sign in"
  }
  let action = case page {
    PasswordRegister -> "password/register"
    PasswordLogin -> "password/session"
    TokenRegister -> "register"
    TokenLogin -> "login"
  }
  let password_field = case password {
    False -> ""
    True -> {
      let autocomplete = case register {
        True -> "new-password"
        False -> "current-password"
      }
      "<label>Password <input name=\"password\" type=\"password\" autocomplete=\""
      <> autocomplete
      <> "\" required></label>"
    }
  }
  let explanation = case password, register {
    True, True ->
      "Choose a password with at least "
      <> int.to_string(auth.policy(identity).password_min_length)
      <> " characters. We will email a token to verify your address before creating the account."
    True, False -> "Enter your email address and password."
    False, _ ->
      "We will email you a single-use token. It expires in "
      <> int.to_string(auth.policy(identity).challenge_seconds / 60)
      <> " minutes."
  }
  let button = case password && !register {
    True -> "Sign in"
    False -> "Send token"
  }
  let exchange = case password && !register {
    True -> ""
    False ->
      "<form method=\"post\" id=\"exchange\"><label>Email token <input name=\"token\" autocomplete=\"one-time-code\" required minlength=\"43\" maxlength=\"43\"></label><button>Continue</button></form>"
  }
  let alternative = case password, auth.passwords_enabled(identity) {
    True, _ ->
      "<p><a href=\""
      <> prefix
      <> case register {
        True -> "/register"
        False -> "/login"
      }
      <> "\">Use an email token</a></p>"
    False, True ->
      "<p><a href=\""
      <> prefix
      <> case register {
        True -> "/password/register"
        False -> "/password/login"
      }
      <> "\">Use a password</a></p>"
    False, False -> ""
  }
  let credentials = case auth.email_tokens_enabled(identity) || password {
    True -> {
      "<p>"
      <> explanation
      <> "</p><form method=\"post\" id=\"request\" data-api=\""
      <> api
      <> "\" data-action=\""
      <> action
      <> "\"><label>Email address <input name=\"email\" type=\"email\" autocomplete=\"username\" required maxlength=\"254\"></label>"
      <> password_field
      <> "<button>"
      <> button
      <> "</button></form>"
      <> exchange
      <> alternative
    }
    False -> ""
  }
  "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>"
  <> title
  <> "</title><script src=\""
  <> prefix
  <> "/client.js\" defer></script></head><body><main><h1>"
  <> title
  <> "</h1>"
  <> provider_forms(identity, prefix, "login", group)
  <> credentials
  <> case auth.passkeys_enabled(identity) {
    True ->
      "<button id=\"passkey-login\" data-api=\""
      <> api
      <> "\">Sign in with a passkey</button>"
    False -> ""
  }
  <> mfa_login(identity, api, True)
  <> "<p><a href=\""
  <> prefix
  <> "/account\">Manage your account</a></p>"
  <> "<p id=\"status\" role=\"status\" aria-live=\"polite\"></p><noscript>Email and account management require JavaScript. Provider sign-in works without it.</noscript></main></body></html>"
}

fn delivered_option(identity: Auth) -> String {
  case auth.mfa_delivery_enabled(identity) {
    True -> "<option value=\"otp\">Delivered code</option>"
    False -> ""
  }
}

fn delivered_button(identity: Auth) -> String {
  case auth.mfa_delivery_enabled(identity) {
    True ->
      "<button id=\"mfa-send\">Send a code to my verified contact</button>"
    False -> ""
  }
}

fn mfa_login(identity: Auth, api: String, hidden: Bool) -> String {
  "<section id=\"mfa-login\" data-api=\""
  <> escape(api)
  <> "\""
  <> case hidden {
    True -> " hidden"
    False -> ""
  }
  <> "><h2>Second factor</h2><form id=\"mfa-verify\"><label>Method <select name=\"method\"><option value=\"totp\">Authenticator app</option>"
  <> delivered_option(identity)
  <> "<option value=\"recovery\">Recovery code</option></select></label><label>Code <input name=\"code\" autocomplete=\"one-time-code\" required maxlength=\"64\"></label><label><input name=\"remember\" type=\"checkbox\">Remember this device for "
  <> trust_period(auth.mfa_trust_seconds(identity))
  <> "</label><button>Verify sign-in</button></form>"
  <> delivered_button(identity)
  <> "</section>"
}

fn trust_period(seconds: Int) -> String {
  let #(count, unit) = case seconds {
    s if s >= 172_800 -> #(s / 86_400, "days")
    s if s >= 7200 -> #(s / 3600, "hours")
    s -> #(s / 60, "minutes")
  }
  int.to_string(count) <> " " <> unit
}

fn security_settings(identity: Auth) -> String {
  let passkeys = case auth.passkeys_enabled(identity) {
    False -> ""
    True ->
      "<h2>Passkeys</h2><p>Sign in again before changing passkeys. To remove one, sign in through another login method.</p><form id=\"passkey-add\"><label>Passkey name <input name=\"name\" required maxlength=\"100\"></label><button>Add passkey</button></form><ul id=\"passkeys\"></ul>"
  }
  let mfa = case auth.mfa_enabled(identity) {
    False -> ""
    True ->
      "<h2>Two-factor authentication</h2><p id=\"mfa-state\"></p><p>Sign in again before changing these settings. Enrollment, disabling MFA and replacing recovery codes sign out all sessions.</p><form id=\"mfa-enroll\"><label>Method <select name=\"method\"><option value=\"totp\">Authenticator app</option>"
      <> delivered_option(identity)
      <> "</select></label><button>Start enrollment</button></form><pre id=\"mfa-setup-key\"></pre><form id=\"mfa-enroll-confirm\" hidden><label>Confirmation code <input name=\"code\" autocomplete=\"one-time-code\" required maxlength=\"6\"></label><button>Enable two-factor authentication</button></form><button id=\"mfa-disable\">Disable two-factor authentication</button><button id=\"mfa-recovery\">Replace recovery codes</button><p>Save these recovery codes privately. Each works once and they are shown only now.</p><pre id=\"recovery-codes\"></pre><h3>Remembered devices</h3><ul id=\"trusted-devices\"></ul>"
  }
  passkeys <> mfa
}

fn account_page(identity: Auth, prefix: String, api: String) -> String {
  let prefix = escape(prefix)
  let api = escape(api)
  let password_form = case
    auth.passwords_enabled(identity) && auth.email_tokens_enabled(identity)
  {
    False -> ""
    True ->
      "<h2>Set or reset password</h2><p>First sign in using a fresh email token. Changing your password signs out every other session.</p><form id=\"password-change\"><label>New password <input name=\"password\" type=\"password\" autocomplete=\"new-password\" required></label><button>Save password</button></form>"
  }
  let password_form =
    case auth.passwords_enabled(identity) {
      False -> ""
      True ->
        "<h2>Change password</h2><p>Changing your password signs out every other session.</p><form id=\"password-current\"><label>Current password <input name=\"current\" type=\"password\" autocomplete=\"current-password\" required></label><label>New password <input name=\"password\" type=\"password\" autocomplete=\"new-password\" required></label><button>Change password</button></form>"
    }
    <> password_form
  let email_forms = case auth.email_tokens_enabled(identity) {
    False -> ""
    True ->
      "<h2>Change email</h2><p>Sign in again first. "
      <> case auth.email_change_approval_enabled(identity) {
        True ->
          "Approve the change with the token sent to your current address, then confirm the token sent to your new address, both in this session."
        False -> "Confirm the token sent to your new address in this session."
      }
      <> " Confirming signs out all sessions.</p><form id=\"email-change\"><label>New email <input name=\"email\" type=\"email\" required maxlength=\"254\" autocomplete=\"email\"></label><button>Send confirmation</button></form>"
      <> case auth.email_change_approval_enabled(identity) {
        True ->
          "<form id=\"email-approve\" hidden><label>Approval token <input name=\"token\" required autocomplete=\"one-time-code\"></label><button>Approve change</button></form>"
        False -> ""
      }
      <> "<form id=\"email-confirm\" hidden><label>Confirmation token <input name=\"token\" required autocomplete=\"one-time-code\"></label><button>Confirm new email</button></form>"
  }
  let deletion_form = case auth.account_deletion_enabled(identity) {
    False -> ""
    True ->
      "<h2>Delete account</h2><p>This permanently deletes your account. Sign in again first, then enter your current email to confirm.</p><form id=\"account-delete\"><label>Current email <input name=\"email\" type=\"email\" required autocomplete=\"email\"></label><button>Permanently delete account</button></form>"
  }
  "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>Your account</title><script src=\""
  <> prefix
  <> "/client.js\" defer></script></head><body><main id=\"account\" data-api=\""
  <> api
  <> "\"><h1>Your account</h1><p><a href=\""
  <> prefix
  <> "/login\">Sign in</a></p>"
  <> provider_forms(identity, prefix, "link", None)
  <> password_form
  <> email_forms
  <> "<h2>Linked sign-in providers</h2><p>To unlink a provider, first sign in again using another method. Unlinking signs out all sessions.</p><ul id=\"linked-providers\"></ul>"
  <> security_settings(identity)
  <> deletion_form
  <> "<h2>Active sessions</h2><ul id=\"sessions\"></ul><button id=\"refresh-sessions\">Refresh sessions</button><button id=\"logout\">Sign out</button><p id=\"status\" role=\"status\" aria-live=\"polite\"></p><noscript>Account management requires JavaScript.</noscript></main></body></html>"
}

const script = "const requestForm = document.getElementById('request');
const exchangeForm = document.getElementById('exchange');
const account = document.getElementById('account');
const status = document.getElementById('status');
const mfaLogin = document.getElementById('mfa-login');
const api = (requestForm || account || mfaLogin || document.getElementById('passkey-login'))?.dataset.api;
async function call(endpoint, payload) {
  const response = await fetch(api + '/' + endpoint, {
    method: payload === undefined ? 'GET' : 'POST', credentials: 'same-origin',
    headers: payload === undefined ? {} : {'Content-Type': 'application/json'},
    body: payload === undefined ? undefined : JSON.stringify(payload)
  });
  const body = response.status === 204 ? {} : await response.json();
  if (!response.ok) throw new Error(body.error || 'Please try again.');
  return body;
}
async function submit(form, endpoint, payload) {
  const button = form.querySelector('button');
  button.disabled = true;
  try {
    const body = await call(endpoint, payload);
    if (body.mfa_required) { showMfa(); return; }
    const signedIn = endpoint === 'session' || endpoint === 'password/session';
    status.textContent = signedIn ? 'You are signed in. You can now manage your account.' : body.message;
    if (form.elements.password) form.elements.password.value = '';
    if (signedIn) {
      if (exchangeForm) exchangeForm.reset();
      requestForm.hidden = true;
      if (exchangeForm) exchangeForm.hidden = true;
    } else { exchangeForm?.elements.token.focus(); }
  } catch (error) { status.textContent = error.message; }
  finally { button.disabled = false; }
}
requestForm?.addEventListener('submit', event => {
  event.preventDefault();
  const payload = {email: requestForm.elements.email.value};
  const group = new URLSearchParams(location.search).get('group');
  if (group) payload.group = group;
  if (requestForm.elements.password) payload.password = requestForm.elements.password.value;
  submit(requestForm, requestForm.dataset.action, payload);
});
exchangeForm?.addEventListener('submit', event => {
  event.preventDefault();
  submit(exchangeForm, 'session', {token: exchangeForm.elements.token.value.trim()});
});
async function refreshSessions() {
  const sessions = await call('sessions');
  const list = document.getElementById('sessions');
  list.replaceChildren();
  for (const session of sessions) {
    const item = document.createElement('li');
    item.textContent = (session.current ? 'This session' : 'Other session') + ' — ' + session.method +
      ', created ' + new Date(session.created_at * 1000).toLocaleString() +
      ', last used ' + new Date(session.last_seen_at * 1000).toLocaleString() + ' ';
    const revoke = document.createElement('button');
    revoke.textContent = 'Revoke session';
    revoke.addEventListener('click', async () => {
      revoke.disabled = true;
      try {
        await call('sessions/revoke', {id: session.id});
        item.remove();
        status.textContent = session.current ? 'You are signed out.' : 'Session revoked.';
        if (session.current) account.querySelectorAll('button').forEach(b => b.disabled = true);
      } catch (error) { status.textContent = error.message; revoke.disabled = false; }
    });
    item.append(revoke); list.append(item);
  }
}
function signedOut(message) {
  status.textContent = message;
  document.getElementById('sessions').replaceChildren();
  document.getElementById('linked-providers')?.replaceChildren();
  account.querySelectorAll('button').forEach(button => button.disabled = true);
}
async function refreshProviders() {
  const list = document.getElementById('linked-providers');
  if (!list) return;
  const links = await call('providers');
  list.replaceChildren();
  for (const link of links) {
    const item = document.createElement('li');
    item.textContent = link.provider + ' ';
    const button = document.createElement('button');
    button.textContent = 'Unlink';
    button.addEventListener('click', async () => {
      button.disabled = true;
      try {
        await call('providers/unlink', {issuer: link.issuer});
        signedOut('Provider unlinked. You are signed out. Sign in using your remaining method.');
      } catch (error) { status.textContent = error.message; button.disabled = false; }
    });
    item.append(button); list.append(item);
  }
}
function accountForm(id, endpoint, field, message) {
  document.getElementById(id)?.addEventListener('submit', async event => {
    event.preventDefault();
    const form = event.currentTarget;
    const button = form.querySelector('button');
    button.disabled = true;
    let completed = false;
    try {
      const result = await call(endpoint, {[field]: form.elements[field].value.trim()});
      form.reset();
      if (id === 'email-change' || id === 'email-approve') {
        status.textContent = result.message;
        const approval = id === 'email-change' && document.getElementById('email-approve');
        const next = approval || document.getElementById('email-confirm');
        if (id === 'email-approve') form.hidden = true;
        next.hidden = false; next.elements.token.focus();
      } else {
        completed = true; signedOut(message);
      }
    } catch (error) { status.textContent = error.message; }
    finally { if (!completed) button.disabled = false; }
  });
}
if (account) {
  refreshProviders().catch(error => status.textContent = error.message);
  accountForm('email-change', 'email/change', 'email', '');
  accountForm('email-approve', 'email/approve', 'token', '');
  accountForm('email-confirm', 'email/confirm', 'token', 'Email changed. You are signed out. Sign in using your new address.');
  accountForm('account-delete', 'account/delete', 'email', 'Your account has been deleted.');
  refreshSessions().catch(error => status.textContent = error.message);
  document.getElementById('refresh-sessions').addEventListener('click', () =>
    refreshSessions().catch(error => status.textContent = error.message));
  const passwordForm = (id, endpoint, fields) =>
    document.getElementById(id)?.addEventListener('submit', async event => {
      event.preventDefault();
      const form = event.currentTarget;
      const button = form.querySelector('button'); button.disabled = true;
      try {
        await call(endpoint, Object.fromEntries(fields.map(name => [name, form.elements[name].value])));
        form.reset(); status.textContent = 'Password saved. Other sessions have been signed out.';
        await refreshSessions();
      } catch (error) { status.textContent = error.message; }
      finally { button.disabled = false; }
    });
  passwordForm('password-change', 'password', ['password']);
  passwordForm('password-current', 'password/change', ['current', 'password']);
  document.getElementById('logout').addEventListener('click', async () => {
    try {
      await call('logout', {}); status.textContent = 'You are signed out.';
      document.getElementById('sessions').replaceChildren();
      account.querySelectorAll('button').forEach(b => b.disabled = true);
    } catch (error) { status.textContent = error.message; }
  });
}
function showMfa() {
  if (mfaLogin) mfaLogin.hidden = false;
  if (requestForm) requestForm.hidden = true;
  if (exchangeForm) exchangeForm.hidden = true;
  status.textContent = 'Verify your second factor to finish signing in.';
}
function loginResult(body) {
  if (body.mfa_required) { showMfa(); return; }
  if (mfaLogin) mfaLogin.hidden = true;
  status.textContent = 'You are signed in. You can now manage your account.';
}
document.getElementById('mfa-verify')?.addEventListener('submit', async event => {
  event.preventDefault(); const form = event.currentTarget; const button = form.querySelector('button'); button.disabled = true;
  try {
    const body = await call('mfa/verify', {method: form.elements.method.value, code: form.elements.code.value.trim(), remember: form.elements.remember.checked});
    form.reset(); loginResult(body);
  } catch (error) { status.textContent = error.message; } finally { button.disabled = false; }
});
document.getElementById('mfa-send')?.addEventListener('click', async event => {
  const button = event.currentTarget; button.disabled = true;
  try { await call('mfa/send', {}); status.textContent = 'Code sent to your verified contact. Choose Delivered code above.'; }
  catch (error) { status.textContent = error.message; } finally { button.disabled = false; }
});
function fromBase64(value) {
  const text = value.replaceAll('-', '+').replaceAll('_', '/');
  return Uint8Array.from(atob(text.padEnd(Math.ceil(text.length / 4) * 4, '=')), c => c.charCodeAt(0));
}
function toBase64(value) {
  return btoa(String.fromCharCode(...new Uint8Array(value))).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}
function credentialOptions(options, register) {
  const parsed = {...options, challenge: fromBase64(options.challenge)};
  if (register) parsed.user = {...options.user, id: fromBase64(options.user.id)};
  for (const field of ['excludeCredentials', 'allowCredentials']) if (options[field]) parsed[field] = options[field].map(c => ({...c, id: fromBase64(c.id)}));
  return parsed;
}
function credentialJSON(credential) {
  const response = credential.response;
  const encoded = {clientDataJSON: toBase64(response.clientDataJSON)};
  if (response.attestationObject) {
    encoded.attestationObject = toBase64(response.attestationObject);
    encoded.transports = response.getTransports?.() || [];
  } else {
    encoded.authenticatorData = toBase64(response.authenticatorData);
    encoded.signature = toBase64(response.signature);
    encoded.userHandle = response.userHandle ? toBase64(response.userHandle) : null;
  }
  return JSON.stringify({id: credential.id, rawId: toBase64(credential.rawId), type: credential.type, response: encoded, clientExtensionResults: credential.getClientExtensionResults?.() || {}});
}
document.getElementById('passkey-login')?.addEventListener('click', async event => {
  const button = event.currentTarget; button.disabled = true;
  try {
    if (!navigator.credentials) throw Error('This browser does not support passkeys.');
    const group = new URLSearchParams(location.search).get('group');
    const challenge = await call('passkeys/login', group ? {group} : {});
    const credential = await navigator.credentials.get({publicKey: credentialOptions(challenge.options, false)});
    if (!credential) throw Error('Passkey sign-in was cancelled.');
    loginResult(await call('passkeys/session', {challenge: challenge.challenge, credential: credentialJSON(credential)}));
  } catch (error) { status.textContent = error.message; } finally { button.disabled = false; }
});
async function refreshPasskeys() {
  const list = document.getElementById('passkeys'); if (!list) return;
  const keys = await call('passkeys'); list.replaceChildren();
  for (const key of keys) {
    const item = document.createElement('li'); item.textContent = key.name + (key.backed_up ? ' (backed up)' : '') + ' ';
    const name = document.createElement('input'); name.value = key.name; name.maxLength = 100; name.setAttribute('aria-label', 'Passkey name');
    const rename = document.createElement('button'); rename.textContent = 'Rename';
    rename.addEventListener('click', async () => {
      rename.disabled = true;
      try { await call('passkeys/rename', {id: key.id, name: name.value}); await refreshPasskeys(); }
      catch (error) { status.textContent = error.message; rename.disabled = false; }
    });
    const remove = document.createElement('button'); remove.textContent = 'Remove';
    remove.addEventListener('click', async () => {
      remove.disabled = true;
      try { await call('passkeys/delete', {id: key.id}); signedOut('Passkey removed. Sign in again using another method.'); }
      catch (error) { status.textContent = error.message; remove.disabled = false; }
    });
    item.append(name); item.append(rename); item.append(remove); list.append(item);
  }
}
document.getElementById('passkey-add')?.addEventListener('submit', async event => {
  event.preventDefault(); const form = event.currentTarget; const button = form.querySelector('button'); button.disabled = true;
  try {
    if (!navigator.credentials) throw Error('This browser does not support passkeys.');
    const challenge = await call('passkeys/register', {name: form.elements.name.value});
    const credential = await navigator.credentials.create({publicKey: credentialOptions(challenge.options, true)});
    if (!credential) throw Error('Passkey registration was cancelled.');
    await call('passkeys/register/confirm', {challenge: challenge.challenge, credential: credentialJSON(credential)});
    form.reset(); await refreshPasskeys(); status.textContent = 'Passkey added.';
  } catch (error) { status.textContent = error.message; } finally { button.disabled = false; }
});
let mfaEnrollment = null;
document.getElementById('mfa-enroll')?.addEventListener('submit', async event => {
  event.preventDefault(); const form = event.currentTarget; const button = form.querySelector('button'); button.disabled = true;
  try {
    const setup = await call('mfa/enroll', {method: form.elements.method.value});
    mfaEnrollment = setup.challenge;
    document.getElementById('mfa-setup-key').textContent = setup.key ? 'Enter this key in your authenticator app: ' + setup.key : 'Check your verified contact for the code.';
    document.getElementById('mfa-enroll-confirm').hidden = false;
    status.textContent = 'Confirm the code to enable two-factor authentication.';
  } catch (error) { status.textContent = error.message; } finally { button.disabled = false; }
});
function showRecovery(result, message) {
  document.getElementById('recovery-codes').textContent = result.recovery_codes.join('\\n');
  document.getElementById('mfa-setup-key').textContent = '';
  signedOut(message + ' Save your recovery codes, then sign in again.');
}
document.getElementById('mfa-enroll-confirm')?.addEventListener('submit', async event => {
  event.preventDefault(); const form = event.currentTarget; const button = form.querySelector('button'); button.disabled = true;
  try {
    const result = await call('mfa/enroll/confirm', {challenge: mfaEnrollment, code: form.elements.code.value.trim()});
    form.reset(); form.hidden = true; mfaEnrollment = null; showRecovery(result, 'Two-factor authentication enabled.');
  } catch (error) {
    mfaEnrollment = null; form.hidden = true; document.getElementById('mfa-setup-key').textContent = '';
    status.textContent = error.message + ' Start enrollment again to retry.'; button.disabled = false;
  }
});
document.getElementById('mfa-recovery')?.addEventListener('click', async event => {
  const button = event.currentTarget; button.disabled = true;
  try { showRecovery(await call('mfa/recovery', {}), 'Old recovery codes replaced.'); }
  catch (error) { status.textContent = error.message; button.disabled = false; }
});
document.getElementById('mfa-disable')?.addEventListener('click', async event => {
  const button = event.currentTarget; button.disabled = true;
  try { await call('mfa/disable', {}); signedOut('Two-factor authentication disabled. Sign in again.'); }
  catch (error) { status.textContent = error.message; button.disabled = false; }
});
async function refreshDevices() {
  const list = document.getElementById('trusted-devices'); if (!list) return;
  const devices = await call('mfa/devices'); list.replaceChildren();
  for (const device of devices) {
    const item = document.createElement('li'); item.textContent = 'Remembered ' + new Date(device.created_at * 1000).toLocaleString() + ' ';
    const button = document.createElement('button'); button.textContent = 'Forget device';
    button.addEventListener('click', async () => {
      button.disabled = true;
      try { await call('mfa/devices/revoke', {id: device.id}); await refreshDevices(); status.textContent = 'Device forgotten. Existing sessions can be revoked below.'; }
      catch (error) { status.textContent = error.message; button.disabled = false; }
    });
    item.append(button); list.append(item);
  }
}
if (account) {
  refreshPasskeys().catch(error => status.textContent = error.message);
  refreshDevices().catch(error => status.textContent = error.message);
  if (document.getElementById('mfa-state')) call('security').then(state => {
    document.getElementById('mfa-state').textContent = state.mfa ? 'Enabled: ' + state.mfa : 'Not enabled';
    document.getElementById('mfa-enroll').hidden = !!state.mfa;
    document.getElementById('mfa-disable').hidden = !state.mfa;
    document.getElementById('mfa-recovery').hidden = !state.mfa;
  }).catch(error => status.textContent = error.message);
}
"
