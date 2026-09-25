//// What the admin was given: which packages the application registered and
//// where the pages are mounted.

import gleam/option.{type Option}
import gloo/repo.{type Repo}
import howdy/auth.{type Auth}
import howdy/authorization.{type Authorization}
import howdy/mail.{type Mailer}
import howdy/mail/outbox.{type Outbox}
import howdy/mail/preview.{type Preview}
import howdy/telemetry/recorder.{type Recorder}

pub type Config {
  Config(
    /// Mount point without a trailing slash, such as `/_howdy`.
    prefix: String,
    /// Shown in the sidebar.
    name: String,
    database: Option(Repo),
    identity: Option(Auth),
    authorization: Option(Authorization),
    outbox: Option(Outbox),
    /// Email previews, and the mailer that renders and sends them.
    previews: List(Preview),
    mailer: Option(Mailer),
    recorder: Option(Recorder),
    /// Exact request hostnames the pages answer.
    hosts: List(String),
  )
}

/// A path under the mount point. `rest` starts with `/`, or is empty for
/// the mount point itself.
pub fn path(config: Config, rest: String) -> String {
  config.prefix <> rest
}
