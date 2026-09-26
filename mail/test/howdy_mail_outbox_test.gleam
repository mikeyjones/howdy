import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import howdy/mail
import howdy/mail/outbox
import simplifile

fn mailer(box: outbox.Outbox) -> mail.Mailer {
  mail.mailer(outbox.adapter(box))
  |> mail.default_from(mail.address("hello@acme.test"))
}

fn message(to: String, subject: String) -> mail.Message {
  mail.message()
  |> mail.to([mail.address(to)])
  |> mail.subject(subject)
  |> mail.html("<p>" <> subject <> "</p>")
  |> mail.text(subject)
  |> mail.tag("test")
}

fn temporary_directory() -> String {
  let directory =
    "build/test-outbox-" <> int.to_string(int.random(1_000_000_000))
  let _ = simplifile.delete(directory)
  directory
}

pub fn keeps_messages_newest_first_test() {
  let box = outbox.start()
  let assert Ok(first) = mail.send(mailer(box), message("a@example.com", "One"))
  let assert Ok(_) = mail.send(mailer(box), message("b@example.com", "Two"))
  let assert [newest, oldest] = outbox.messages(box)
  assert newest.subject == "Two"
  assert oldest.subject == "One"
  assert outbox.get(box, first.id) == Ok(oldest)
  let assert Ok(latest) = outbox.latest_to(box, "A@Example.com")
  assert latest.subject == "One"
  assert outbox.latest_to(box, "nobody@example.com") == Error(Nil)
  assert outbox.directory(box) == None
  outbox.clear(box)
  assert outbox.messages(box) == []
}

pub fn keeps_only_the_newest_test() {
  let box = outbox.start()
  int.range(from: 1, to: outbox.capacity + 4, with: Nil, run: fn(_, n) {
    let assert Ok(_) =
      mail.send(mailer(box), message("a@example.com", int.to_string(n)))
    Nil
  })
  let messages = outbox.messages(box)
  assert list.length(messages) == outbox.capacity
  let assert [newest, ..] = messages
  assert newest.subject == int.to_string(outbox.capacity + 3)
}

pub fn subscribers_hear_about_changes_test() {
  let box = outbox.start()
  let heard = process.new_subject()
  outbox.subscribe(box, fn() { process.send(heard, Nil) })
  let assert Ok(_) = mail.send(mailer(box), message("a@example.com", "One"))
  assert process.receive(heard, 1000) == Ok(Nil)
  outbox.clear(box)
  assert process.receive(heard, 1000) == Ok(Nil)
}

pub fn subscribers_are_dropped_when_they_exit_test() {
  let box = outbox.start()
  let heard = process.new_subject()
  let done = process.new_subject()
  process.spawn(fn() {
    outbox.subscribe(box, fn() { process.send(heard, Nil) })
    process.send(done, Nil)
  })
  let assert Ok(Nil) = process.receive(done, 1000)
  process.sleep(50)
  let assert Ok(_) = mail.send(mailer(box), message("a@example.com", "One"))
  assert process.receive(heard, 100) == Error(Nil)
}

pub fn a_crashing_subscriber_does_not_stop_the_outbox_test() {
  let box = outbox.start()
  outbox.subscribe(box, fn() { panic as "boom" })
  let assert Ok(_) = mail.send(mailer(box), message("a@example.com", "One"))
  let assert Ok(_) = mail.send(mailer(box), message("a@example.com", "Two"))
  assert list.length(outbox.messages(box)) == 2
}

pub fn directory_survives_a_restart_test() {
  let directory = temporary_directory()
  let assert Ok(box) = outbox.start_in(directory)
  assert outbox.directory(box) == Some(directory)
  let assert Ok(_) =
    mail.send(
      mailer(box),
      message("a@example.com", "Grüße")
        |> mail.cc([mail.named("C", "c@example.com")])
        |> mail.reply_to(mail.address("r@acme.test"))
        |> mail.header("X-Test", "yes")
        |> mail.attach(
          mail.attachment("a.bin", "application/octet-stream", <<0, 1, 2, 255>>)
          |> mail.inline("a"),
        ),
    )
  let assert Ok(_) = mail.send(mailer(box), message("b@example.com", "Two"))
  let assert Ok(files) = simplifile.read_directory(directory)
  assert list.count(files, string.ends_with(_, ".eml")) == 2
  assert list.count(files, string.ends_with(_, ".json")) == 2

  let before = outbox.messages(box)
  let assert Ok(again) = outbox.start_in(directory)
  assert outbox.messages(again) == before

  outbox.clear(again)
  let assert Ok(files) = simplifile.read_directory(directory)
  assert files == []
  let _ = simplifile.delete(directory)
}

pub fn unreadable_files_are_skipped_test() {
  let directory = temporary_directory()
  let assert Ok(_) = simplifile.create_directory_all(directory)
  let assert Ok(_) = simplifile.write(directory <> "/junk.json", "{not json")
  let assert Ok(box) = outbox.start_in(directory)
  assert outbox.messages(box) == []
  let _ = simplifile.delete(directory)
}
