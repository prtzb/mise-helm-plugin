# Design notes: `mise-helm-plugin`

Why this plugin is shaped the way it is, and what was measured to find out.
The section numbering is referenced from code comments (`DESIGN.md §3`), so
don't renumber casually.

For what's built and what's left, see `TODO.md`. For how to use it, `README.md`.

## Goal

A mise backend plugin (`helm-plugin:<name>`) that lets helm plugins be
declared, versioned, and installed through `mise.toml` like any other tool,
instead of a `postinstall` hook calling `helm plugin install` directly.

## Non-goals

- Do **not** support every possible `plugin.yaml` hook variant. Lean on
  `helm plugin install` itself — see §1.
- Do **not** curate a registry of all known helm plugins. The bundled map in
  `metadata.lua` stays small. It is no longer the only way in, though: mise
  forwards arbitrary tool options to every hook as `ctx.options` (measured
  2026-09-02), so a project can name any GitHub-hosted plugin inline with
  `repo = "owner/repo"`. The map is a shorthand, not a gate — which keeps the
  non-goal intact while removing the need to fork the plugin to use it.
- Do **not** try to solve global vs. per-shell `HELM_PLUGINS` conflicts across
  unrelated tools outside mise's control. Assume `HELM_PLUGINS` is managed by
  this plugin while mise is active.

## What mise gives a backend plugin

Hook context fields, verified against live docs 2026-08-31:

| Hook | ctx fields |
| --- | --- |
| `BackendListVersions` | `tool`, `options` |
| `BackendInstall` | `tool`, `version`, `install_path`, `download_path`, `options` |
| `BackendExecEnv` | `tool`, `version`, `install_path`, `options` |

Plugins run in an embedded Lua 5.1 VM (gopher-lua), not a standalone `lua`
binary. Modules loaded with `require()`: `cmd`, `json`, `http`, `file`, `env`,
`strings`, `semver`, `html`, `archiver`, `log`. `os.getenv()` works; the docs
don't enumerate what else of the stock stdlib survives, so treat anything
outside the injected modules as unverified.

`types/mise-plugin.lua` holds LuaCATS stubs for these. They only do anything if
each `require` is annotated — `--- @type file` above `local file =
require("file")` — because `require` otherwise returns `unknown` and
lua-language-server checks nothing.

## 1. Installation (`BackendInstall`)

Don't reimplement helm's plugin installer. Shell out to the real
`helm plugin install`, redirecting its target directory to mise's per-version
install path with a temporary `HELM_PLUGINS` override. helm then handles
platform-specific archives, `plugin.yaml` install hooks (`make`, `go build`,
prebuilt binary downloads), and any future changes to those semantics — we
inherit correctness instead of maintaining it.

Notes:

- Use `cmd.exec`, not `os.execute`. It returns stdout as a string (useful in
  error messages) and takes the environment **structurally** via its `env`
  option, so there is no shell command line to quote.
- `cmd.exec`'s `env` **merges** with the inherited environment rather than
  replacing it (measured 2026-09-01: a variable set only in the calling shell
  was visible to the command, and `PATH` arrived at full length). So
  `HELM_PLUGINS` is the only key worth setting — `PATH`, `HOME`, and the proxy
  and TLS variables git needs all come through on their own.
- `helm plugin install` creates a subdirectory named after the plugin's `name`
  field in `plugin.yaml`, **not** after the tool or the version. The installed
  plugin lands at `install_path/plugins/<plugin-name>/`, and activation has to
  discover that segment rather than assume it.
- helm 4 verifies plugin signatures by default and rejects git sources
  outright, so the backend detects the major version and passes
  `--verify=false` there. helm 3 has no such flag.

## 2. Version listing (`BackendListVersions`)

There's no central registry of helm plugin versions, so query the plugin's own
GitHub repo for tags — the same pattern mise's `github:` backend uses.
`http.try_get` + `json.decode` + `semver.sort`, all built in.

This is why `repo` must be an `owner/repo` slug rather than a URL: version
listing goes through the GitHub tags API, so a plugin hosted anywhere else
could install but would never resolve a version. The backend rejects the URL
form up front instead of failing later.

mise filters prereleases itself (measured 2026-09-02: both supported repos have
`-rc.N` tags, `ls-remote` lists 77 versions with zero rc, and
`helm-plugin:helm-secrets@4.7` resolves to `4.7.7`). The loose `^%d+%.%d+` tag
filter is therefore fine as it stands.

## 3. Making helm see the installed plugins (activation)

This is the part `BackendInstall`/`BackendListVersions` don't cover — mise has
to expose the *currently active* set of plugin versions to helm via
`HELM_PLUGINS`, and that changes per project and per shell.

`BackendExecEnv(ctx)` looks like the hook for this: it's called per active tool
and returns env vars. **It cannot do the job.**

Two facts that looked promising at first:

- `HELM_PLUGINS` accepts **multiple** path-separated directories. helm 3 splits
  it in `plugin.FindPlugins` with `filepath.SplitList` ("Let's get all UNIXy
  and allow path separators"). helm 4 moved the split out to the caller —
  `FindPlugins` now takes a pre-split `[]string` — so the capability still
  exists, but verify against the helm version you actually pin.
- Each active `helm-plugin:*` tool gets its own `BackendExecEnv` call.

So *if* mise concatenated same-key `env_vars` across active tools, each tool
could return its own `install_path/plugins` and the symlink farm, the shared
mutable directory, and the cross-shell race would all disappear.

**Neither survives contact with mise.** All measured 2026-08-31:

1. **Same-key `env_vars` are last-wins, not merged.** With
   `helm-plugin:helm-diff@3.9.0` and `helm-plugin:helm-secrets@4.6.0` both
   active, mise emitted only
   `HELM_PLUGINS=~/.local/share/mise/installs/helm-plugin-helm-diff/3.9.0/plugins`
   and `helm plugin list` showed one plugin. `PATH` is special-cased;
   `HELM_PLUGINS` is not. Both plugins *installed* fine, and joining the two
   directories with a colon by hand lists both — the gap is purely activation.
2. **A hook cannot append to its siblings' work.** `os.getenv("HELM_PLUGINS")`
   inside `BackendExecEnv` returns `nil` for every tool: mise builds each
   tool's env in isolation and merges afterwards. (The docs' "inherits the
   mise-constructed environment" applies to `cmd.exec` inside a hook.)
3. **`BackendExecEnv` output is cached per tool@version.** A second `mise env`
   in the same project emits the right value without invoking the hook at all.
   The return value must therefore be a *pure function of `(tool, version)`* —
   keying it on the project (e.g. `PWD`, the only project-ish variable a hook
   can see; `MISE_PROJECT_ROOT` and friends are not exported) is unsound, since
   a value computed in one project is served to every other project pinning the
   same version. Symlink assembly inside the hook is equally dead: a cache hit
   skips the rebuild entirely on `cd`.

The hook still has to *exist* — deleting `hooks/backend_exec_env.lua` makes
mise fail every bin-path lookup with "module not found". It keeps one sound
job: putting the plugin's own `bin/` on `PATH`, so projects can write
`enter = "helm-plugins-sync"` rather than hardcoding a path into mise's data
directory. That's safe precisely where `HELM_PLUGINS` wasn't — `PATH` is the
one key mise merges, and the value depends only on the plugin's location, so
caching it per tool@version is harmless.

**Design: assembly outside the hook.** `mise ls --current --json` reports the
active `helm-plugin:*` tools with their `install_path`s, so a plain script can
build the directory correctly. The consuming project wires it up with `[env]`
and `[hooks]` — see `example/1/mise.toml` for the canonical four lines.

`bin/helm-plugins-sync` symlinks each active plugin into `$HELM_PLUGINS` (named
after the tool, so version switches replace in place) and prunes symlinks for
plugins no longer active. Because the directory is keyed on a hash of
`config_root`, it is per-project by construction: no global shared state, no
cross-shell race, and the single-active-shell limitation never arises.

On placement: mise defines no per-project directory convention — its documented
directories (config, cache, state, data) are all user-level. Templates expose
`xdg_state_home` and a `hash` filter, so the directory goes in XDG state, which
mise describes as "state local to the machine". That fits derived, rebuildable
data better than cache (which may be wiped) or data (which is for installed
tools), and keeps generated files out of the repo. It sits beside
`~/.local/state/mise/` rather than inside it, so we aren't squatting in a
namespace mise owns.

Costs, honestly: four lines in each consuming `mise.toml` beyond `[tools]`, a
dependency on `mise activate` for the `enter` hook to fire, and `jq`.

## Other measured facts

- **There is no `BackendUninstall` hook.** mise documents only the three hooks
  we implement, so pruning stale links is `helm-plugins-sync`'s job on its next
  run. That's benign: both helm 3.21.4 and helm 4.2.4 skip a dangling plugin
  symlink silently and exit 0, so the window before the next `cd` breaks
  nothing.
- **Failed installs leave nothing behind.** mise removes the install directory
  itself, so there is no half-installed state to clean up.
- **The tool name is the identity, not the repo.** Install paths are
  `helm-plugin-<tool>/<version>`, with no repo component. Measured 2026-09-02:
  project x pinned `samename@3.9.0` at helm-diff, project y pinned the same
  name and version at helm-secrets, and y was told "all tools are installed"
  while silently getting helm-diff. Not fixable from inside the plugin;
  documented under Known limitations in the README.
- **Untrusted configs don't parse at all.** A `mise.toml` with `[env]` or
  `[hooks]` that hasn't been trusted fails outright rather than degrading, and
  trust is recorded per file content — so rewriting a config invalidates it.
  The test tasks call `mise trust` explicitly at every write; relying on
  ambient trust state made them pass locally while a clean runner would have
  failed.

## Testing

Four tasks, all runnable individually; `mise run test` runs the three
end-to-end ones sequentially (they share the global plugin link and data dir,
so parallel runs race).

- `test-activation` — the main one. Projects pinning different helm-diff
  versions on different helm majors, revisited to catch state leaking between
  them, plus a project reaching helm-diff purely through an inline `repo` and
  assertions on both resolution error messages.
- `test-sync-hardening` — uninstall cleanup, corrupt installs, stray files and
  directories. Runs against a scratch `MISE_DATA_DIR` so the corruption case
  can't touch real installs.
- `test-activate-hook` — runs `eval "$(mise activate <sh>)"` under both bash and
  zsh and checks that `cd` alone rebuilds the directory. Negative control
  checked: with activation removed, nothing is created, so it can't pass
  vacuously.

  No interactive shell is involved. Both shells hook `cd` without needing a
  prompt — zsh through `add-zsh-hook chpwd`, bash through the `cd` function
  wrapper mise installs — so only `precmd`/`PROMPT_COMMAND` would require `-i`,
  and `cd` is what this test is about. That matters beyond tidiness: `zsh -i`
  turns on job control, which acts on the controlling terminal rather than on
  stdin, so no redirection keeps such a shell away from the terminal running
  the suite. It takes the foreground process group and can leave the invoking
  shell in the background. Running both shells also means the test never skips
  entirely, since bash is always present.
- `mise run ci` — lint only, hermetic, fast. CI runs it as a separate job from
  the tests.

The examples are configuration only — `cd` in with `mise activate` and the
plugins are active — and deliberately not in CI. `example/3` in particular
installs helm-unittest, a real third-party dependency whose release cadence
could break the build for reasons unrelated to this plugin.

## Still open

- Whether `helm plugin install --version` works cleanly for every plugin
  someone might name, or whether some need a git ref rather than a semver tag.
  Fine for all four plugins tried so far.
- Whether mise supports plugin-local `lib/` modules. If it does, the registry
  and resolution logic should move out of `metadata.lua`.
- The Linux half of the CI matrix has never actually run.
