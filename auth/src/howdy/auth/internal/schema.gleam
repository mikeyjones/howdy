import gloo/migration as gloo_migration
import howdy/migration

pub fn authentication() -> migration.Package {
  migration.Package("howdy_auth", [
    gloo_migration.new(
      1,
      "create_auth",
      "
CREATE TABLE howdy_auth_users (
  id TEXT PRIMARY KEY NOT NULL,
  email TEXT NOT NULL UNIQUE,
  suspended INTEGER NOT NULL DEFAULT 0 CHECK (suspended IN (0, 1))
);
CREATE TABLE howdy_auth_identities (
  issuer TEXT NOT NULL,
  subject TEXT NOT NULL,
  user_id TEXT NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE,
  PRIMARY KEY (issuer, subject)
);
CREATE TABLE howdy_auth_challenges (
  digest TEXT PRIMARY KEY NOT NULL,
  email TEXT NOT NULL,
  intent TEXT NOT NULL CHECK (intent IN ('login', 'register')),
  expires_at BIGINT NOT NULL
);
CREATE INDEX howdy_auth_challenges_expiry ON howdy_auth_challenges(expires_at);
CREATE TABLE howdy_auth_sessions (
  digest TEXT PRIMARY KEY NOT NULL,
  user_id TEXT NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE,
  expires_at BIGINT NOT NULL
);
CREATE INDEX howdy_auth_sessions_user ON howdy_auth_sessions(user_id);
CREATE INDEX howdy_auth_sessions_expiry ON howdy_auth_sessions(expires_at);
CREATE TABLE howdy_auth_throttles (
  key TEXT PRIMARY KEY NOT NULL,
  next_at BIGINT NOT NULL
);
CREATE TABLE howdy_auth_events (
  id TEXT PRIMARY KEY NOT NULL,
  user_id TEXT NOT NULL,
  action TEXT NOT NULL,
  occurred_at BIGINT NOT NULL
);
",
    ),
    gloo_migration.new(
      2,
      "add_password_authentication",
      "
ALTER TABLE howdy_auth_challenges ADD COLUMN password_hash TEXT;
CREATE TABLE howdy_auth_passwords (
  user_id TEXT PRIMARY KEY NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE,
  encoded_hash TEXT NOT NULL
);
CREATE TABLE howdy_auth_password_attempts (
  key TEXT PRIMARY KEY NOT NULL,
  window_start BIGINT NOT NULL,
  attempts INTEGER NOT NULL
);
",
    ),
    // Existing sessions predate the new columns: treat them as created one
    // default lifetime before they expire, so none counts as freshly issued.
    gloo_migration.new(
      3,
      "add_session_metadata_backoff_audit_detail_and_indexes",
      "
ALTER TABLE howdy_auth_sessions ADD COLUMN created_at BIGINT NOT NULL DEFAULT 0;
ALTER TABLE howdy_auth_sessions ADD COLUMN last_seen_at BIGINT NOT NULL DEFAULT 0;
ALTER TABLE howdy_auth_sessions ADD COLUMN method TEXT NOT NULL DEFAULT 'email' CHECK (method IN ('email', 'password'));
UPDATE howdy_auth_sessions SET created_at = expires_at - 86400, last_seen_at = expires_at - 86400;
ALTER TABLE howdy_auth_challenges ADD COLUMN created_at BIGINT NOT NULL DEFAULT 0;
CREATE INDEX howdy_auth_challenges_email ON howdy_auth_challenges(email);
ALTER TABLE howdy_auth_throttles ADD COLUMN strikes INTEGER NOT NULL DEFAULT 0;
CREATE INDEX howdy_auth_throttles_next ON howdy_auth_throttles(next_at);
CREATE INDEX howdy_auth_password_attempts_window ON howdy_auth_password_attempts(window_start);
CREATE INDEX howdy_auth_identities_user ON howdy_auth_identities(user_id);
ALTER TABLE howdy_auth_events ADD COLUMN actor_id TEXT NOT NULL DEFAULT '';
ALTER TABLE howdy_auth_events ADD COLUMN detail TEXT NOT NULL DEFAULT '';
CREATE INDEX howdy_auth_events_user ON howdy_auth_events(user_id, occurred_at);
CREATE INDEX howdy_auth_events_time ON howdy_auth_events(occurred_at);
",
    ),
    gloo_migration.new(
      4,
      "password_client_backoff",
      "
CREATE TABLE howdy_auth_password_clients (
 key TEXT PRIMARY KEY NOT NULL,
 email_key TEXT NOT NULL,
 failures INTEGER NOT NULL,
 next_at BIGINT NOT NULL,
 expires_at BIGINT NOT NULL
);
CREATE INDEX howdy_auth_password_clients_expiry ON howdy_auth_password_clients(expires_at);
CREATE INDEX howdy_auth_password_clients_email ON howdy_auth_password_clients(email_key);
",
    ),
    gloo_migration.new(
      5,
      "track_password_normalization",
      "
ALTER TABLE howdy_auth_passwords ADD COLUMN normalized INTEGER NOT NULL DEFAULT 0 CHECK (normalized IN (0, 1));
ALTER TABLE howdy_auth_challenges ADD COLUMN password_normalized INTEGER NOT NULL DEFAULT 0 CHECK (password_normalized IN (0, 1));
",
    ),
    gloo_migration.new(
      6,
      "record_request_client_and_throttle_key",
      "
ALTER TABLE howdy_auth_events ADD COLUMN client TEXT NOT NULL DEFAULT '';
ALTER TABLE howdy_auth_sessions ADD COLUMN client TEXT NOT NULL DEFAULT '';
CREATE TABLE howdy_auth_keys (
  name TEXT PRIMARY KEY NOT NULL,
  secret TEXT NOT NULL
);
DROP INDEX howdy_auth_challenges_email;
CREATE INDEX howdy_auth_challenges_email_expiry ON howdy_auth_challenges(email, expires_at);
",
    ),
    // The unique column becomes the login key so uniqueness can be per address
    // or per address and group; see `group.login_key`. Renaming rather than
    // rebuilding keeps every row that references a user.
    gloo_migration.new(
      7,
      "add_groups",
      "
CREATE TABLE howdy_auth_groups (
  id TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL
);
INSERT INTO howdy_auth_groups(id, name) VALUES ('default', 'Default');
ALTER TABLE howdy_auth_users RENAME COLUMN email TO login_key;
ALTER TABLE howdy_auth_users ADD COLUMN email TEXT NOT NULL DEFAULT '';
ALTER TABLE howdy_auth_users ADD COLUMN group_id TEXT REFERENCES howdy_auth_groups(id);
UPDATE howdy_auth_users SET email = login_key, group_id = 'default';
CREATE INDEX howdy_auth_users_email ON howdy_auth_users(email);
CREATE INDEX howdy_auth_users_group ON howdy_auth_users(group_id);
ALTER TABLE howdy_auth_challenges ADD COLUMN group_id TEXT REFERENCES howdy_auth_groups(id) ON DELETE CASCADE;
CREATE TABLE howdy_auth_settings (
  name TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
);
",
    ),
  ])
}

pub fn authorization() -> migration.Package {
  migration.Package("howdy_authz", [
    gloo_migration.new(
      1,
      "create_authz",
      "
CREATE TABLE howdy_authz_roles (
  scope TEXT NOT NULL,
  name TEXT NOT NULL,
  PRIMARY KEY (scope, name)
);
CREATE TABLE howdy_authz_permissions (
  scope TEXT NOT NULL,
  role TEXT NOT NULL,
  permission TEXT NOT NULL,
  PRIMARY KEY (scope, role, permission),
  FOREIGN KEY (scope, role) REFERENCES howdy_authz_roles(scope, name) ON DELETE CASCADE
);
CREATE TABLE howdy_authz_assignments (
  user_id TEXT NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE,
  scope TEXT NOT NULL,
  role TEXT NOT NULL,
  PRIMARY KEY (user_id, scope, role),
  FOREIGN KEY (scope, role) REFERENCES howdy_authz_roles(scope, name) ON DELETE CASCADE
);
",
    ),
    gloo_migration.new(
      2,
      "index_assignments_by_role",
      "
CREATE INDEX howdy_authz_assignments_role ON howdy_authz_assignments(scope, role);
",
    ),
  ])
}
