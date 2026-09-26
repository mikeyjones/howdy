//// The feature flag pages: every flag with its state, one flag's kill
//// switch, rollout, ramp, rules and history, a check of who gets it, and
//// the groups rules can name.

import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import gleam/uri
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/layout
import howdy/auth/users
import howdy/content.{type Content}
import howdy/controller.{type Context, type Controller}
import howdy/flags.{type Flags, type Setting, type Target}
import howdy/form.{type Form}
import howdy/service
import howdy/ui
import howdy/ui/badge
import howdy/ui/button
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

const actor = "howdy_admin"

pub fn controller(config: Config, features: Flags) -> Controller {
  let act = fn(run) { fn(ctx) { act(config, ctx, run) } }
  controller.new(config.prefix)
  |> controller.get("/flags", fn(ctx) { index(config, features, ctx) })
  |> controller.get("/flags/flag", fn(ctx) { show(config, features, ctx) })
  |> controller.post(
    "/flags/flag/kill",
    act(fn(key, _) { flags.kill(features, key, by: actor) }),
  )
  |> controller.post(
    "/flags/flag/revive",
    act(fn(key, _) { flags.revive(features, key, by: actor) }),
  )
  |> controller.post(
    "/flags/flag/allow",
    act(fn(key, form) {
      use target <- result.try(read_target(config, form))
      flags.allow(features, key, target, by: actor)
    }),
  )
  |> controller.post(
    "/flags/flag/block",
    act(fn(key, form) {
      use target <- result.try(read_target(config, form))
      flags.block(features, key, target, by: actor)
    }),
  )
  |> controller.post(
    "/flags/flag/unlist",
    act(fn(key, form) {
      use target <- result.try(
        flags.target_from_string(form.value(form, "target"))
        |> result.replace_error(service.Invalid("no such rule")),
      )
      flags.unlist(features, key, target, by: actor)
    }),
  )
  |> controller.post(
    "/flags/flag/forget",
    act(fn(key, _) { flags.forget(features, key, by: actor) }),
  )
  |> controller.post(
    "/flags/flag/undo",
    act(fn(_, form) {
      use id <- result.try(
        int.parse(form.value(form, "change"))
        |> result.replace_error(service.NotFound("no such change")),
      )
      flags.undo(features, change: id, by: actor)
    }),
  )
  |> controller.get("/flags/groups", fn(ctx) { groups(config, features, ctx) })
  |> controller.post("/flags/groups", fn(ctx) {
    use form <- form.read(ctx)
    let name = string.trim(form.value(form, "name"))
    case
      flags.create_group(
        features,
        name,
        description: form.value(form, "description"),
        by: actor,
      )
    {
      Ok(Nil) -> layout.redirect(group_path(config, name))
      Error(error) -> groups_failure(config, ctx, error)
    }
  })
  |> controller.get("/flags/groups/group", fn(ctx) {
    group(config, features, ctx)
  })
  |> controller.post("/flags/groups/group/add", fn(ctx) {
    use name <- with_group(config, ctx)
    use form <- form.read(ctx)
    let outcome = {
      use member <- result.try(read_target(config, form))
      flags.add_member(features, name, member, by: actor)
    }
    case outcome {
      Ok(Nil) -> layout.redirect(group_path(config, name))
      Error(error) -> groups_failure(config, ctx, error)
    }
  })
  |> controller.post("/flags/groups/group/remove", fn(ctx) {
    use name <- with_group(config, ctx)
    use form <- form.read(ctx)
    let outcome = {
      use member <- result.try(
        flags.target_from_string(form.value(form, "member"))
        |> result.replace_error(service.Invalid("no such member")),
      )
      flags.remove_member(features, name, member, by: actor)
    }
    case outcome {
      Ok(Nil) -> layout.redirect(group_path(config, name))
      Error(error) -> groups_failure(config, ctx, error)
    }
  })
  |> controller.post("/flags/groups/group/delete", fn(ctx) {
    use name <- with_group(config, ctx)
    case flags.delete_group(features, name, by: actor) {
      Ok(Nil) -> layout.redirect(config.path(config, "/flags/groups"))
      Error(error) -> groups_failure(config, ctx, error)
    }
  })
}

// -- Flags -------------------------------------------------------------------

/// A row of the index: a registered flag, or a stored key the code no
/// longer has.
type Entry {
  Entry(key: String, flag: Option(flags.Flag), setting: Option(Setting))
}

fn entries(features: Flags) -> service.Result(List(Entry)) {
  use stored <- result.map(flags.settings(features))
  let defined = flags.defined(features)
  let registered =
    list.map(defined, fn(flag) {
      Entry(
        key: flags.key(flag),
        flag: Some(flag),
        setting: list.key_find(stored, flags.key(flag)) |> option.from_result,
      )
    })
  let orphans =
    list.filter_map(stored, fn(row) {
      case list.any(defined, fn(flag) { flags.key(flag) == row.0 }) {
        True -> Error(Nil)
        False -> Ok(Entry(key: row.0, flag: None, setting: Some(row.1)))
      }
    })
  list.append(registered, orphans)
}

fn index(config: Config, features: Flags, ctx: Context) -> Response(Content) {
  let found = {
    use entries <- result.try(entries(features))
    use changes <- result.try(flags.history(features, of: None, limit: 20))
    Ok(#(entries, changes))
  }
  case found {
    Error(error) -> failure(config, ctx, "Flags", error)
    Ok(#(entries, changes)) ->
      layout.page(
        config,
        ctx,
        current: "/flags",
        heading: "Flags",
        live: False,
        content: [
          read_only_notice(features),
          case entries {
            [] ->
              ui.empty(
                icon: text("🚩"),
                title: "No flags registered",
                description: "Define flags with flags.flag and pass them to flags.register before flags.start.",
                actions: [],
              )
            _ ->
              ui.table([], [
                ui.table_header([], [
                  ui.table_row([], [
                    ui.table_head([], [text("Flag")]),
                    ui.table_head([], [text("State")]),
                    ui.table_head([], [text("Rules")]),
                    ui.table_head([], [text("Description")]),
                  ]),
                ]),
                ui.table_body(
                  [],
                  list.map(entries, fn(entry) {
                    ui.table_row([], [
                      ui.table_cell([], [
                        ui.link(flag_path(config, entry.key), [
                          html.code([], [text(entry.key)]),
                        ]),
                      ]),
                      ui.table_cell([], state_badges(entry)),
                      ui.table_cell([], [text(rule_count(entry.setting))]),
                      ui.table_cell([], [
                        case entry.flag {
                          Some(flag) -> text(flags.description(flag))
                          None ->
                            ui.muted(
                              "Not in the code any more: reset it to tidy it away.",
                            )
                        },
                      ]),
                    ])
                  }),
                ),
              ])
          },
          ui.card([], [
            ui.card_header([], [ui.card_title([text("Recent changes")])]),
            ui.card_content([], [
              history_table(config, changes, True, flags.writable(features)),
            ]),
          ]),
        ],
      )
  }
}

fn show(config: Config, features: Flags, ctx: Context) -> Response(Content) {
  use key <- with_key(config, ctx)
  let found = {
    use entries <- result.try(entries(features))
    use entry <- result.try(
      list.find(entries, fn(entry) { entry.key == key })
      |> result.replace_error(service.NotFound("no flag named " <> key)),
    )
    use changes <- result.try(flags.history(features, of: Some(key), limit: 50))
    Ok(#(entry, changes))
  }
  case found {
    Error(error) -> failure(config, ctx, key, error)
    Ok(#(entry, changes)) -> {
      let here = flag_path(config, key)
      let action = fn(name) {
        config.path(config, "/flags/flag/" <> name <> "?")
        <> uri.query_to_string([#("key", key)])
      }
      let current = case entry.flag, entry.setting {
        _, Some(setting) -> setting
        Some(flag), None ->
          flags.Setting(
            killed: False,
            rollout: case flags.default(flag) {
              True -> 10_000
              False -> 0
            },
            bucketing: flags.ByUser,
            allowed: [],
            blocked: [],
            ramp: None,
          )
        None, None ->
          flags.Setting(
            killed: False,
            rollout: 0,
            bucketing: flags.ByUser,
            allowed: [],
            blocked: [],
            ramp: None,
          )
      }
      let writable = flags.writable(features)
      layout.page(
        config,
        ctx,
        current: "/flags",
        heading: key,
        live: False,
        content: [
          ui.p([
            ui.link(config.path(config, "/flags"), [text("All flags")]),
            text(" · "),
            ..state_badges(entry)
          ]),
          case entry.flag {
            Some(flag) ->
              ui.p([
                text(flags.description(flag)),
                ui.muted(
                  " Default "
                  <> case flags.default(flag) {
                    True -> "on"
                    False -> "off"
                  }
                  <> case entry.setting {
                    Some(_) -> ", overridden by what is stored."
                    None -> ", and nothing is stored: that is what applies."
                  }
                  <> " Rollouts and ramps are set from the app or a console with howdy/flags, not here.",
                ),
              ])
            None ->
              ui.p([
                ui.muted(
                  "The code no longer registers this flag. Its settings are unused; reset it to delete them.",
                ),
              ])
          },
          read_only_notice(features),
          case entry.flag {
            None -> element.none()
            Some(flag) ->
              ui.stack([], [
                case writable {
                  True -> kill_card(action, current)
                  False -> element.none()
                },
                rules_card(config, action, current, writable),
                check_card(config, ctx, features, flag, here),
              ])
          },
          ui.card([], [
            ui.card_header([], [ui.card_title([text("History")])]),
            ui.card_content([], [
              history_table(config, changes, False, flags.writable(features)),
            ]),
            case entry.setting, writable {
              Some(_), True ->
                ui.card_footer([], [
                  html.form(
                    [
                      attribute.method("post"),
                      attribute.action(action("forget")),
                    ],
                    [
                      ui.submit_button(button.Outline, [], [
                        text("Reset to the default"),
                      ]),
                    ],
                  ),
                ])
              _, _ -> element.none()
            },
          ]),
        ],
      )
    }
  }
}

/// Where read-only flags are managed, when they are.
fn read_only_notice(features: Flags) -> Element(msg) {
  case flags.writable(features) {
    True -> element.none()
    False ->
      ui.p([
        ui.muted(
          "These flags are kept in "
          <> flags.store_name(features)
          <> ", which is read-only here: change them where they are managed.",
        ),
      ])
  }
}

fn kill_card(action: fn(String) -> String, setting: Setting) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("Kill switch")]),
      ui.card_description([
        text(case setting.killed {
          True ->
            "On: the flag is off for everyone, whatever the rules and rollout say."
          False ->
            "Off. Turning it on switches the flag off for everyone at once and pauses any ramp."
        }),
      ]),
    ]),
    ui.card_content([], [
      html.form(
        [
          attribute.method("post"),
          attribute.action(
            action(case setting.killed {
              True -> "revive"
              False -> "kill"
            }),
          ),
        ],
        [
          case setting.killed {
            True ->
              ui.submit_button(button.Primary, [], [text("Revive the flag")])
            False ->
              ui.submit_button(button.Danger, [], [text("Kill the flag")])
          },
        ],
      ),
    ]),
  ])
}

fn rules_card(
  config: Config,
  action: fn(String) -> String,
  setting: Setting,
  writable: Bool,
) -> Element(msg) {
  let rules =
    list.append(
      list.map(setting.blocked, fn(target) { #(target, "blocked") }),
      list.map(setting.allowed, fn(target) { #(target, "allowed") }),
    )
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("Users, organizations and groups")]),
      ui.card_description([
        text(
          "Allowed targets get the flag whatever the rollout; blocked ones never do. Blocks win over allows; the kill switch wins over both.",
        ),
      ]),
    ]),
    ui.card_content([], [
      ui.stack([], [
        case rules {
          [] -> ui.p([ui.muted("No rules.")])
          _ ->
            ui.table([], [
              ui.table_body(
                [],
                list.map(rules, fn(rule) {
                  ui.table_row([], [
                    ui.table_cell([], [target_view(config, rule.0)]),
                    ui.table_cell([], [
                      ui.badge(
                        case rule.1 {
                          "blocked" -> badge.Danger
                          _ -> badge.Secondary
                        },
                        [],
                        [text(rule.1)],
                      ),
                    ]),
                    ui.table_cell([], [
                      case writable {
                        False -> element.none()
                        True ->
                          html.form(
                            [
                              attribute.method("post"),
                              attribute.action(action("unlist")),
                            ],
                            [
                              html.input([
                                attribute.type_("hidden"),
                                attribute.name("target"),
                                attribute.value(flags.target_to_string(rule.0)),
                              ]),
                              ui.sized_button(
                                button.Ghost,
                                button.Small,
                                [attribute.type_("submit")],
                                [text("Remove")],
                              ),
                            ],
                          )
                      },
                    ]),
                  ])
                }),
              ),
            ])
        },
        case writable {
          False -> element.none()
          True ->
            html.form(
              [attribute.method("post"), attribute.action(action("allow"))],
              [
                ui.row(
                  [],
                  list.append(target_inputs(config, "rule"), [
                    ui.submit_button(button.Secondary, [], [text("Allow")]),
                    ui.submit_button(
                      button.Outline,
                      [attribute.formaction(action("block"))],
                      [text("Block")],
                    ),
                  ]),
                ),
              ],
            )
        },
      ]),
    ]),
  ])
}

/// Who gets the flag, and why, for any user and organization.
fn check_card(
  config: Config,
  ctx: Context,
  features: Flags,
  flag: flags.Flag,
  here: String,
) -> Element(msg) {
  let query = request.get_query(ctx.request) |> result.unwrap([])
  let asked = fn(name) {
    list.key_find(query, name) |> result.unwrap("") |> string.trim
  }
  let user = asked("user")
  let organization = asked("org")
  let answer = case user, organization {
    "", "" -> element.none()
    _, _ -> {
      let user = case config.identity, string.contains(user, "@") {
        Some(identity), True ->
          users.list(identity)
          |> result.unwrap([])
          |> list.find(fn(found) { found.email == user })
          |> result.map(fn(found) { found.id })
          |> result.unwrap(user)
        _, _ -> user
      }
      let who = case user {
        "" -> flags.anonymous()
        id -> flags.user(id)
      }
      let who = case organization {
        "" -> who
        id -> flags.in_organization(who, id)
      }
      let decision = flags.explain(features, flag, for: who)
      ui.p([
        case flags.is_on(decision) {
          True -> ui.badge(badge.Primary, [], [text("on")])
          False -> ui.badge(badge.Outline, [], [text("off")])
        },
        text(" " <> explanation(decision)),
      ])
    }
  }
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("Check")]),
      ui.card_description([
        text("Whether someone gets the flag, and which rule decides it."),
      ]),
    ]),
    ui.card_content([], [
      ui.stack([], [
        html.form([attribute.method("get"), attribute.action(here)], [
          html.input([
            attribute.type_("hidden"),
            attribute.name("key"),
            attribute.value(flags.key(flag)),
          ]),
          ui.row([], [
            ui.input([
              attribute.name("user"),
              attribute.value(user),
              attribute.placeholder(case config.identity {
                Some(_) -> "user id or email"
                None -> "user id"
              }),
              attribute.attribute("aria-label", "User"),
            ]),
            ui.input([
              attribute.name("org"),
              attribute.value(organization),
              attribute.placeholder("organization id"),
              attribute.attribute("aria-label", "Organization"),
            ]),
            ui.submit_button(button.Secondary, [], [text("Check")]),
          ]),
        ]),
        answer,
      ]),
    ]),
  ])
}

fn explanation(decision: flags.Decision) -> String {
  case decision {
    flags.Default(on:) ->
      "Nothing is stored, so the default applies: "
      <> case on {
        True -> "on."
        False -> "off."
      }
    flags.Killed -> "The kill switch is on."
    flags.Blocked(target) ->
      "Blocked for " <> flags.target_to_string(target) <> "."
    flags.Allowed(target) ->
      "Allowed for " <> flags.target_to_string(target) <> "."
    flags.InRollout(position:, rollout:) ->
      "Their position "
      <> flags.percent_to_string(position)
      <> " is below the rollout of "
      <> flags.percent_to_string(rollout)
      <> "."
    flags.OutsideRollout(position:, rollout:) ->
      "Their position "
      <> flags.percent_to_string(position)
      <> " is outside the rollout of "
      <> flags.percent_to_string(rollout)
      <> "; they get it once the rollout passes it."
    flags.NoPosition(flags.ByUser) ->
      "No user was given and the rollout is by user, so only 100% includes them."
    flags.NoPosition(flags.ByOrganization) ->
      "No organization was given and the rollout is by organization, so only 100% includes them."
  }
}

fn history_table(
  config: Config,
  changes: List(flags.Change),
  with_flag: Bool,
  writable: Bool,
) -> Element(msg) {
  case changes {
    [] -> ui.p([ui.muted("No changes yet.")])
    _ ->
      ui.table([], [
        ui.table_header([], [
          ui.table_row([], [
            ui.table_head([], [text("When")]),
            case with_flag {
              True -> ui.table_head([], [text("Flag")])
              False -> element.none()
            },
            ui.table_head([], [text("Change")]),
            ui.table_head([], [text("By")]),
            ui.table_head([], []),
          ]),
        ]),
        ui.table_body(
          [],
          list.map(changes, fn(change) {
            ui.table_row([], [
              ui.table_cell([], [ui.muted(when(change.at))]),
              case with_flag {
                True ->
                  ui.table_cell([], [
                    case change.flag {
                      Some(key) ->
                        ui.link(flag_path(config, key), [
                          html.code([], [text(key)]),
                        ])
                      None -> ui.muted("groups")
                    },
                  ])
                False -> element.none()
              },
              ui.table_cell([], [text(change.summary)]),
              ui.table_cell([], [text(change.by)]),
              ui.table_cell([], [
                case change.flag, writable {
                  Some(key), True ->
                    html.form(
                      [
                        attribute.method("post"),
                        attribute.action(
                          config.path(config, "/flags/flag/undo?")
                          <> uri.query_to_string([#("key", key)]),
                        ),
                      ],
                      [
                        html.input([
                          attribute.type_("hidden"),
                          attribute.name("change"),
                          attribute.value(int.to_string(change.id)),
                        ]),
                        ui.sized_button(
                          button.Ghost,
                          button.Small,
                          [
                            attribute.type_("submit"),
                            attribute.title(
                              "Put the flag back as it was before this change",
                            ),
                          ],
                          [text("Undo")],
                        ),
                      ],
                    )
                  _, _ -> element.none()
                },
              ]),
            ])
          }),
        ),
      ])
  }
}

fn state_badges(entry: Entry) -> List(Element(msg)) {
  case entry.setting, entry.flag {
    None, Some(flag) -> [
      ui.badge(badge.Outline, [], [
        text(case flags.default(flag) {
          True -> "default on"
          False -> "default off"
        }),
      ]),
    ]
    None, None -> []
    Some(setting), _ ->
      list.flatten([
        case setting.killed {
          True -> [ui.badge(badge.Danger, [], [text("killed")])]
          False -> []
        },
        [
          ui.badge(
            case setting.rollout {
              0 -> badge.Outline
              10_000 -> badge.Primary
              _ -> badge.Secondary
            },
            [],
            [text(flags.percent_to_string(setting.rollout))],
          ),
        ],
        case setting.ramp {
          Some(flags.Ramp(next: Some(_), ..)) -> [
            ui.badge(badge.Secondary, [], [text("ramping")]),
          ]
          Some(flags.Ramp(next: None, ..)) -> [
            ui.badge(badge.Outline, [], [text("ramp paused")]),
          ]
          None -> []
        },
        case setting.bucketing {
          flags.ByOrganization -> [
            ui.badge(badge.Outline, [], [text("by organization")]),
          ]
          flags.ByUser -> []
        },
      ])
  }
}

fn rule_count(setting: Option(Setting)) -> String {
  case setting {
    None -> ""
    Some(setting) ->
      case list.length(setting.allowed), list.length(setting.blocked) {
        0, 0 -> ""
        allowed, 0 -> int.to_string(allowed) <> " allowed"
        0, blocked -> int.to_string(blocked) <> " blocked"
        allowed, blocked ->
          int.to_string(allowed)
          <> " allowed, "
          <> int.to_string(blocked)
          <> " blocked"
      }
  }
}

// -- Groups ------------------------------------------------------------------

fn groups(config: Config, features: Flags, ctx: Context) -> Response(Content) {
  case flags.groups(features) {
    Error(error) -> groups_failure(config, ctx, error)
    Ok(found) ->
      layout.page(
        config,
        ctx,
        current: "/flags/groups",
        heading: "Flag groups",
        live: False,
        content: [
          read_only_notice(features),
          only(
            flags.writable(features),
            ui.card([], [
              ui.card_header([], [
                ui.card_title([text("New group")]),
                ui.card_description([
                  text(
                    "A named set of users and organizations, such as staff or beta testers, that flags can allow or block together.",
                  ),
                ]),
              ]),
              ui.card_content([], [
                html.form(
                  [
                    attribute.method("post"),
                    attribute.action(config.path(config, "/flags/groups")),
                  ],
                  [
                    ui.row([], [
                      ui.input([
                        attribute.name("name"),
                        attribute.placeholder("name, such as beta"),
                        attribute.required(True),
                        attribute.attribute("aria-label", "Name"),
                      ]),
                      ui.input([
                        attribute.name("description"),
                        attribute.placeholder("what it is for"),
                        attribute.attribute("aria-label", "Description"),
                      ]),
                      ui.submit_button(button.Primary, [], [text("Create")]),
                    ]),
                  ],
                ),
              ]),
            ]),
          ),
          case found {
            [] ->
              ui.empty(
                icon: text("👥"),
                title: "No groups yet",
                description: "Create one above, then add users and organizations to it.",
                actions: [],
              )
            _ ->
              ui.table([], [
                ui.table_header([], [
                  ui.table_row([], [
                    ui.table_head([], [text("Group")]),
                    ui.table_head([], [text("Members")]),
                    ui.table_head([], [text("Description")]),
                  ]),
                ]),
                ui.table_body(
                  [],
                  list.map(found, fn(group) {
                    ui.table_row([], [
                      ui.table_cell([], [
                        ui.link(group_path(config, group.name), [
                          text(group.name),
                        ]),
                      ]),
                      ui.table_cell([], [
                        text(int.to_string(list.length(group.members))),
                      ]),
                      ui.table_cell([], [text(group.description)]),
                    ])
                  }),
                ),
              ])
          },
        ],
      )
  }
}

fn group(config: Config, features: Flags, ctx: Context) -> Response(Content) {
  use name <- with_group(config, ctx)
  let writable = flags.writable(features)
  let found = {
    use all <- result.try(flags.groups(features))
    list.find(all, fn(group) { group.name == name })
    |> result.replace_error(service.NotFound("no group named " <> name))
  }
  case found {
    Error(error) -> groups_failure(config, ctx, error)
    Ok(found) -> {
      let action = fn(rest) {
        config.path(config, "/flags/groups/group/" <> rest <> "?")
        <> uri.query_to_string([#("name", name)])
      }
      layout.page(
        config,
        ctx,
        current: "/flags/groups",
        heading: name,
        live: False,
        content: [
          ui.p([
            ui.link(config.path(config, "/flags/groups"), [text("All groups")]),
            text(" · " <> found.description),
          ]),
          ui.card([], [
            ui.card_header([], [ui.card_title([text("Members")])]),
            ui.card_content([], [
              ui.stack([], [
                case found.members {
                  [] -> ui.p([ui.muted("Nobody is in this group.")])
                  members ->
                    ui.table([], [
                      ui.table_body(
                        [],
                        list.map(members, fn(member) {
                          ui.table_row([], [
                            ui.table_cell([], [target_view(config, member)]),
                            ui.table_cell([], [
                              only(
                                writable,
                                html.form(
                                  [
                                    attribute.method("post"),
                                    attribute.action(action("remove")),
                                  ],
                                  [
                                    html.input([
                                      attribute.type_("hidden"),
                                      attribute.name("member"),
                                      attribute.value(flags.target_to_string(
                                        member,
                                      )),
                                    ]),
                                    ui.sized_button(
                                      button.Ghost,
                                      button.Small,
                                      [attribute.type_("submit")],
                                      [text("Remove")],
                                    ),
                                  ],
                                ),
                              ),
                            ]),
                          ])
                        }),
                      ),
                    ])
                },
                only(
                  writable,
                  html.form(
                    [attribute.method("post"), attribute.action(action("add"))],
                    [
                      ui.row(
                        [],
                        list.append(target_inputs(config, "member"), [
                          ui.submit_button(button.Secondary, [], [text("Add")]),
                        ]),
                      ),
                    ],
                  ),
                ),
              ]),
            ]),
            only(
              writable,
              ui.card_footer([], [
                html.form(
                  [attribute.method("post"), attribute.action(action("delete"))],
                  [ui.submit_button(button.Danger, [], [text("Delete group")])],
                ),
              ]),
            ),
          ]),
        ],
      )
    }
  }
}

// -- Pieces ------------------------------------------------------------------

/// `element` when `shown`, nothing otherwise.
fn only(shown: Bool, element: Element(msg)) -> Element(msg) {
  case shown {
    True -> element
    False -> element.none()
  }
}

/// A kind and an id. Group members cannot be groups; `add_member` refuses
/// them, so the choice is offered everywhere and explained there.
fn target_inputs(config: Config, id: String) -> List(Element(msg)) {
  [
    ui.native_select(
      [attribute.name("kind"), attribute.attribute("aria-label", "Kind")],
      [
        html.option([attribute.value("user")], "User"),
        html.option([attribute.value("org")], "Organization"),
        ..case id {
          "member" -> []
          _ -> [html.option([attribute.value("group")], "Group")]
        }
      ],
    ),
    ui.input([
      attribute.id(id <> "-target"),
      attribute.name("id"),
      attribute.required(True),
      attribute.placeholder(case config.identity {
        Some(_) -> "id, user email, or group name"
        None -> "id or group name"
      }),
      attribute.attribute("aria-label", "Id"),
    ]),
  ]
}

/// The target a form names. With auth registered, a user can be given by
/// email.
fn read_target(config: Config, form: Form) -> service.Result(Target) {
  let id = string.trim(form.value(form, "id"))
  case form.value(form, "kind"), config.identity {
    "user", Some(identity) ->
      case string.contains(id, "@") {
        False -> Ok(flags.User(id))
        True -> {
          use everyone <- result.try(users.list(identity))
          list.find(everyone, fn(user) { user.email == id })
          |> result.map(fn(user) { flags.User(user.id) })
          |> result.replace_error(service.NotFound("no user with email " <> id))
        }
      }
    "user", None -> Ok(flags.User(id))
    "org", _ -> Ok(flags.Organization(id))
    "group", _ -> Ok(flags.Group(id))
    _, _ -> Error(service.Invalid("choose a user, organization or group"))
  }
}

/// A target, with the user's email when auth can say.
fn target_view(config: Config, target: Target) -> Element(msg) {
  let label = flags.target_to_string(target)
  case target, config.identity {
    flags.User(id), Some(identity) ->
      case users.get(identity, id) {
        Ok(user) ->
          html.span([], [
            ui.link(config.path(config, "/users/" <> id), [text(user.email)]),
            ui.muted(" " <> label),
          ])
        Error(_) -> html.code([], [text(label)])
      }
    flags.Group(name), _ ->
      ui.link(group_path(config, name), [html.code([], [text(label)])])
    _, _ -> html.code([], [text(label)])
  }
}

fn when(seconds: Int) -> String {
  timestamp.from_unix_seconds(seconds)
  |> timestamp.to_rfc3339(calendar.utc_offset)
}

/// Run a change to the flag the query names, then show the flag again.
fn act(
  config: Config,
  ctx: Context,
  run: fn(String, Form) -> service.Result(Nil),
) -> Response(Content) {
  use key <- with_key(config, ctx)
  use form <- form.read(ctx)
  case run(key, form) {
    Ok(Nil) -> layout.redirect(flag_path(config, key))
    Error(error) -> failure(config, ctx, key, error)
  }
}

fn with_key(
  config: Config,
  ctx: Context,
  next: fn(String) -> Response(Content),
) -> Response(Content) {
  case
    request.get_query(ctx.request)
    |> result.unwrap([])
    |> list.key_find("key")
  {
    Ok(key) if key != "" -> next(key)
    _ -> failure(config, ctx, "Flags", service.NotFound("flag"))
  }
}

fn with_group(
  config: Config,
  ctx: Context,
  next: fn(String) -> Response(Content),
) -> Response(Content) {
  case
    request.get_query(ctx.request)
    |> result.unwrap([])
    |> list.key_find("name")
  {
    Ok(name) if name != "" -> next(name)
    _ -> groups_failure(config, ctx, service.NotFound("group"))
  }
}

pub fn flag_path(config: Config, key: String) -> String {
  config.path(config, "/flags/flag?") <> uri.query_to_string([#("key", key)])
}

fn group_path(config: Config, name: String) -> String {
  config.path(config, "/flags/groups/group?")
  <> uri.query_to_string([#("name", name)])
}

fn failure(
  config: Config,
  ctx: Context,
  heading: String,
  error: service.Error,
) -> Response(Content) {
  layout.failure(
    config,
    ctx,
    current: "/flags",
    heading:,
    error:,
    back: config.path(config, "/flags"),
  )
}

fn groups_failure(
  config: Config,
  ctx: Context,
  error: service.Error,
) -> Response(Content) {
  layout.failure(
    config,
    ctx,
    current: "/flags/groups",
    heading: "Flag groups",
    error:,
    back: config.path(config, "/flags/groups"),
  )
}
