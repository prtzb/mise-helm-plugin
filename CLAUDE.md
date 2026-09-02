# mise-helm-plugin

A mise backend plugin that installs helm plugins, so they can be pinned in
`mise.toml` as `helm-plugin:<name>`.

## Orientation

- `README.md` — how to use it.
- `DESIGN.md` — why it's shaped this way, and everything measured to find out.
  §3 (why `BackendExecEnv` can't do activation) is referenced from code
  comments by number; don't renumber it casually.
- `TODO.md` — what's done and what's left, with the reasoning.

## Commands

```sh
mise run lint          # hk: stylua + lua-language-server + actionlint + shellcheck
mise run format        # stylua
mise run test          # all three end-to-end tests, sequentially
mise run ci            # lint only — hermetic and fast, what CI's lint job runs
```

Individual tests: `test-activation`, `test-sync-hardening`, `test-activate-hook`.
They need network and install real helm plugins.

For manual work against the plugin:

```sh
mise plugin link --force helm-plugin .
mise ls-remote helm-plugin:helm-diff
mise install helm-plugin:helm-diff@3.9.0
```

## Things that will bite you

- **`mise` is not on the default PATH in tool shells.** It's at
  `~/.local/bin/mise`; export that first.
- **Lua type stubs only work if annotated.** `require("file")` returns
  `unknown`, so `types/mise-plugin.lua` does nothing unless each require has a
  `--- @type file` line above it. Without that, lint passes vacuously.
- **Test configs must be trusted explicitly.** A `mise.toml` with
  `[env]`/`[hooks]` that hasn't been trusted fails to parse rather than
  degrading, and trust is recorded per file content — rewriting a config
  invalidates it. Every test calls `mise trust` at each write.
- **Tests share global state.** All three call
  `mise plugin link --force helm-plugin`, so they run sequentially, not via
  `depends`.
- **helm 3 and helm 4 differ in ways that matter.** helm 4 needs
  `--verify=false` at install time; plugin.yaml fields (`command` vs
  `platformCommand`, `platformHooks`) decide which plugin versions load on
  which major. Pin deliberately and check both.
- **macOS ships bash 3.2.** No `${arr[-1]}`, no associative arrays. Keep the
  shell portable — CI runs Linux too, so no `sed -i ''` either.

## Conventions

Commit messages: imperative subject, then a body explaining *why* and what was
measured. Verify claims by running things rather than asserting them; when a
test is added for a bug, check the negative control (that it fails without the
fix). Existing commits show the register.
