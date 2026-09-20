# Howdy Auth compared with Better Auth

Updated 20 September 2026. Assesses the working tree based on `0127fec`, including
the uncommitted passkey/MFA implementation. Better Auth references are its live
official documentation, not a pinned release. Enterprise integrations such as
SSO, SAML and SCIM are deferred for this comparison. Optional
Better Auth plugins are identified as available capabilities, not enabled defaults.

## Assessment

Howdy now covers the core authentication lifecycle for a conventional web app:
verified registration, password/email/provider login, passkeys, MFA, recovery,
account changes/deletion and session management. The earlier comparison's major
missing-workflow findings are no longer accurate.

My assessment: Howdy is now a credible, deliberately narrower auth library for
Howdy/Gleam applications. Better Auth remains the more complete general-purpose
framework, especially in client integrations, login convenience, configuration
and operational tooling. Implemented features and passing tests do not establish
equal production maturity or prove that either library is more secure.

## What is now covered

| Area | Howdy working tree | Comparison |
| --- | --- | --- |
| Passwords and recovery | Argon2id, verified registration, persistent throttling, configurable breach check; replacement/recovery through a fresh email-token session | Core capability present; Better Auth also offers current-password changes and a dedicated reset-link flow. [Password docs](https://better-auth.com/docs/authentication/email-password) |
| Account lifecycle | New-email verification, recent-session checks, deletion cleanup hook, safe provider unlinking and session revocation | Major gap closed. Better Auth additionally offers confirmation through the old email before proceeding. [Account docs](https://better-auth.com/docs/concepts/users-accounts) |
| Passkeys | Discoverable enrollment/login, naming/removal, signature counters, backup metadata, required user verification | Core lifecycle present. Better Auth additionally exposes conditional autofill, configurable RP/origins, extensions and pre-authentication enrollment hooks. [Passkey plugin](https://better-auth.com/docs/plugins/passkey) |
| MFA | TOTP, callback-delivered OTP, one-use recovery codes, recovery replacement, disablement and remembered devices | Core lifecycle present. Better Auth exposes more settings and automatic trust renewal; Howdy fixes formats/timings and uses a fixed 30-day trust lifetime. [2FA plugin](https://better-auth.com/docs/plugins/2fa) |
| Providers | Google, GitHub, Facebook and Microsoft Entra, with explicit linking | Much improved; smaller catalog, no supported public provider-construction contract, and no provider token retention/refresh. Apple is one concrete consumer gap. [Apple support](https://better-auth.com/docs/authentication/apple), [account token management](https://better-auth.com/docs/concepts/users-accounts) |
| Sessions | Cookie/bearer sessions, list/revoke, absolute and idle expiry, custom session storage | Core present. Better Auth also supports rolling renewal and optional cookie caching/stateless strategies. [Session docs](https://better-auth.com/docs/concepts/session-management) |
| Authorization and user data | Scoped roles/permissions, typed custom fields, trusted provisioning and suspension | Already implemented; these are not missing features. Applications own administrative authorization and UI. [Howdy documentation](../auth/README.md#simple-roles-and-permission-based-rbac) |

Howdy's MFA enforcement is broader than Better Auth's documented default:
enrolled users must complete it after email, password, provider and passkey
login. Better Auth normally challenges credential-based login; its passwordless
and social flows are not gated by default. Both provide shared failed-code
budgets; that protection is not unique to Howdy. These are policy differences,
not proof of overall security superiority. [Better Auth 2FA](https://better-auth.com/docs/plugins/2fa)

Howdy also stores session-token digests, checks current account state and uses
session generations for account-security revocation. Choosing fresh database
checks has a cost but avoids accepting stale cached account state. Better Auth's
optional cookie cache can delay revocation until cache expiry, as its docs
explicitly explain. [Howdy storage](../auth/README.md#session-storage),
[Better Auth sessions](https://better-auth.com/docs/concepts/session-management)

## Remaining practical gaps

1. **Login and account UX.** Built-in magic links and short email OTP login are
   absent; Howdy's emailed-token flow requires pasting a high-entropy token.
   Delivered second-factor OTP does not fill that primary-login gap. Username,
   phone and anonymous-to-registered accounts are also absent. Better Auth offers
   these as optional [authentication plugins](https://better-auth.com/docs/plugins).
   Password changes in Howdy require another email login, even when the user
   knows the current password. Its authenticator page displays a manual key;
   custom pages can render the supplied URI as a QR code.
2. **Client tooling.** Typed Gleam server APIs, JSON endpoints and starter pages
   exist, but no reusable typed browser SDK, reactive session client or supported
   mobile integration. Better Auth's [client](https://better-auth.com/docs/concepts/client)
   and [Expo integration](https://better-auth.com/docs/integrations/expo) reduce
   integration work for application developers.
3. **Passkey deployment flexibility.** Howdy uses exactly one public-origin
   hostname as RP ID and requires authenticated enrollment. Cross-subdomain
   arrangements and passkey-first signup need more design. Conditional autofill
   is a useful smaller UX improvement. This is narrower configuration rather
   than absence of passkeys. [Better Auth passkeys](https://better-auth.com/docs/plugins/passkey)
4. **Session convenience.** Howdy has fixed absolute expiry, not sliding renewal.
   Remembering MFA is separate from keeping the main session alive. Better Auth
   provides renewal and optional [same-browser account switching](https://better-auth.com/docs/plugins/multi-session).
5. **Distributed abuse controls.** Howdy's HTTP limits are per process, although
   account/password/MFA guessing and email cooldowns are database-backed. Better
   Auth offers shared database, secondary-storage and custom limiter backends.
   Its server-side `auth.api` calls bypass that HTTP limiter. [Rate-limit docs](https://better-auth.com/docs/concepts/rate-limit)
6. **Administrative and extension tooling.** Howdy has useful headless primitives
   but no equivalent packaged permission-controlled admin API/client,
   impersonation, general endpoint/database hooks or supported third-party
   plugin contract. [Admin plugin](https://better-auth.com/docs/plugins/admin),
   [hooks](https://better-auth.com/docs/concepts/hooks). A hosted dashboard should
   not be assumed to come with Better Auth's open-source admin plugin.
7. **Service credentials.** Bearer login sessions exist in Howdy; independently
   scoped API keys with expiry, management and per-key limits do not. This is a
   separate capability, useful when applications expose integrations. [API-key plugin](https://better-auth.com/docs/plugins/api-key)
8. **Shared workspaces, if needed.** Groups currently partition identities: each
   user belongs to one group, or has separate accounts in separate groups. This
   does not supply one identity with multiple memberships, teams and invitations.
   Better Auth supplies those in its [organization plugin](https://better-auth.com/docs/plugins/organization).
   This concerns ordinary collaborative SaaS as well as enterprise products.
9. **Release readiness.** Howdy still carries a locally patched native password
   dependency and a pinned prerelease WebAuthn verifier (`glasslock 1.0.0-rc1`),
   including internal metadata parsing. No independent audit or physical-device
   interoperability matrix was completed in this work. Current deployment
   guidance stops old instances before migrations. These are concrete limits
   on claiming production parity. [Package notes](../auth/README.md),
   [verifier research](passkey-mfa-research.md), [password dependency](../auth/vendor/jargon/README.md)

## Recommended next work

For a normal Howdy web application, prioritize:

1. Release/dependency hardening and real-browser/device interoperability checks.
2. Smoother existing workflows: magic-link or short email-OTP login, current-password
   changes, local authenticator QR rendering, and passkey autofill.
3. A small reusable auth client with explicit signed-out, pending-MFA and signed-in
   states; configurable session renewal if the application needs persistent login.
4. Shared HTTP rate limiting before deploying multiple application instances.
5. Add providers and API-key support when there is a concrete product requirement.

Multi-origin passkeys deserve earlier priority if deployment spans subdomains.
Shared memberships and invitations matter if the product needs collaborative
workspaces. Enterprise integrations remain deferred.

## Evidence and limits

Reviewed the current APIs, provider boundary, policies, storage contracts, starter
pages and documentation. The immediately preceding implementation run passed
**163 Gleam tests on SQLite and 163 on PostgreSQL**, plus **10 JavaScript starter-page
tests**. This comparison did not rerun them. Those tests include actual signed
ES256/Ed25519/RSA assertions, replay checks, recovery-code concurrency and MFA
transport behavior; they are not a production benchmark or independent audit.
Additional current primary-source notes: [Better Auth research](betterauth-current-research.md).
