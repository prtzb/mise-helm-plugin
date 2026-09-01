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
HELM_PLUGINS = "{{xdg_state_home}}/helm-plugins/{{ config_root | basename }}-{{ config_root | hash(len=8) }}"

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

The directory is keyed on a hash of `config_root`, so each project gets its own
— e.g. `~/.local/state/helm-plugins/myproj-d2fbca0b`. Two shells in two projects
don't interfere, and two projects can pin different versions of the same plugin.
It lives in XDG state rather than in the repo because it's derived, machine-local
data that `helm-plugins-sync` can rebuild at any time; nothing is generated
inside your project, so there's nothing to `.gitignore`.

## Examples

`example/1` and `example/2` are two runnable projects that pin *different major
versions of helm* alongside the helm-secrets release each one supports:

| | helm | helm-diff | helm-secrets |
| --- | --- | --- | --- |
| `example/1` | 3 | 3.9.0 | 4.6.0 |
| `example/2` | 4 | 3.10.0 | 4.7.7 |

The helm-secrets pins are not interchangeable. Releases up to 4.6.4 set both
`command` and `platformCommand` in `plugin.yaml`; helm 3 accepts that (with a
deprecation warning as of 3.21) and helm 4 refuses to load the plugin at all.
4.6.5 dropped the bare `command`, so 4.6.5+ is required on helm 4. Pinning helm
per project is what makes both work side by side.

## Requirements

- `helm` on `PATH` — installation delegates to `helm plugin install` rather
  than reimplementing it. Both helm 3 and helm 4 work: helm 4 verifies plugin
  signatures by default and rejects git sources outright, so the backend
  detects the major version and passes `--verify=false` there. helm 3 has no
  such flag and doesn't get one.
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
  helm-diff versions on different helm majors, checked in both and on revisit
- `mise run test-sync-hardening` — uninstall cleanup, corrupt installs, stray
  files in the managed directory

`helm-plugins-sync` exits non-zero if anything needed attention — a plugin
installed without a readable `plugin.yaml`, or a non-symlink sitting in the
managed directory — but only after linking everything it could. One broken
plugin never blocks the others.

## Known limitations

- **Relies on undocumented mise behaviour.** The design works around
  `BackendExecEnv` caching and last-wins `env_vars` merging, neither of which
  is documented. If mise changes either, `mise run test-activation` should
  catch it.
- **`helm plugin install` needs network at install time**, including for
  plugins whose `plugin.yaml` hooks download prebuilt binaries.
- **Stale links are cleaned up lazily.** mise has no `BackendUninstall` hook,
  so `mise uninstall` can't prune anything; the link disappears on the next
  `helm-plugins-sync`, i.e. the next `cd` into the project. Harmless in the
  meantime — helm 3 and 4 both skip dangling plugin symlinks silently.
  Renaming or deleting a project likewise orphans its directory under
  `~/.local/state/helm-plugins/`, since the name is a hash of the old path.
  Both are safe to `rm -rf`.
