# Project Plan: `mise-helm-plugin` Backend Plugin

## Goal

Build a mise backend plugin (`helm-plugin:<name>`) that lets helm plugins be
declared, versioned, and installed through `mise.toml` like any other tool —
e.g.

```toml
[tools]
"helm-plugin:helm-diff" = "3.9.0"
"helm-plugin:helm-secrets" = "4.6.0"
```

instead of a `postinstall` hook calling `helm plugin install` directly.

## Non-goals (keep scope small)

- Do **not** attempt to support every possible `plugin.yaml` hook variant.
  Lean on `helm plugin install` itself to do installation — see Architecture.
- Do **not** build a general-purpose registry of all known helm plugins.
  Support only the plugins your projects actually use; add more later as needed.
- Do **not** try to solve global vs. per-shell `HELM_PLUGINS` conflicts across
  unrelated tools outside mise's control. Assume `HELM_PLUGINS` is always
  managed by this plugin while mise is active.

## Prerequisites

- `helm` itself must be installed and resolvable (via mise, e.g. `aqua:helm`
  or similar) before this backend runs its install step. Document this as a
  hard dependency.
- Start from `mise-backend-plugin-template`
  (https://github.com/jdx/mise-backend-plugin-template) rather than from
  scratch — it gives you the Lua scaffolding, LuaCATS type defs, and lint/test
  setup already wired up.
- Read `https://mise.jdx.dev/backend-plugin-development.html` and
  `https://mise.jdx.dev/plugin-lua-modules.html` before writing code.
  Verified against live docs 2026-08-31:

  | Hook | ctx fields |
  | --- | --- |
  | `BackendListVersions` | `tool`, `options` |
  | `BackendInstall` | `tool`, `version`, `install_path`, `download_path`, `options` |
  | `BackendExecEnv` | `tool`, `version`, `install_path`, `options` |

  Plugins run in an embedded Lua 5.1 VM (gopher-lua), not a standalone
  `lua` binary. Available modules, loaded with `require()`: `cmd`, `json`,
  `http`, `file`, `env`, `strings`, `semver`, `html`, `archiver`, `log`.
  Relevant pieces: `cmd.exec(command, {cwd=, env=, timeout=})`,
  `semver.sort` (ascending), `http.try_get`, `file.join_path/symlink/exists`,
  `log.debug` (gated behind `MISE_DEBUG=1`). `os.getenv()` works; the docs
  do not enumerate what else of the stock stdlib survives, so treat anything
  outside the injected modules as unverified.

## Architecture

### 1. Installation (`BackendInstall`)

Do **not** reimplement helm's plugin installer. Instead, shell out to the
real `helm plugin install`, but redirect its target directory to mise's
per-version install path using a temporary `HELM_PLUGINS` override:

```lua
local cmd = require("cmd")
local file = require("file")

function PLUGIN:BackendInstall(ctx)
  local tool = ctx.tool           -- e.g. "helm-diff"
  local version = ctx.version     -- e.g. "3.9.0"

  local plugins_dir = file.join_path(ctx.install_path, "plugins")
  local repo_url = PLUGIN:ResolveRepoUrl(tool) -- see version listing below

  local ok, err = pcall(cmd.exec,
    string.format("helm plugin install %s --version %s", repo_url, version),
    { env = { HELM_PLUGINS = plugins_dir } })
  if not ok then
    error("helm plugin install failed for " .. tool .. "@" .. version .. ": " .. tostring(err))
  end

  return {}
end
```

Notes:
- Use `cmd.exec` rather than `os.execute`. It's the documented idiom, it
  returns stdout as a string (useful for error messages), and it takes the
  environment **structurally** via its `env` option — so there is no shell
  command line to quote and no escaping bug waiting to happen.
- `helm plugin install` creates a subdirectory named after the plugin's
  `name` field in `plugin.yaml` inside `HELM_PLUGINS` — **not** the version.
  So the actual installed plugin will live at
  `install_path/plugins/<plugin-name>/`, not `install_path/plugins/`. The
  activation step (below) needs to account for this extra path segment.
- This approach means helm's own installer handles platform-specific
  archives, `plugin.yaml` install hooks (`make`, `go build`, etc.), and any
  future changes to those semantics — you inherit correctness from helm
  instead of maintaining it yourself.

### 2. Version listing (`BackendListVersions`)

There's no central registry of helm plugin versions, unlike a package
registry. Implement this per-plugin by querying the plugin's own GitHub
repo for tags/releases (same pattern mise's `github:` backend already uses):

```lua
function PLUGIN:BackendListVersions(ctx)
  local tool = ctx.tool
  local repo = PLUGIN:ResolveRepoUrl(tool)
  -- http.try_get the GitHub tags API, json.decode, strip leading "v",
  -- then semver.sort(versions) -- returns ascending, no hand-rolled sort
  return { versions = versions }
end
```

Use `http.try_get` (returns `(nil, err_string)` instead of raising) +
`json.decode` + `semver.sort`. All three are built in; no external deps.

Maintain a small internal map from short plugin name -> GitHub repo URL
(e.g. `helm-diff` -> `https://github.com/databus23/helm-diff`), scoped to
just the plugins you use. This is the main piece of "registry" data you own.

### 3. Making helm see the installed plugins (activation)

This is the part `BackendInstall`/`BackendListVersions` don't cover — mise
needs to expose the *currently active* set of plugin versions to helm via
`HELM_PLUGINS`, and that changes per project/per shell.

`BackendExecEnv(ctx)` looks like the hook for this — it's called per active
tool and returns env vars. **It cannot do the job.** Two measured constraints
rule it out; the design below works around them.

Two facts that looked promising at first:

- `HELM_PLUGINS` accepts **multiple** path-separated directories, not just
  one. Helm 3.x splits it in `plugin.FindPlugins` with `filepath.SplitList`
  ("Let's get all UNIXy and allow path separators"). Helm 4 moved the split
  out to the caller — `FindPlugins` now takes a pre-split `[]string` — so
  the capability still exists, but **verify against the helm version you
  actually pin**.
- Each active `helm-plugin:*` tool gets its own `BackendExecEnv` call.

So *if* mise concatenated same-key `env_vars` across multiple active tools,
each tool could just return its own `install_path/plugins` and the symlink
farm, the shared mutable directory, and the cross-shell race would all
disappear.

**Neither survives contact with mise.** Both measured 2026-08-31:

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
   So the return value must be a *pure function of `(tool, version)`* —
   keying it on the project (e.g. `PWD`, the only project-ish variable a hook
   can see; `MISE_PROJECT_ROOT` and friends are not exported) is unsound:
   a value computed in one project is served to every other project pinning
   the same version. Symlink assembly inside the hook is equally dead, since
   a cache hit skips the rebuild entirely on `cd`.

The hook still has to *exist* — deleting `hooks/backend_exec_env.lua` makes
mise fail every bin-path lookup with "module not found". It keeps one sound
job: adding the plugin's own `bin/` to `PATH`, so projects can write
`enter = "helm-plugins-sync"` rather than hardcoding a path into mise's data
directory. That's safe precisely where `HELM_PLUGINS` wasn't — `PATH` is the
one key mise merges, and the value depends only on the plugin's location, so
caching it per tool@version is harmless.

**Design: assembly outside the hook.** `mise ls --current --json` reports the
active `helm-plugin:*` tools with their `install_path`s, so a plain script can
build the directory correctly. The consuming project wires it up:

```toml
[tools]
"helm-plugin:helm-diff" = "3.9.0"
"helm-plugin:helm-secrets" = "4.6.0"

[env]
HELM_PLUGINS = "{{xdg_state_home}}/helm-plugins/{{ config_root | basename }}-{{ config_root | hash(len=8) }}"

[hooks]
enter = "helm-plugins-sync"
```

`bin/helm-plugins-sync` symlinks each active plugin into `$HELM_PLUGINS`
(named after the tool, so version switches replace in place) and prunes
symlinks for plugins no longer active. Because the directory is keyed on a
hash of `config_root`, it is per-project by construction: no global shared
state, no cross-shell race, and the single-active-shell limitation never
arises.

On placement: mise defines no per-project directory convention — its
documented directories (config, cache, state, data) are all user-level. But
templates expose `xdg_state_home` and a `hash` filter, so the directory goes
in XDG state, which mise describes as "state local to the machine". That fits
derived, rebuildable data better than cache (which may be wiped) or data
(which is for installed tools), and keeps generated files out of the repo.
It sits beside `~/.local/state/mise/` rather than inside it, so we're not
squatting in a namespace mise owns.

Costs, honestly: four lines in each consuming `mise.toml` beyond `[tools]`,
a dependency on `mise activate` for the `enter` hook to fire, and `jq`.

## Milestones

1. **Scaffold**
   - Clone `mise-backend-plugin-template`, rename, strip template boilerplate.
   - Confirm `mise plugin link --force helm-plugin .` works and `mise ls-remote`
     runs (even with a stub `BackendListVersions`).

2. **Version listing for one plugin**
   - Hardcode `helm-diff` -> its GitHub repo.
   - Implement `BackendListVersions` against GitHub tags.
   - Verify `mise ls-remote helm-plugin:helm-diff` returns correct, sorted versions.

3. **Install for one plugin**
   - Implement `BackendInstall` using the `HELM_PLUGINS` override trick above.
   - Verify `mise install helm-plugin:helm-diff@3.9.0` produces
     `install_path/plugins/helm-diff/plugin.yaml` correctly.

4. **Activation** — DONE (2026-08-31). Settled as `bin/helm-plugins-sync`
   plus per-project `[env]`/`[hooks]` wiring; see §3 for why the hook route
   failed. `mise run test-activation` covers two projects pinning different
   helm-diff versions, including revisiting the first, and passes.
   - Still untested: that the `enter` hook actually fires under a real
     `eval "$(mise activate)"` shell, as opposed to the test calling
     `helm-plugins-sync` directly.

5. **Add remaining plugins**
   - Add `helm-secrets`, and whatever others your projects use, to the
     name -> repo map.
   - Repeat verification for each.

6. **Edge cases & hardening**
   - `mise uninstall` cleans up stale symlinks.
   - Failed `helm plugin install` (bad version, network failure) errors
     clearly instead of leaving a half-installed state.
   - Document the "single active shell" limitation if option 2 above
     wasn't feasible.

7. **Docs**
   - README: install instructions, supported plugins, known limitations
     (especially anything about concurrent shells / global state).
   - Example `mise.toml` snippet for a real project.

## Testing plan

- Manual smoke test per milestone (above) is sufficient given the small
  scope — a full test suite is likely overkill for a personal/small-team tool.
- One end-to-end test: two sibling directories, each with a `mise.toml`
  pinning a different version of the same helm plugin; `cd` between them and
  confirm `helm plugin list` / `helm diff version` (or equivalent) reflects
  the correct version each time.

## Risks / open questions to resolve early

- ~~Exact `ctx` fields available in current `BackendInstall`.~~ Resolved
  2026-08-31 — see the table under Prerequisites.
- ~~Whether mise's backend API supports a hook that runs on every env
  activation.~~ Partly resolved: `BackendExecEnv` exists and returns
  `env_vars`. Still open is whether it re-runs on every directory change or
  is cached per tool-version.
- ~~Whether mise merges same-key `env_vars` across multiple active tools.~~
  Resolved 2026-08-31: **it does not** — last-wins. Activation needs symlink
  assembly; see §3.
- ~~Whether the helm version you pin still splits `HELM_PLUGINS` on the path
  separator.~~ Verified empirically against helm 3.11.0: colon-separated
  values list plugins from every directory. Re-check if you move to helm 4.
- ~~Whether `BackendExecEnv` can instead *append* to the `HELM_PLUGINS` it
  inherits.~~ Resolved 2026-08-31: no — `os.getenv("HELM_PLUGINS")` is `nil`
  in every hook. See §3.
- ~~Whether mise re-runs `BackendExecEnv` on every directory change.~~
  Resolved 2026-08-31: no, it caches per tool@version. This is undocumented
  behaviour (the docs' only caching note is a "TODO" about shared Lua
  modules), so it could change; `mise run test-activation` would catch it.
- Whether `helm plugin install` supports `--version` cleanly for all target
  plugins, or whether some require a git ref instead of a semver tag.