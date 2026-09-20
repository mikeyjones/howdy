# Howdy Auth compared with Better Auth

Reviewed 20 September 2026. Local revision: `52d8d2f`. Better Auth references describe its current online documentation, rather than a pinned release. Features may require opt-in configuration, plugins and migrations.

## Assessment

Howdy Auth is a thoughtfully implemented, narrowly scoped authentication package for Gleam/Erlang. Its security mechanisms and tests are substantial. Better Auth is a substantially more complete authentication framework, with more login methods, account workflows and integration options. These are separate judgments: a longer feature list does not establish that one implementation is more secure.

Howdy fits applications that need email/password or Google login, database-backed sessions and scoped permissions in the existing Howdy stack. It is not yet a feature-equivalent alternative for applications needing passkeys, MFA, shared organization membership or enterprise federation. Better Auth is a JavaScript/TypeScript system, so adopting it in a Gleam application requires an integration boundary rather than a dependency swap.

## Existing strengths

- Passwords use Argon2id with explicit costs, Unicode normalization, a configurable breach check, dummy verification for unavailable accounts, persistent guessing limits and upgrades of older hashes. Recovery exists: a fresh email-token session authorizes password replacement and revokes other sessions. [Implementation](../auth/src/howdy/auth/internal/password.gleam), [password documentation](../auth/README.md#optional-passwords).
- Random email and session tokens are stored as digests. Browser cookies, exact-origin checks and rejection of ambiguous credentials provide deliberate transport protections. [Tokens](../auth/src/howdy/auth/internal/token.gleam), [guards](../auth/src/howdy/auth.gleam), [routes](../auth/src/howdy/auth/routes.gleam).
- Google login includes PKCE, nonce and browser-bound single-use state, signature validation and explicit linking to existing accounts. [Provider documentation](../auth/README.md#google-and-built-in-providers), [Google implementation](../auth/src/howdy/auth/providers/google.gleam), [signature verification](../auth/src/howdy_auth_oidc_ffi.erl).
- Sessions can be listed and revoked. Authorization has scoped roles and permission grants, with fresh database checks by default. Lifecycle events record actors and clients. Groups, typed custom fields, PostgreSQL/SQLite support and a custom session-store interface already exist. These should not be counted as missing features. [Local documentation](../auth/README.md), [authorization](../auth/src/howdy/authorization.gleam).

## Important differences

| Area | Howdy today | Better Auth |
| --- | --- | --- |
| Passkeys | No WebAuthn/passkey flow | Official [passkey plugin](https://better-auth.com/docs/plugins/passkey) |
| MFA | No second-factor enrollment, challenge or recovery codes; password and email login are alternatives | Official [2FA plugin](https://better-auth.com/docs/plugins/2fa) |
| Account lifecycle | No supported change-email, delete-user or provider-unlink API | Configurable email changes and deletion, plus account unlinking in [user/account APIs](https://better-auth.com/docs/concepts/users-accounts) |
| Organizations | One group per user, or distinct accounts per group; no invitation lifecycle | [Organization plugin](https://better-auth.com/docs/plugins/organization) supports memberships, invitations, teams and organization roles |
| Session lifetime | Fixed absolute expiry, optional idle timeout, list/revoke and custom store | Configurable renewal and optional cookie caching/stateless strategies in [session management](https://better-auth.com/docs/concepts/session-management) |
| Provider extensibility | Google only; provider construction is an internal seam, not a supported extension contract | Broader provider ecosystem and a generic OAuth [plugin](https://better-auth.com/docs/plugins) |
| Additional login experiences | Paste a high-entropy emailed token, password or Google; a username custom field does not enable username login | Optional magic links, email OTP, username, phone and anonymous authentication [plugins](https://better-auth.com/docs/plugins) |
| Enterprise identity | No arbitrary OIDC federation, SAML or SCIM | Public [SSO](https://better-auth.com/docs/plugins/sso) and [SCIM](https://better-auth.com/docs/plugins/scim) plugins; enterprise self-service SSO is a separate offering |
| Administration | Trusted provisioning, suspension/resumption and revocation functions; applications authorize callers and build management interfaces | [Admin plugin](https://better-auth.com/docs/plugins/admin) adds permission-controlled user/session management and impersonation |
| Client and extension APIs | Typed Gleam headless operations, HTTP API and starter pages; targeted password/store callbacks | Framework-specific typed clients and reactive session state, [client plugins](https://better-auth.com/docs/concepts/client), endpoint [hooks](https://better-auth.com/docs/concepts/hooks) and database hooks |
| Database integrations | PostgreSQL/SQLite through Gloo, explicit migrations, custom session-store contract | Broader [database/adaptor tooling](https://better-auth.com/docs/concepts/database), including Prisma, Drizzle and MongoDB, plus secondary storage |
| Shared HTTP rate limits | HTTP limits are in-process; password/account throttling is already database-backed | Configurable memory/database/secondary/custom [rate-limit storage](https://better-auth.com/docs/concepts/rate-limit); server-side `auth.api` calls bypass this limiter |
| Service/delegated access | Bearer session tokens already supported; no scoped API-key lifecycle or OAuth authorization server | Optional API-key, JWT, OAuth-provider and device-authorization [plugins](https://better-auth.com/docs/plugins) |

The organization difference is architectural. `AccountPerGroup` creates separate identities and credentials, rather than allowing one identity to join multiple organizations. Scoped authorization does not itself create membership or invitations. [Group model](../auth/src/howdy/auth/group.gleam).

Session caching is a tradeoff rather than an automatic improvement: Better Auth documents that revocation can remain stale until the cache expires. Howdy checks current account state on every authentication, even with an external session store. That store does not eliminate the database read, and cross-store mutations lose database/session atomicity. [Better Auth sessions](https://better-auth.com/docs/concepts/session-management), [Howdy storage contract](../auth/README.md#session-storage).

## Release readiness and verification

Howdy describes itself as an initial implementation. It depends on a locally patched native password dependency and documents that this must be resolved before Hex publication. It offers no rolling-upgrade compatibility guarantee; old instances should stop before migrations. These are material operational limitations beyond missing login features. [Installation and migration notes](../auth/README.md#install-and-migrate), [dependency patch](../auth/vendor/jargon/README.md).

Executed locally: `cd auth && gleam test` passed all 126 tests; `node --test test/pages_client_test.mjs` passed all four tests. Tests include concurrency, token replay, provider validation, session revocation, authorization and migrations. The [CI configuration](../.github/workflows/test.yml) includes SQLite/PostgreSQL and both native Argon2 implementations. PostgreSQL and the full CI matrix were not rerun for this comparison. This review is not a penetration test, independent security audit or performance benchmark.

## Suggested priorities

1. Complete everyday account lifecycle: verified email changes, deletion with application cleanup hooks, and safe provider unlinking.
2. Add passkeys and/or MFA with enrollment, recovery and sensitive-action reauthentication designed together.
3. Establish a supported external-provider extension contract and add providers users actually need.
4. If targeting collaborative SaaS, add an explicit user-to-organization membership model and invitation lifecycle. Preserve account partitioning where it is intentional.
5. Resolve packaging and upgrade limitations, then invest in client integrations and distributed operation according to actual deployment needs.

Howdy does not need every Better Auth plugin to be useful. The immediate objective should be a complete, supportable set of workflows for its intended applications.
