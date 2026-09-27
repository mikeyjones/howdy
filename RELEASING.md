# Releasing Howdy

Every package in this repository is released together, as one Howdy
version. A release is a git tag, `v<version>`, and the website's docs and
component pages for that release are built from the tag.

## Version numbers

- The Howdy version is the version of the core `howdy` package, and follows
  semantic versioning: a patch fixes things, a minor adds things, a major
  breaks things.
- Each other package keeps its own version, and changes it when it changes.
  `releases/releases.json` records which versions of every package make up
  each Howdy release, so users can see what goes together.
- Apps depend on a tag, never the `v2` branch:

  ```toml
  howdy = { git = "https://github.com/mikeyjones/howdy.git", ref = "v2.1.0" }
  howdy_ui = { git = "https://github.com/mikeyjones/howdy.git", ref = "v2.1.0", path = "ui" }
  ```

## Making a release

1. Bump `version` in the `gleam.toml` of every package that changed, and in
   the root `gleam.toml` to the new Howdy version.
2. Commit, so the working tree is clean.
3. Run:

   ```sh
   scripts/release.sh 2.1.0
   ```

   It checks the versions, exports every package's public API, records the
   release in `releases/`, points the install instructions in `docs/` at
   the new tag, then commits and tags `v2.1.0`. Pass `--no-tag` to stop
   before committing and review the changes first.
4. Push the branch and the tag:

   ```sh
   git push origin HEAD v2.1.0
   ```

5. In the website, point the dependencies at the new tag and take a
   snapshot of its docs and components; see the website's README.

## What is recorded

`releases/releases.json` lists every release, its date and its package
versions. The website shows it as a compatibility table.

`releases/since.json` records, for every public module, function, constant
and type in every package, the Howdy release that first shipped it, and the
ones that deprecated or removed it. It is worked out from
`gleam export package-interface`, so it cannot drift from the code:

- Something new in this release is marked as added in it.
- Something marked `@deprecated` for the first time is marked as deprecated
  in it.
- Something that has gone is kept, and marked as removed in it.

The website shows these on the component pages. Never edit either file by
hand; run the release again instead.

## Docs

User docs live in `docs/`, next to the code, and are released with it. A
change that adds or changes a feature should change its docs in the same
pull request. See `docs/README.md`.
