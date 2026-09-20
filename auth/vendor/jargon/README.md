# Temporary Jargon 1.1.0 correction

Source: the `jargon` 1.1.0 Hex package, used by Argus 2.0.0.
Upstream: <https://github.com/Pevensie/jargon>.

The upstream `c_src/jargon.c` defines `ARGON2_VERSION` as decimal `13`.
The reference implementation requires `ARGON2_VERSION_NUMBER` (`0x13`, decimal
19). The version participates in the hash computation, so changing an encoded
hash's label cannot repair it. This copy corrects that constant and updates the Makefile to select the
upstream SIMD implementation on x86-64 (the portable reference elsewhere). No custom cryptographic algorithm is introduced.

The whole change is recorded in [PATCH.diff](PATCH.diff). `./verify.sh`
downloads the published Hex tarball, checks its SHA-256
(`963fcd2e851f5fcf3821638c088ea1ef07365187319b9145a1d12dd3980162ca`), applies
the patch and fails if any runtime source differs from this directory. CI runs
it on every build, so an unreviewed edit to the vendored C cannot slip in.

`gleam.toml` packages the Erlang module as a local Gleam dependency so the
transitive dependency from Argus resolves to this corrected copy. The upstream
rebar packaging files are not used. Build its native library explicitly:

```sh
make -C auth/vendor/jargon/c_src  # from the repository root
```

On x86-64 the build uses upstream `opt.c` with baseline SSE2, without
`-march=native`. Other architectures default to `ref.c`. Cross-compilers should
select their target explicitly with `ARGON2_IMPL=ref` or `ARGON2_IMPL=opt`.
For a portable build, run `make -C auth/vendor/jargon/c_src ARGON2_IMPL=ref`.
Both implementations run the same known-answer tests in CI. The Makefile changes
are included in `PATCH.diff` and checked by `verify.sh` alongside the version fix.

Requires make, a C compiler and Erlang development headers. Build on the target
platform before `gleam build`, `gleam test`, or exporting a release. Generated
objects and `priv/jargon.so` are ignored. Rebuild after changing Erlang/platform;
run `make -C auth/vendor/jargon/c_src clean` first. If switching an existing
build from the Hex dependency, run `gleam clean` in the consuming project once.

Howdy refuses to enable passwords if Argus generates a nonstandard version.
The auth suite checks a known-answer vector generated independently with system
libargon2, including raw hash bytes and standard encoded-hash verification.

The version problem is tracked in [Pevensie/jargon#9](https://github.com/Pevensie/jargon/issues/9). Until
a corrected release is published, Howdy uses this copy. Remove the override
when an upstream release passes the known-answer test, then delete this
directory, the `jargon` path dependency and the CI steps that build and verify
it. Hashes produced by an uncorrected build are not standard Argon2id v19 and
will not verify against a corrected one; Howdy never stored any, because
`with_passwords` refuses a nonstandard encoder. This path dependency is for the
repository prototype; publishing `howdy_auth` to Hex requires the corrected
published dependency first.

The Jargon wrapper is MIT licensed (see LICENSE). The bundled Argon2 reference
sources retain their copyright notices and are used under Apache-2.0 (see
argon2/LICENSE). Full provenance is pinned by auth/manifest.toml for Argus;
the copied Jargon source is versioned in this repository.
