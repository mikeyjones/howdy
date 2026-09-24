# Gallery example

howdy_ui components assembled into whole screens.

```sh
gleam run
```

Open <http://localhost:8791>.

- **Dashboard** (`/`): a collapsible sidebar that remembers its state in a
  cookie, stat cards, a bar and an area chart, and a live orders table you
  can sort, filter by status and due date, select, mark paid and page
  through. Marking orders paid shows a toast.
- **Components** (`/components`): a line chart, a data table sorted with
  plain links, pagination, a calendar inside an ordinary form, a command
  menu, and a toast that stays until it is closed.
- **Sign in** and **Sign up** (`/sign-in`, `/sign-up`): centred forms. Sign
  up validates on the server and shows each problem beside its field.

Press ⌘K or Ctrl+K anywhere in the app to search its pages.

`src/howdy_gallery/blocks.gleam` holds the screens as functions: the
application shell, stat cards and the authentication cards. They are plain
compositions of howdy_ui components, meant to be copied into your app and
changed. `src/howdy_gallery/orders.gleam` is the live view.
