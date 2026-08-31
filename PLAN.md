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
- Read `https://mise.jdx.dev/backend-plugin-development.html` in full before
  writing code — confirm the current `ctx` fields available in
  `BackendInstall` (`install_path`, `download_path`, `version`, `tool`,
  `options`) match what's assumed below, since the API may have evolved.

## Architecture

### 1. Installation (`BackendInstall`)

Do **not** reimplement helm's plugin installer. Instead, shell out to the
real `helm plugin install`, but redirect its target directory to mise's
per-version install path using a temporary `HELM_PLUGINS` override:

```lua
function PLUGIN:BackendInstall(ctx)
  local tool = ctx.tool           -- e.g. "helm-diff"
  local version = ctx.version     -- e.g. "3.9.0"
  local install_path = ctx.install_path

  local plugins_dir = install_path .. "/plugins"
  local repo_url = PLUGIN:ResolveRepoUrl(tool) -- see version listing below

  local cmd = string.format(
    'HELM_PLUGINS=%q helm plugin install %q --version %q',
    plugins_dir, repo_url, version
  )
  local ok, err = os.execute(cmd)
  if not ok then
    error("helm plugin install failed for " .. tool .. "@" .. version .. ": " .. tostring(err))
  end

  return {}
end
```

Notes:
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
  -- fetch tags from GitHub API, strip leading "v", sort ascending semver
  return { versions = versions }
end
```

Maintain a small internal map from short plugin name -> GitHub repo URL
(e.g. `helm-diff` -> `https://github.com/databus23/helm-diff`), scoped to
just the plugins you use. This is the main piece of "registry" data you own.

### 3. Making helm see the installed plugins (activation)

This is the part `BackendInstall`/`BackendListVersions` don't cover — mise
needs to expose the *currently active* set of plugin versions to helm via
`HELM_PLUGINS`, and that changes per project/per shell.

Two options, in increasing order of robustness:

- **Env var + symlink assembly, done at mise env-activation time.** The
  plugin sets `HELM_PLUGINS` to a mise-managed directory (e.g.
  `~/.local/share/mise/helm-plugins-active/`), and on each activation mise
  rebuilds that directory's contents as symlinks to
  `install_path/plugins/<plugin-name>/` for every currently active
  `helm-plugin:*` tool.
- **Per-shell temp directory instead of a shared one**, to avoid races
  between multiple concurrent shells with different active tool sets
  (e.g. two terminals in two different project directories). This avoids
  clobbering one shell's active plugin set with another's. Prefer this if
  mise's env-var/hook API allows per-invocation directories; otherwise
  fall back to the shared directory and accept the single-active-shell
  limitation as a known constraint.

Confirm during implementation which mechanism mise's backend/env API
actually exposes for "run this logic on every env activation, not just on
install" — this determines whether option 2 is feasible or you're stuck
with option 1's shared-directory limitation.

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

4. **Activation / symlink assembly**
   - Implement the `HELM_PLUGINS`-pointing-at-managed-directory logic.
   - Verify `helm plugin list` sees the plugin after `mise use` +
     `eval "$(mise activate)"`, with the correct version.
   - Test switching directories between two projects with different pinned
     versions of the same plugin; confirm `helm plugin list` reflects the
     right one in each.

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

- Exact `ctx` fields available in current `BackendInstall` — confirm against
  live docs, not assumptions in this plan.
- Whether mise's backend API supports a hook that runs on every env
  activation (needed for real per-project switching) or only on
  install/uninstall (which would force the shared-directory, single-active-shell
  limitation).
- Whether `helm plugin install` supports `--version` cleanly for all target
  plugins, or whether some require a git ref instead of a semver tag.