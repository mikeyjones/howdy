//// The auth pages: users and groups, and signing in as a user.

import ewe
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/layout
import howdy/admin/internal/roles
import howdy/auth.{type Auth}
import howdy/auth/field
import howdy/auth/group.{type Group, Single}
import howdy/auth/groups
import howdy/auth/routes
import howdy/auth/user.{type User}
import howdy/auth/users
import howdy/authorization.{type Authorization}
import howdy/controller.{type Context, type Controller}
import howdy/form
import howdy/service
import howdy/ui
import howdy/ui/badge
import howdy/ui/button
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

/// Who the audit trail says did it.
const actor = user.SystemFrom("howdy_admin")

pub fn controller(config: Config, identity: Auth) -> Controller {
  controller.new(config.prefix)
  |> controller.get("/users", fn(ctx) { user_index(config, identity, ctx) })
  |> controller.post("/users", fn(ctx) { user_create(config, identity, ctx) })
  |> controller.get("/users/:id", fn(ctx) { user_show(config, identity, ctx) })
  |> controller.post("/users/:id/suspend", fn(ctx) {
    user_action(config, identity, ctx, fn(id) {
      auth.suspend(identity, id, by: actor)
    })
  })
  |> controller.post("/users/:id/resume", fn(ctx) {
    user_action(config, identity, ctx, fn(id) {
      auth.resume(identity, id, by: actor)
    })
  })
  |> controller.post("/users/:id/revoke", fn(ctx) {
    user_action(config, identity, ctx, fn(id) {
      auth.revoke_sessions(identity, id, by: actor)
    })
  })
  |> controller.post("/users/:id/move", fn(ctx) {
    user_move(config, identity, ctx)
  })
  |> controller.post("/users/:id/impersonate", fn(ctx) {
    impersonate(config, identity, ctx)
  })
  |> controller.post("/users/:id/delete", fn(ctx) {
    user_delete(config, identity, ctx)
  })
  |> controller.post("/users/:id/sessions/revoke", fn(ctx) {
    session_revoke(config, identity, ctx)
  })
  |> controller.post("/users/:id/roles/assign", fn(ctx) {
    role_change(config, ctx, fn(access, id, scope, role) {
      authorization.assign(access, id, role, scope, by: actor)
    })
  })
  |> controller.post("/users/:id/roles/revoke", fn(ctx) {
    role_change(config, ctx, fn(access, id, scope, role) {
      authorization.revoke(access, id, role, scope, by: actor)
    })
  })
  |> controller.get("/groups", fn(ctx) { group_index(config, identity, ctx) })
  |> controller.post("/groups", fn(ctx) { group_create(config, identity, ctx) })
  |> controller.get("/groups/:id", fn(ctx) { group_show(config, identity, ctx) })
  |> controller.post("/groups/:id/rename", fn(ctx) {
    group_rename(config, identity, ctx)
  })
  |> controller.post("/groups/:id/delete", fn(ctx) {
    group_delete(config, identity, ctx)
  })
}

// -- Users -------------------------------------------------------------------

fn user_index(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(ewe.Body) {
  let listed = {
    use listed <- result.try(users.list(identity))
    use groups <- result.try(groups.list(identity))
    use listed <- result.try(
      list.try_map(listed, fn(user) {
        use suspended <- result.try(users.suspended(identity, user.id))
        Ok(#(user, suspended))
      }),
    )
    Ok(#(listed, groups))
  }
  case listed {
    Error(error) -> failure(config, ctx, "/users", "Users", error)
    Ok(#(listed, groups)) ->
      layout.page(
        config,
        ctx,
        current: "/users",
        heading: "Users",
        live: False,
        content: [
          ui.card([], [
            ui.card_header([], [ui.card_title([text("New user")])]),
            ui.card_content([], [
              html.form(
                [
                  attribute.method("post"),
                  attribute.action(config.path(config, "/users")),
                ],
                [
                  ui.row([], [
                    ui.input([
                      attribute.name("email"),
                      attribute.type_("email"),
                      attribute.placeholder("email address"),
                      attribute.required(True),
                    ]),
                    case auth.group_mode(identity) {
                      Single -> element.none()
                      _ -> group_select(groups, selected: group.default_id)
                    },
                    ui.submit_button(button.Primary, [], [text("Create")]),
                  ]),
                ],
              ),
              ui.field_description([], [
                text(
                  "The user is provisioned without a credential. Sign in as them from their page, or let them set a password or passkey.",
                ),
              ]),
            ]),
          ]),
          case listed {
            [] ->
              ui.empty(
                icon: text("☺"),
                title: "No users yet",
                description: "Create one above, or register through your application.",
                actions: [],
              )
            _ ->
              ui.table([], [
                ui.table_header([], [
                  ui.table_row([], [
                    ui.table_head([], [text("Email")]),
                    ui.table_head([], [text("Group")]),
                    ui.table_head([], [text("Created")]),
                    ui.table_head([], [text("Status")]),
                  ]),
                ]),
                ui.table_body(
                  [],
                  list.map(listed, fn(entry) {
                    let #(user, suspended) = entry
                    ui.table_row([], [
                      ui.table_cell([], [
                        ui.link(user_path(config, user.id), [text(user.email)]),
                      ]),
                      ui.table_cell([], [
                        ui.link(group_path(config, user.group_id), [
                          text(user.group_id),
                        ]),
                      ]),
                      ui.table_cell([], [text(when(user.created_at))]),
                      ui.table_cell([], [status(suspended)]),
                    ])
                  }),
                ),
              ])
          },
        ],
      )
  }
}

fn user_create(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(ewe.Body) {
  use form <- form.read(ctx)
  let email = form.value(form, "email")
  let identity = case form.get(form, "group") {
    Ok(id) if id != "" -> auth.in_group(identity, id)
    _ -> identity
  }
  case auth.provision(identity, email, by: actor) {
    Ok(user) -> layout.redirect(user_path(config, user.id))
    Error(error) -> failure(config, ctx, "/users", "Users", error)
  }
}

fn user_show(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(ewe.Body) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  let found = {
    use user <- result.try(users.get(identity, id))
    use suspended <- result.try(users.suspended(identity, id))
    use fields <- result.try(users.fields(identity, id))
    use groups <- result.try(groups.list(identity))
    use held <- result.try(case config.authorization {
      Some(access) -> {
        use assignments <- result.try(authorization.assignments(access, id))
        use roles <- result.try(authorization.roles(access))
        Ok(Some(#(assignments, roles)))
      }
      None -> Ok(None)
    })
    use sessions <- result.try(auth.sessions_of(identity, id))
    Ok(#(user, suspended, field.to_list(fields), groups, held, sessions))
  }
  case found {
    Error(error) -> failure(config, ctx, "/users", "User", error)
    Ok(#(user, suspended, fields, groups, held, sessions)) -> {
      let action = fn(name, variant, label) {
        html.form(
          [
            attribute.method("post"),
            attribute.action(user_path(config, id) <> name),
          ],
          [ui.submit_button(variant, [], [text(label)])],
        )
      }
      layout.page(
        config,
        ctx,
        current: "/users",
        heading: user.email,
        live: False,
        content: [
          ui.p([ui.link(config.path(config, "/users"), [text("All users")])]),
          ui.card([], [
            ui.card_header([], [
              ui.card_title([text("Account")]),
              ui.card_action([], [status(suspended)]),
            ]),
            ui.card_content([], [
              facts([
                #("Id", user.id),
                #("Email", user.email),
                #("Group", user.group_id),
                #("Created", when(user.created_at)),
                #("Updated", when(user.updated_at)),
              ]),
            ]),
            ui.card_footer([], [
              ui.row([], [
                case suspended {
                  True -> element.none()
                  False ->
                    action(
                      "/impersonate",
                      button.Primary,
                      "Sign in as this user",
                    )
                },
                case suspended {
                  True -> action("/resume", button.Secondary, "Resume")
                  False -> action("/suspend", button.Danger, "Suspend")
                },
                action("/revoke", button.Outline, "Sign out everywhere"),
              ]),
            ]),
          ]),
          case fields {
            [] -> element.none()
            _ ->
              ui.card([], [
                ui.card_header([], [ui.card_title([text("Fields")])]),
                ui.card_content([], [facts(fields)]),
              ])
          },
          sessions_card(config, id, sessions),
          case held {
            None -> element.none()
            Some(#(assignments, roles)) ->
              roles_card(config, id, assignments, roles)
          },
          case auth.account_deletion_enabled(identity) {
            True -> delete_card(config, user)
            False ->
              ui.p([
                ui.muted(
                  "Account deletion is off: enable it with auth.with_account_deletion, whose callback cleans up your own tables.",
                ),
              ])
          },
          case auth.group_mode(identity) {
            Single -> element.none()
            _ ->
              ui.card([], [
                ui.card_header([], [
                  ui.card_title([text("Move to another group")]),
                ]),
                ui.card_content([], [
                  html.form(
                    [
                      attribute.method("post"),
                      attribute.action(user_path(config, id) <> "/move"),
                    ],
                    [
                      ui.row([], [
                        group_select(groups, selected: user.group_id),
                        ui.submit_button(button.Secondary, [], [text("Move")]),
                      ]),
                    ],
                  ),
                ]),
              ])
          },
        ],
      )
    }
  }
}

fn user_action(
  config: Config,
  identity: Auth,
  ctx: Context,
  run: fn(String) -> service.Result(Nil),
) -> Response(ewe.Body) {
  let _ = identity
  let id = result.unwrap(controller.param(ctx, "id"), "")
  case run(id) {
    Ok(Nil) -> layout.redirect(user_path(config, id))
    Error(error) -> failure(config, ctx, "/users", "User", error)
  }
}

fn user_move(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(ewe.Body) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  use form <- form.read(ctx)
  case groups.move(identity, id, to: form.value(form, "group"), by: actor) {
    Ok(_) -> layout.redirect(user_path(config, id))
    Error(error) -> failure(config, ctx, "/users", "User", error)
  }
}

/// Issue a session for the user and make it the browser's, then go to the
/// application's root.
fn impersonate(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(ewe.Body) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  case auth.impersonate(identity, id, by: actor) {
    Ok(session) ->
      routes.signed_in(identity, ctx, layout.redirect("/"), session)
    Error(error) -> failure(config, ctx, "/users", "User", error)
  }
}

/// Deletion behind a confirmation: the email address must be typed back.
fn delete_card(config: Config, user: User) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("Delete account")]),
      ui.card_description([
        text(
          "Removes the account, its credentials and sessions, and whatever your deletion callback cleans up. There is no undo.",
        ),
      ]),
    ]),
    ui.card_content([], [
      html.form(
        [
          attribute.method("post"),
          attribute.action(user_path(config, user.id) <> "/delete"),
        ],
        [
          ui.row([], [
            ui.input([
              attribute.name("confirm"),
              attribute.type_("email"),
              attribute.placeholder("type " <> user.email <> " to confirm"),
              attribute.required(True),
            ]),
            ui.submit_button(button.Danger, [], [text("Delete account")]),
          ]),
        ],
      ),
    ]),
  ])
}

fn user_delete(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(ewe.Body) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  use form <- form.read(ctx)
  let deleted = {
    use user <- result.try(users.get(identity, id))
    use _ <- result.try(
      case
        string.lowercase(string.trim(form.value(form, "confirm"))) == user.email
      {
        True -> Ok(Nil)
        False ->
          Error(service.Invalid("type the account's email address to confirm"))
      },
    )
    auth.delete_user(identity, id, by: actor)
  }
  case deleted {
    Ok(Nil) -> layout.redirect(config.path(config, "/users"))
    Error(error) -> failure(config, ctx, "/users", "User", error)
  }
}

/// The user's live sessions, newest first, each with a revoke button.
fn sessions_card(
  config: Config,
  id: String,
  sessions: List(auth.SessionInfo),
) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("Sessions")]),
      ui.card_description([
        text(describe(list.length(sessions), "live session")),
      ]),
    ]),
    ui.card_content([], [
      case sessions {
        [] -> ui.p([ui.muted("Not signed in anywhere.")])
        _ ->
          ui.table([], [
            ui.table_header([], [
              ui.table_row([], [
                ui.table_head([], [text("Method")]),
                ui.table_head([], [text("Signed in")]),
                ui.table_head([], [text("Last seen")]),
                ui.table_head([], [text("Expires")]),
                ui.table_head([], [text("Client")]),
                ui.table_head([], [text("")]),
              ]),
            ]),
            ui.table_body(
              [],
              list.map(sessions, fn(session) {
                ui.table_row([], [
                  ui.table_cell([], [method_badge(session.method)]),
                  ui.table_cell([], [text(at(session.created_at))]),
                  ui.table_cell([], [text(at(session.last_seen_at))]),
                  ui.table_cell([], [text(at(session.expires_at))]),
                  ui.table_cell([], [
                    case session.client {
                      "" -> ui.muted("unknown")
                      client -> text(client)
                    },
                  ]),
                  ui.table_cell([], [
                    html.form(
                      [
                        attribute.method("post"),
                        attribute.action(
                          user_path(config, id) <> "/sessions/revoke",
                        ),
                      ],
                      [
                        html.input([
                          attribute.type_("hidden"),
                          attribute.name("session"),
                          attribute.value(session.id),
                        ]),
                        ui.sized_button(
                          button.Ghost,
                          button.Small,
                          [attribute.type_("submit")],
                          [text("Revoke")],
                        ),
                      ],
                    ),
                  ]),
                ])
              }),
            ),
          ])
      },
    ]),
  ])
}

fn method_badge(method: auth.Method) -> Element(msg) {
  case method {
    auth.EmailToken -> ui.badge(badge.Outline, [], [text("email token")])
    auth.Password -> ui.badge(badge.Outline, [], [text("password")])
    auth.Passkey -> ui.badge(badge.Outline, [], [text("passkey")])
    auth.Provider(id) -> ui.badge(badge.Outline, [], [text("provider " <> id)])
    auth.Impersonation -> ui.badge(badge.Primary, [], [text("impersonation")])
  }
}

/// Unix seconds as a timestamp.
fn at(seconds: Int) -> String {
  when(timestamp.from_unix_seconds(seconds))
}

fn session_revoke(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(ewe.Body) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  use form <- form.read(ctx)
  case
    auth.revoke_session_of(identity, id, form.value(form, "session"), by: actor)
  {
    Ok(Nil) -> layout.redirect(user_path(config, id))
    Error(error) -> failure(config, ctx, "/users", "User", error)
  }
}

/// The roles a user holds, each with a revoke button, and a form to assign
/// one they do not.
fn roles_card(
  config: Config,
  id: String,
  assignments: List(#(authorization.Scope, String)),
  roles: List(authorization.Role),
) -> Element(msg) {
  let here = user_path(config, id) <> "/roles"
  let available =
    list.filter(roles, fn(role) {
      !list.contains(assignments, #(role.scope, role.name))
    })
  ui.card([], [
    ui.card_header([], [ui.card_title([text("Roles")])]),
    ui.card_content([], [
      case assignments {
        [] -> ui.p([ui.muted("No roles.")])
        _ ->
          ui.table([], [
            ui.table_body(
              [],
              list.map(assignments, fn(assignment) {
                let #(scope, role) = assignment
                ui.table_row([], [
                  ui.table_cell([], [
                    ui.link(roles.role_path(config, scope, role), [text(role)]),
                  ]),
                  ui.table_cell([], [roles.scope_badge(scope)]),
                  ui.table_cell([], [
                    html.form(
                      [
                        attribute.method("post"),
                        attribute.action(here <> "/revoke"),
                      ],
                      [
                        html.input([
                          attribute.type_("hidden"),
                          attribute.name("role"),
                          attribute.value(role_value(scope, role)),
                        ]),
                        ui.sized_button(
                          button.Ghost,
                          button.Small,
                          [attribute.type_("submit")],
                          [text("Revoke")],
                        ),
                      ],
                    ),
                  ]),
                ])
              }),
            ),
          ])
      },
      case available {
        [] -> element.none()
        _ ->
          html.form(
            [attribute.method("post"), attribute.action(here <> "/assign")],
            [
              ui.row([], [
                ui.native_select(
                  [attribute.name("role")],
                  list.map(available, fn(role) {
                    html.option(
                      [attribute.value(role_value(role.scope, role.name))],
                      role.name
                        <> " ("
                        <> authorization.scope_to_string(role.scope)
                        <> ")",
                    )
                  }),
                ),
                ui.submit_button(button.Secondary, [], [text("Assign")]),
              ]),
            ],
          )
      },
    ]),
  ])
}

/// A role and its scope in one form value. Names cannot contain a tab.
fn role_value(scope: authorization.Scope, role: String) -> String {
  authorization.scope_to_string(scope) <> "\t" <> role
}

fn role_change(
  config: Config,
  ctx: Context,
  run: fn(Authorization, String, authorization.Scope, String) ->
    service.Result(Nil),
) -> Response(ewe.Body) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  use form <- form.read(ctx)
  let parsed = {
    use access <- result.try(option.to_result(
      config.authorization,
      service.NotFound("authorization"),
    ))
    use #(scope, role) <- result.try(
      string.split_once(form.value(form, "role"), "\t")
      |> result.replace_error(service.Invalid("choose a role")),
    )
    use scope <- result.try(
      authorization.scope_from_string(scope)
      |> result.replace_error(service.Invalid("unknown scope")),
    )
    run(access, id, scope, role)
  }
  case parsed {
    Ok(Nil) -> layout.redirect(user_path(config, id))
    Error(error) -> failure(config, ctx, "/users", "User", error)
  }
}

// -- Groups ------------------------------------------------------------------

fn group_index(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(ewe.Body) {
  case groups.list(identity) {
    Error(error) -> failure(config, ctx, "/groups", "Groups", error)
    Ok(listed) ->
      layout.page(
        config,
        ctx,
        current: "/groups",
        heading: "Groups",
        live: False,
        content: [
          ui.p([
            ui.muted(
              "Group mode: " <> group.mode_name(auth.group_mode(identity)),
            ),
          ]),
          case auth.group_mode(identity) {
            Single ->
              ui.p([
                text(
                  "Every user is in the default group. Choose another mode with auth.with_groups to create more.",
                ),
              ])
            _ ->
              ui.card([], [
                ui.card_header([], [ui.card_title([text("New group")])]),
                ui.card_content([], [
                  html.form(
                    [
                      attribute.method("post"),
                      attribute.action(config.path(config, "/groups")),
                    ],
                    [
                      ui.row([], [
                        ui.input([
                          attribute.name("name"),
                          attribute.placeholder("name"),
                          attribute.required(True),
                        ]),
                        ui.input([
                          attribute.name("id"),
                          attribute.placeholder("id (optional)"),
                        ]),
                        ui.submit_button(button.Primary, [], [text("Create")]),
                      ]),
                    ],
                  ),
                ]),
              ])
          },
          ui.table([], [
            ui.table_header([], [
              ui.table_row([], [
                ui.table_head([], [text("Name")]),
                ui.table_head([], [text("Id")]),
                ui.table_head([], [text("Created")]),
              ]),
            ]),
            ui.table_body(
              [],
              list.map(listed, fn(group) {
                ui.table_row([], [
                  ui.table_cell([], [
                    ui.link(group_path(config, group.id), [text(group.name)]),
                  ]),
                  ui.table_cell([], [text(group.id)]),
                  ui.table_cell([], [text(when(group.created_at))]),
                ])
              }),
            ),
          ]),
        ],
      )
  }
}

fn group_create(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(ewe.Body) {
  use form <- form.read(ctx)
  let name = form.value(form, "name")
  let created = case form.value(form, "id") {
    "" -> groups.create(identity, name:, by: actor)
    id -> groups.create_with_id(identity, id:, name:, by: actor)
  }
  case created {
    Ok(group) -> layout.redirect(group_path(config, group.id))
    Error(error) -> failure(config, ctx, "/groups", "Groups", error)
  }
}

fn group_show(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(ewe.Body) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  let found = {
    use group <- result.try(groups.get(identity, id))
    use members <- result.try(groups.members(identity, id))
    Ok(#(group, members))
  }
  case found {
    Error(error) -> failure(config, ctx, "/groups", "Group", error)
    Ok(#(group, members)) ->
      layout.page(
        config,
        ctx,
        current: "/groups",
        heading: group.name,
        live: False,
        content: [
          ui.p([ui.link(config.path(config, "/groups"), [text("All groups")])]),
          ui.card([], [
            ui.card_header([], [ui.card_title([text("Group")])]),
            ui.card_content([], [
              facts([
                #("Id", group.id),
                #("Created", when(group.created_at)),
                #("Updated", when(group.updated_at)),
              ]),
              html.form(
                [
                  attribute.method("post"),
                  attribute.action(group_path(config, id) <> "/rename"),
                ],
                [
                  ui.row([], [
                    ui.input([
                      attribute.name("name"),
                      attribute.value(group.name),
                      attribute.required(True),
                    ]),
                    ui.submit_button(button.Secondary, [], [text("Rename")]),
                  ]),
                ],
              ),
            ]),
            ui.card_footer([], [
              html.form(
                [
                  attribute.method("post"),
                  attribute.action(group_path(config, id) <> "/delete"),
                ],
                [ui.submit_button(button.Danger, [], [text("Delete group")])],
              ),
            ]),
          ]),
          ui.h2("Members"),
          members_table(config, members),
        ],
      )
  }
}

fn group_rename(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(ewe.Body) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  use form <- form.read(ctx)
  case groups.rename(identity, id, to: form.value(form, "name"), by: actor) {
    Ok(_) -> layout.redirect(group_path(config, id))
    Error(error) -> failure(config, ctx, "/groups", "Group", error)
  }
}

fn group_delete(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(ewe.Body) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  case groups.delete(identity, id, by: actor) {
    Ok(Nil) -> layout.redirect(config.path(config, "/groups"))
    Error(error) -> failure(config, ctx, "/groups", "Group", error)
  }
}

// -- Pieces ------------------------------------------------------------------

fn members_table(config: Config, members: List(User)) -> Element(msg) {
  case members {
    [] -> ui.p([ui.muted("No members.")])
    _ ->
      ui.table([], [
        ui.table_header([], [
          ui.table_row([], [
            ui.table_head([], [text("Email")]),
            ui.table_head([], [text("Created")]),
          ]),
        ]),
        ui.table_body(
          [],
          list.map(members, fn(user) {
            ui.table_row([], [
              ui.table_cell([], [
                ui.link(user_path(config, user.id), [text(user.email)]),
              ]),
              ui.table_cell([], [text(when(user.created_at))]),
            ])
          }),
        ),
      ])
  }
}

fn group_select(
  groups: List(Group),
  selected selected: String,
) -> Element(msg) {
  ui.native_select(
    [attribute.name("group")],
    list.map(groups, fn(group) {
      html.option(
        [attribute.value(group.id), attribute.selected(group.id == selected)],
        group.name <> " (" <> group.id <> ")",
      )
    }),
  )
}

fn facts(pairs: List(#(String, String))) -> Element(msg) {
  ui.table([], [
    ui.table_body(
      [],
      list.map(pairs, fn(pair) {
        ui.table_row([], [
          ui.table_head([], [text(pair.0)]),
          ui.table_cell([], [text(pair.1)]),
        ])
      }),
    ),
  ])
}

fn status(suspended: Bool) -> Element(msg) {
  case suspended {
    True -> ui.badge(badge.Danger, [], [text("suspended")])
    False -> ui.badge(badge.Outline, [], [text("active")])
  }
}

fn when(time: Timestamp) -> String {
  timestamp.to_rfc3339(time, calendar.utc_offset)
}

fn user_path(config: Config, id: String) -> String {
  config.path(config, "/users/" <> id)
}

fn group_path(config: Config, id: String) -> String {
  config.path(config, "/groups/" <> id)
}

fn failure(
  config: Config,
  ctx: Context,
  current: String,
  heading: String,
  error: service.Error,
) -> Response(ewe.Body) {
  layout.failure(
    config,
    ctx,
    current:,
    heading:,
    error:,
    back: config.path(config, current),
  )
}

/// Unused for now; keeps the count helper handy for the overview.
pub fn count_users(identity: Auth) -> service.Result(Int) {
  users.list(identity) |> result.map(list.length)
}

pub fn count_groups(identity: Auth) -> service.Result(Int) {
  groups.list(identity) |> result.map(list.length)
}

pub fn describe(n: Int, noun: String) -> String {
  int.to_string(n)
  <> " "
  <> case n {
    1 -> noun
    _ -> noun <> "s"
  }
}
