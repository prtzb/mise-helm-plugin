# mise-helm-plugin

A [mise](https://mise.jdx.dev) backend plugin that installs helm plugins, so
they can be declared and pinned in `mise.toml` like any other tool instead of
being installed by a `postinstall` hook.

## Usage

```toml
[tools]
"helm-plugin:helm-diff" = "3.9.0"
"helm-plugin:helm-secrets" = "4.6.0"

[env]
HELM_PLUGINS = "{{config_root}}/.mise/helm-plugins"

[hooks]
enter = "helm-plugins-sync"
```

The `[env]` and `[hooks]` lines are required, not optional polish. mise's
backend API cannot set `HELM_PLUGINS` correctly on its own: it doesn't merge
same-key `env_vars` across tools, and it caches `BackendExecEnv` per
tool@version so the hook can't react to `cd`. `helm-plugins-sync` does the
work instead — it symlinks every active `helm-plugin:*` tool into
`$HELM_PLUGINS` and prunes ones that are no longer active. See PLAN.md §3 for
the measurements behind that.

You don't need to install `helm-plugins-sync` or reference it by path: the
plugin puts its own `bin/` on `PATH` whenever a `helm-plugin:*` tool is active,
so the bare name in `[hooks]` resolves.

Because `HELM_PLUGINS` lives under `{{config_root}}`, each project gets its own
directory. Two shells in two projects don't interfere, and two projects can pin
different versions of the same plugin.

## Requirements

- `helm` on `PATH` — installation delegates to `helm plugin install` rather
  than reimplementing it.
- `git`, which helm's own plugin installer shells out to.
- `jq`, used by `helm-plugins-sync` to read `mise ls --current --json`.
- `mise activate` in your shell, so the `enter` hook fires on `cd`. Without it
  the plugins still install, but `$HELM_PLUGINS` won't be rebuilt
  automatically — run `helm-plugins-sync` by hand.

## Supported plugins

| Tool | Repo |
| --- | --- |
| `helm-diff` | [databus23/helm-diff](https://github.com/databus23/helm-diff) |
| `helm-secrets` | [jkroepke/helm-secrets](https://github.com/jkroepke/helm-secrets) |

This is deliberately not a general-purpose registry. Add entries to
`PLUGIN.tools` in `metadata.lua` as you need them.

## Development

```sh
mise plugin link --force helm-plugin .
mise ls-remote helm-plugin:helm-diff
mise install helm-plugin:helm-diff@3.9.0
```

- `mise run lint` / `mise run format` — hk + stylua + actionlint
- `mise run test-activation` — end-to-end: two projects pinning different
  helm-diff versions, checked in both and on revisit

## Known limitations

- **Relies on undocumented mise behaviour.** The design works around
  `BackendExecEnv` caching and last-wins `env_vars` merging, neither of which
  is documented. If mise changes either, `mise run test-activation` should
  catch it.
- **`helm plugin install` needs network at install time**, including for
  plugins whose `plugin.yaml` hooks download prebuilt binaries.
- **Stale directories aren't garbage collected.** `mise uninstall` doesn't run
  `helm-plugins-sync`, so a removed plugin's symlink survives until the next
  `cd` into the project.
