import gleam/http/request
import gleam/list
import gleam/option
import gleam/string
import gleeunit
import gloo/repo
import howdy/admin
import howdy/auth
import howdy/mail
import howdy/mail/outbox
import howdy/mail/preview
import howdy/testing
import howdy_admin_example as example

pub fn main() {
  gleeunit.main()
}

/// The admin mounts on the example's app and sees its table.
pub fn the_admin_sees_the_notes_table_test() {
  let db = example.open(":memory:")
  let box = outbox.start()
  let mailer =
    mail.mailer(outbox.adapter(box)) |> mail.default_from(example.sender)
  let identity = example.identity(db, mailer)
  let permissions = example.permissions(db)
  let app =
    example.app(db, identity, permissions)
    |> admin.mount(
      admin.new() |> admin.auth(identity) |> admin.authorization(permissions),
    )
  let res =
    testing.get("/_howdy/data")
    |> request.set_host("localhost")
    |> testing.send(app)
  assert res.status == 200
  assert string.contains(testing.text(res), "notes_notes")
  let res =
    testing.get("/_howdy/roles")
    |> request.set_host("localhost")
    |> testing.send(app)
  assert string.contains(testing.text(res), "reader")
  let assert Ok(_) = repo.close(db)
}

/// Registering sends the auth email to the outbox, with a link to the
/// starter pages, and every email has a preview that renders.
pub fn registration_mail_reaches_the_outbox_test() {
  let db = example.open(":memory:")
  let box = outbox.start()
  let mailer =
    mail.mailer(outbox.adapter(box)) |> mail.default_from(example.sender)
  let identity = example.identity(db, mailer)
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Register)
  let assert Ok(sent) = outbox.latest_to(box, "ada@example.com")
  assert sent.subject == "Confirm your Notes account"
  let assert option.Some(text) = sent.text
  assert string.contains(text, example.origin <> "/auth/login#token=")

  let app =
    example.app(db, identity, example.permissions(db))
    |> admin.mount(
      admin.new()
      |> admin.mail(box)
      |> admin.mail_previews(example.previews(mailer), send_with: mailer),
    )
  list.each(example.previews(mailer), fn(p) {
    let res =
      testing.get("/_howdy/mail/previews?p=" <> preview.key(p))
      |> request.set_host("localhost")
      |> testing.send(app)
    assert res.status == 200
    assert !string.contains(testing.text(res), "would not be sent")
    assert !string.contains(testing.text(res), "crashed")
  })
  let assert Ok(_) = repo.close(db)
}
