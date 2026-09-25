//// Ready-made emails for auth, sent with `howdy/mail`: one template for each
//// `auth.Purpose`, and one for MFA codes. Replace any of them with your own.
////
//// ```gleam
//// import howdy/auth
//// import howdy/auth/emails
//// import howdy/auth/mfa
////
//// let auth_emails = emails.new(mailer, app_name: "Acme")
//// let assert Ok(identity) =
////   auth.new(repo:, origin:, deliver: emails.deliver(auth_emails))
//// let mfa_config = mfa.with_delivery(config, emails.deliver_mfa(auth_emails))
//// ```
////
//// Each message goes to the delivery's address and is tagged
//// `auth.<purpose>`, such as `auth.sign_in`, so it is easy to find in the
//// admin outbox. `previews` gives the admin a preview of every template.
////
//// A token, link or code is only revealed into the message body. A failed
//// send is logged without it, and the auth flow reports the failure.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import howdy/auth.{type Delivery, type Purpose, Delivery}
import howdy/auth/secret.{type Secret}
import howdy/auth/user.{type User}
import howdy/mail.{type Mailer, type Message}
import howdy/mail/preview.{type Preview}
import logging
import smail/attribute
import smail/email
import smail/html
import smail/style

pub opaque type Emails {
  Emails(
    mailer: Mailer,
    app_name: String,
    templates: List(#(Purpose, fn(Delivery) -> Message)),
    mfa: Option(fn(String, Secret) -> Message),
  )
}

/// The default templates, naming the app `app_name`, sent with `mailer`.
pub fn new(mailer: Mailer, app_name app_name: String) -> Emails {
  Emails(mailer:, app_name:, templates: [], mfa: None)
}

/// Build the email for one purpose yourself. Set the subject and body;
/// the recipient and the `auth.<purpose>` tag are added for you.
pub fn with_template(
  emails: Emails,
  for purpose: Purpose,
  build build: fn(Delivery) -> Message,
) -> Emails {
  Emails(..emails, templates: [
    #(purpose, build),
    ..list.filter(emails.templates, fn(entry) { entry.0 != purpose })
  ])
}

/// Build the MFA code email yourself, from the address and the code.
pub fn with_mfa_template(
  emails: Emails,
  build: fn(String, Secret) -> Message,
) -> Emails {
  Emails(..emails, mfa: Some(build))
}

/// The function `auth.new` and `auth.with_email_tokens` take.
pub fn deliver(emails: Emails) -> fn(Delivery) -> Result(Nil, Nil) {
  fn(delivery: Delivery) {
    send(emails, message(emails, delivery), delivery.email)
  }
}

/// The function `mfa.with_delivery` takes.
pub fn deliver_mfa(emails: Emails) -> fn(User, Secret) -> Result(Nil, Nil) {
  fn(user: User, code: Secret) {
    send(emails, mfa_message(emails, user.email, code), user.email)
  }
}

fn send(emails: Emails, message: Message, email: String) -> Result(Nil, Nil) {
  case mail.send(emails.mailer, message) {
    Ok(_) -> Ok(Nil)
    Error(error) -> {
      logging.log(
        logging.Error,
        "howdy/auth/emails: not sent to "
          <> email
          <> ": "
          <> mail.error_to_string(error),
      )
      Error(Nil)
    }
  }
}

/// The message for a delivery: yours if `with_template` gave one for its
/// purpose, otherwise the default.
pub fn message(emails: Emails, delivery: Delivery) -> Message {
  let build = case list.key_find(emails.templates, delivery.purpose) {
    Ok(build) -> build
    Error(Nil) -> default(emails.app_name, _)
  }
  build(delivery)
  |> mail.to([mail.address(delivery.email)])
  |> mail.tag("auth." <> purpose_name(delivery.purpose))
}

/// The MFA code message.
pub fn mfa_message(emails: Emails, email: String, code: Secret) -> Message {
  case emails.mfa {
    Some(build) -> build(email, code)
    None -> default_mfa(emails.app_name, code)
  }
  |> mail.to([mail.address(email)])
  |> mail.tag("auth.mfa_code")
}

/// `sign_in`, `registration` and so on.
pub fn purpose_name(purpose: Purpose) -> String {
  case purpose {
    auth.SignIn -> "sign_in"
    auth.Registration -> "registration"
    auth.AlreadyRegistered -> "already_registered"
    auth.EmailChange -> "email_change"
    auth.EmailChangeApproval -> "email_change_approval"
    auth.EmailChanged -> "email_changed"
    auth.PasswordChanged -> "password_changed"
  }
}

const purposes = [
  auth.SignIn,
  auth.Registration,
  auth.AlreadyRegistered,
  auth.EmailChange,
  auth.EmailChangeApproval,
  auth.EmailChanged,
  auth.PasswordChanged,
]

/// A preview of every template, grouped under "Auth", with made-up tokens,
/// links and codes sent to `someone@example.com`.
pub fn previews(emails: Emails) -> List(Preview) {
  let sample = fn(purpose) {
    let notice = purpose == auth.EmailChanged || purpose == auth.PasswordChanged
    let signs_in =
      purpose == auth.SignIn
      || purpose == auth.Registration
      || purpose == auth.AlreadyRegistered
    Delivery(
      email: "someone@example.com",
      token: secret.wrap(case notice {
        True -> ""
        False -> "preview-token-0123456789abcdefghijklmnopqrstuv"
      }),
      purpose:,
      link: case notice {
        True -> None
        False ->
          Some(secret.wrap(
            "https://example.com/auth/login#token=preview-token-0123456789abcdefghijklmnopqrstuv",
          ))
      },
      code: case signs_in {
        True -> Some(secret.wrap("123456"))
        False -> None
      },
    )
  }
  list.append(
    list.map(purposes, fn(purpose) {
      preview.new(title(purpose), fn() { message(emails, sample(purpose)) })
      |> preview.in_group("Auth")
    }),
    [
      preview.new("MFA code", fn() {
        mfa_message(emails, "someone@example.com", secret.wrap("482913"))
      })
      |> preview.in_group("Auth"),
    ],
  )
}

fn title(purpose: Purpose) -> String {
  case purpose {
    auth.SignIn -> "Sign in"
    auth.Registration -> "Registration"
    auth.AlreadyRegistered -> "Already registered"
    auth.EmailChange -> "Email change"
    auth.EmailChangeApproval -> "Email change approval"
    auth.EmailChanged -> "Email changed"
    auth.PasswordChanged -> "Password changed"
  }
}

// -- The default templates -----------------------------------------------------

/// The default message for a delivery, without its recipient.
pub fn default(app_name: String, delivery: Delivery) -> Message {
  let link = option.map(delivery.link, secret.reveal)
  let code = option.map(delivery.code, secret.reveal)
  let token = secret.reveal(delivery.token)
  let #(subject, heading, paragraphs, action, closing) = case delivery.purpose {
    auth.SignIn -> #(
      "Sign in to " <> app_name,
      "Sign in to " <> app_name,
      ["Use this to sign in. It works once and expires soon."],
      "Sign in",
      "If you did not ask to sign in, you can ignore this email.",
    )
    auth.Registration -> #(
      "Confirm your " <> app_name <> " account",
      "Welcome to " <> app_name,
      ["Confirm this address to finish creating your account."],
      "Confirm and sign in",
      "If you did not create an account, you can ignore this email.",
    )
    auth.AlreadyRegistered -> #(
      "You already have a " <> app_name <> " account",
      "You already have an account",
      [
        "Someone asked to register this address, but it already has an account. Use this to sign in to it instead.",
      ],
      "Sign in",
      "If this was not you, you can ignore this email. Nothing has changed.",
    )
    auth.EmailChange -> #(
      "Confirm your new email address",
      "Confirm your new email address",
      [
        "Confirm this address to make it the one your "
        <> app_name
        <> " account signs in with.",
      ],
      "Confirm this address",
      "If you did not ask for this, you can ignore this email.",
    )
    auth.EmailChangeApproval -> #(
      "Approve your " <> app_name <> " email change",
      "Approve the email change",
      [
        "Someone signed in to your account asked to move it to another email address. Approve it while signed in to go ahead.",
      ],
      "Approve the change",
      "If this was not you, do not approve it. Sign in and change your password, and sign out of your other sessions.",
    )
    auth.EmailChanged -> #(
      "Your " <> app_name <> " email address changed",
      "Your email address changed",
      [
        "Your account now signs in with a different email address, and this one can no longer be used to recover it.",
      ],
      "",
      "If you did not do this, contact support straight away.",
    )
    auth.PasswordChanged -> #(
      "Your " <> app_name <> " password changed",
      "Your password changed",
      ["The password for your account was just changed."],
      "",
      "If you did not do this, sign in with a link sent by email and set a new password.",
    )
  }
  let credential = case delivery.purpose {
    auth.EmailChanged | auth.PasswordChanged -> []
    _ ->
      list.flatten([
        case link {
          Some(link) -> [
            email.section([style.margin("24px 0")], [
              email.button(
                [
                  attribute.href(link),
                  style.background_color("#18181b"),
                  style.color("#ffffff"),
                  style.border_radius("6px"),
                  style.padding("12px 20px"),
                  style.font_weight("600"),
                ],
                [html.text(action)],
              ),
            ]),
          ]
          None -> []
        },
        case code {
          Some(code) -> [
            paragraph("Or enter this code:"),
            email.paragraph(
              [
                style.font_size("28px"),
                style.font_weight("700"),
                style.letter_spacing("6px"),
                style.margin("8px 0 24px"),
              ],
              [html.text(code)],
            ),
          ]
          None -> []
        },
        case link, code {
          None, None -> [
            paragraph("Paste this token where you were asked for it:"),
            monospace(token),
          ]
          _, _ -> []
        },
      ])
  }
  // smail can render plain text too, but runs a paragraph into the URL
  // of a button before it, which would break the link for text readers.
  let plain =
    list.flatten([
      [heading],
      paragraphs,
      case delivery.purpose {
        auth.EmailChanged | auth.PasswordChanged -> []
        _ ->
          list.flatten([
            case link {
              Some(link) -> [action <> ":\n" <> link]
              None -> []
            },
            case code {
              Some(code) -> ["Or enter this code: " <> code]
              None -> []
            },
            case link, code {
              None, None -> [
                "Paste this token where you were asked for it:\n" <> token,
              ]
              _, _ -> []
            },
          ])
      },
      [closing, "-- \n" <> app_name],
    ])
    |> string.join("\n\n")
  mail.message()
  |> mail.subject(subject)
  |> mail.template(page(
    app_name,
    preview: heading,
    content: list.flatten([
      [
        email.h1([style.font_size("24px"), style.line_height("32px")], [
          html.text(heading),
        ]),
      ],
      list.map(paragraphs, paragraph),
      credential,
      [small(closing)],
    ]),
  ))
  |> mail.text(plain)
}

/// The default MFA code message, without its recipient.
pub fn default_mfa(app_name: String, code: Secret) -> Message {
  mail.message()
  |> mail.subject("Your " <> app_name <> " verification code")
  |> mail.template(
    page(app_name, preview: "Your verification code", content: [
      email.h1([style.font_size("24px"), style.line_height("32px")], [
        html.text("Your verification code"),
      ]),
      paragraph("Enter this code to finish signing in:"),
      email.paragraph(
        [
          style.font_size("28px"),
          style.font_weight("700"),
          style.letter_spacing("6px"),
          style.margin("8px 0 24px"),
        ],
        [html.text(secret.reveal(code))],
      ),
      small("If you are not signing in, someone has your password: change it."),
    ]),
  )
  |> mail.text(
    "Your verification code\n\nEnter this code to finish signing in: "
    <> secret.reveal(code)
    <> "\n\nIf you are not signing in, someone has your password: change it.\n\n-- \n"
    <> app_name,
  )
}

fn page(
  app_name: String,
  preview preview: String,
  content content: List(html.Element),
) -> html.Element {
  email.html([attribute.lang("en")], [
    email.head([], []),
    email.body(
      [
        style.background_color("#f4f4f5"),
        style.font_family(
          "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif",
        ),
        style.color("#18181b"),
      ],
      [
        email.preview(preview),
        email.container(
          [
            style.max_width("480px"),
            style.margin("40px auto"),
            style.padding("32px"),
            style.background_color("#ffffff"),
            style.border_radius("8px"),
          ],
          list.append(content, [
            email.hr([style.margin("32px 0 16px")]),
            small(app_name),
          ]),
        ),
      ],
    ),
  ])
}

fn paragraph(text: String) -> html.Element {
  email.paragraph([style.font_size("16px"), style.line_height("24px")], [
    html.text(text),
  ])
}

fn small(text: String) -> html.Element {
  email.paragraph(
    [
      style.font_size("13px"),
      style.line_height("20px"),
      style.color("#71717a"),
    ],
    [html.text(text)],
  )
}

fn monospace(text: String) -> html.Element {
  email.paragraph(
    [
      style.font_family("ui-monospace, Menlo, monospace"),
      style.font_size("14px"),
      style.background_color("#f4f4f5"),
      style.padding("12px"),
      style.border_radius("6px"),
      style.word_break("break-all"),
    ],
    [html.text(text)],
  )
}
