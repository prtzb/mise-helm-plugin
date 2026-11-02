# mise-helm-plugin

A [mise](https://mise.jdx.dev) backend plugin that installs helm plugins, so
they can be declared and pinned in `mise.toml` like any other tool instead of
a hook calling `helm plugin install` by hand.

## Install

```sh
mise plugin install helm-plugin https://github.com/prtzb/mise-helm-plugin
```

Backend plugins aren't in mise's shorthand registry, so the git URL is
required — `mise plugin install helm-plugin` on its own won't find it.

## Usage

```toml
[tools]
"helm-plugin:helm-diff" = "3.9.0"
"helm-plugin:helm-secrets" = "4.6.0"

[env]
HELM_PLUGINS = "{{xdg_state_home}}/helm-plugins/{{ config_root | basename }}-{{ config_root | hash(len=8) }}"

[hooks]
enter = "helm-plugins-sync"
postinstall = "helm-plugins-sync"
```

The `[env]` and `[hooks]` lines are required, not optional polish. mise's
backend API cannot set `HELM_PLUGINS` correctly on its own: it doesn't merge
same-key `env_vars` across tools, and it caches `BackendExecEnv` per
tool@version so the hook can't react to `cd`. `helm-plugins-sync` does the
work instead — it symlinks every active `helm-plugin:*` tool into
`$HELM_PLUGINS` and prunes ones that are no longer active. See DESIGN.md §3 for
the measurements behind that.

Both hooks matter. `enter` keeps the directory current as you move between
projects; `postinstall` covers the case `enter` can't, because a first
`mise install` is usually run from inside the project you are already in.
Without it, `helm plugin list` shows nothing until you leave and come back.

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
| `example/2` | 4 | 3.10.0 | 4.7.7, as three release archives |

The helm-secrets pins are not interchangeable. Releases up to 4.6.4 set both
`command` and `platformCommand` in `plugin.yaml`; helm 3 accepts that (with a
deprecation warning as of 3.21) and helm 4 refuses to load the plugin at all.
4.6.5 dropped the bare `command`, so 4.6.5+ is required on helm 4. Pinning helm
per project is what makes both work side by side. On helm 4, helm-secrets is
also split into three plugins published only as release archives, which is how
`example/2` installs it — see [Plugins published as release
archives](#plugins-published-as-release-archives).

`example/3` shows the two declaration forms side by side: helm-diff by its
built-in shorthand, and helm-unittest — which has no shorthand — by naming its
repo inline. In a shell with `mise activate`, cd in and both are simply there:

```sh
cd example/3 && mise install
helm plugin list
```

```
NAME    	VERSION	DESCRIPTION
diff    	3.9.0  	Preview helm upgrade changes as a diff
unittest	1.0.3  	Unit test for helm chart in YAML with ease to keep your chart functional and robust.
```

It pins helm-unittest 1.0.3 rather than the latest for the same class of reason
as the helm-secrets pins above: 1.1.0 moved `plugin.yaml` to `platformCommand`
and `platformHooks`, and neither helm 3.21 nor helm 4.2 can parse
`platformHooks` — both refuse the plugin with `unknown field "platformHooks"`.
1.0.3 is the last release using the classic `command`/`hooks` form, and it works
on both majors.

## Requirements

- `helm`, pinned in the same `mise.toml` (recommended) or on `PATH` —
  installation delegates to `helm plugin install` rather than reimplementing
  it. A pinned helm is used even if a different one is on `PATH`, and the
  backend waits for it when mise is still installing it in parallel. Both helm 3 and helm 4 work: helm 4 verifies plugin
  signatures by default and rejects git sources outright, so the backend
  detects the major version and passes `--verify=false` there. helm 3 has no
  such flag and doesn't get one.
- `git`, which helm's own plugin installer shells out to.
- `mise activate` in your shell, so the `enter` hook fires on `cd`. Without it
  the plugins still install, but `$HELM_PLUGINS` won't be rebuilt
  automatically — run `helm-plugins-sync` by hand. The `postinstall` hook runs
  either way, since mise runs it itself.

## Plugins

Two have built-in shorthands:

| Tool | Repo |
| --- | --- |
| `helm-diff` | [databus23/helm-diff](https://github.com/databus23/helm-diff) |
| `helm-secrets` | [jkroepke/helm-secrets](https://github.com/jkroepke/helm-secrets) |

Any other GitHub-hosted plugin works too — name the repo inline and mise
forwards it to the backend as a tool option:

```toml
[tools]
"helm-plugin:<tool-name>" = { version = "<version>", repo = "<owner>/<repo>" }
```

`<tool-name>` is yours to choose: it names the mise tool, while helm takes the
plugin's real name from its `plugin.yaml`. The two need not match.

`repo` must be an `owner/repo` slug rather than a URL. Version listing goes
through the GitHub tags API, so a plugin hosted anywhere else could install but
would never resolve a version — the backend rejects the URL form up front
instead of failing later. Adding a shorthand to the map in `lib/registry.lua`
is still worth it for plugins you use across many projects, but it is no longer
required.

### Plugins published as release archives

Some plugins can't be installed from a checkout — helm-secrets ships three
separate plugins for helm 4, and each is a release archive. Name the asset:

```toml
[tools]
"helm-plugin:helm-secrets-cli" = { version = "4.7.7", repo = "jkroepke/helm-secrets", asset = "secrets-{version}.tgz" }
"helm-plugin:helm-secrets-getter" = { version = "4.7.7", repo = "jkroepke/helm-secrets", asset = "secrets-getter-{version}.tgz" }
"helm-plugin:helm-secrets-post-renderer" = { version = "4.7.7", repo = "jkroepke/helm-secrets", asset = "secrets-post-renderer-{version}.tgz" }
```

`{version}` expands to the pinned version, and the asset is fetched from that
repo's release for tag `v<version>`. Use **single** braces: mise templates
config values itself and rewrites `{{version}}` to `{version}` before the
backend sees it. If a release tags differently or hosts the archive elsewhere,
give `asset` a full `https://` URL instead; `{version}` expands there too.

Two things to know:

- **Asset installs need helm 4.** helm 3 doesn't recognise a URL as an archive
  and tries to clone it, failing with `Unable to update repository`. The
  backend checks the major version and says so instead. See `example/2`.
- **Give each plugin its own tool name.** Two tools resolving to the same helm
  plugin make helm refuse to load *any* plugin (`two plugins claim the name
  ...`), so installing one repo under three names breaks everything, including
  unrelated plugins. `helm-plugins-sync` detects that, links only the first and
  reports the rest, so helm keeps working while you fix the config.

## Development

```sh
mise plugin link --force helm-plugin .
mise ls-remote helm-plugin:helm-diff
mise install helm-plugin:helm-diff@3.9.0
```

- `mise run lint` / `mise run format` — hk + stylua + actionlint + shellcheck
- `mise run test` — all four end-to-end tests below, in sequence. Needs network
  and installs real helm plugins, so it's a separate CI job from `mise run ci`,
  which stays lint-only and hermetic.
- `mise run test-activation` — end-to-end: projects pinning different helm-diff
  versions on different helm majors, checked in both and on revisit, plus one
  reaching a plugin by inline `repo` and one installing the three helm-secrets
  release archives on helm 4
- `mise run test-sync-hardening` — uninstall cleanup, corrupt installs, stray
  files, dotfiles and directories in the managed directory, and two tools
  claiming one helm plugin name. Runs against a scratch
  `MISE_DATA_DIR`, so the corruption case can't touch your real installs.
- `mise run test-activate-hook` — runs `mise activate` under both bash and zsh
  and checks that `cd` alone rebuilds the directory. No interactive shell is
  involved: both shells hook `cd` without needing a prompt, so the test never
  touches the terminal it was launched from.
- `mise run test-install-resolution` — installs with the wrong helm in front on
  `PATH`, three ways: a mise shim, which re-applies the project's `[env]` and
  redirects the install into `$HELM_PLUGINS`; a helm of a different major, which
  decides `--verify` wrongly; and no helm at all, where the hook has to wait for
  the one mise is installing in parallel. All three are shapes CI runs in.

`helm-plugins-sync` exits non-zero if anything needed attention — a plugin
installed without a readable `plugin.yaml`, a non-symlink sitting in the
managed directory, or two tools claiming the same helm plugin name — but only
after linking everything it could. One broken
plugin never blocks the others.

## Known limitations

- **Relies on undocumented mise behaviour.** The design works around
  `BackendExecEnv` caching and last-wins `env_vars` merging, neither of which
  is documented. If mise changes either, `mise run test-activation` should
  catch it.
- **`helm plugin install` needs network at install time**, including for
  plugins whose `plugin.yaml` hooks download prebuilt binaries.
- **The tool name is the identity, not the repo.** mise keys install paths on
  `helm-plugin-<tool>/<version>`, which doesn't include the repo. Two projects
  pinning the same tool name at the same version with *different* `repo` values
  therefore share one install: the first to install wins and the second is told
  "all tools are installed" while quietly getting the other project's plugin.
  Measured, not hypothetical. Give distinct plugins distinct tool names.

  The same applies over time, not just across projects: **changing a tool's
  options doesn't reinstall it.** Adding `asset` to a name already installed
  from its repo keeps the old install and ignores the option. Either use a new
  tool name or `mise uninstall helm-plugin:<tool>@<version>` first.
- **Stale links are cleaned up lazily.** mise has no `BackendUninstall` hook,
  so `mise uninstall` can't prune anything; the link disappears on the next
  `helm-plugins-sync`, i.e. the next `cd` into the project. Harmless in the
  meantime — helm 3 and 4 both skip dangling plugin symlinks silently.
  Renaming or deleting a project likewise orphans its directory under
  `~/.local/state/helm-plugins/`, since the name is a hash of the old path.
  Both are safe to `rm -rf`.
