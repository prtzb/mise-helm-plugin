# TODO

Findings from a full review of the code and docs on 2026-09-01. Claims marked
**verified** were measured on this machine during the review, not inferred.

The first batch (symlink guard, `cmd.exec` env, `@type` annotations,
shellcheck) was applied on 2026-09-02 — see "Done" at the bottom.

## Bugs

- [x] **`ln -sfn` corrupts a stray real directory instead of reporting it** —
      `bin/helm-plugins-sync:80`.

      The prune loop only ever deletes symlinks, but the link step upstream has
      no matching guard. If `$target/<tool>` exists as a real directory,
      `ln -sfn src dest` does not replace it — it creates the link *inside* it.
      Verified:

      ```
      ln -sfn /tmp/src /tmp/target/helm-diff   # exit 0
      /tmp/target/helm-diff/src                # <- link created inside
      ```

      So the "a stray non-symlink is preserved" invariant that
      `test-sync-hardening` checks only holds for stray *files*. A stray
      directory gets written into, and helm then sees a plugin dir with no
      `plugin.yaml`. Fix, symmetric with the prune loop:

      ```bash
      dest="$target/$tool"
      if [ -e "$dest" ] && [ ! -L "$dest" ]; then
          echo "helm-plugins-sync: $dest is not a symlink, refusing to replace it" >&2
          broken=1
          continue
      fi
      ln -sfn "$(dirname "$manifest")" "$dest"
      ```

- [x] **Add the matching test case** to `mise-tasks/test-sync-hardening`:
      `mkdir "$target/helm-diff"` → expect exit 1 and the directory untouched.

- [ ] **Dotfiles are never pruned or reported** — `bin/helm-plugins-sync:86`.
      `"$target"/*` doesn't match hidden entries, so a stray `.foo` escapes the
      accounting entirely. `shopt -s nullglob dotglob` at the top covers this
      and also makes the `[ -L ] || [ -e ]` literal-glob guard unnecessary.

## Resolved unknowns (measured during review)

- [x] **`cmd.exec`'s `env` merges with the inherited environment** —
      `hooks/backend_install.lua:42-50` currently hedges: *"the docs don't state
      whether `env` merges with the inherited environment or replaces it."*
      Probed with a throwaway copy of the plugin:

      ```
      RESULT PROBE=[hello] HOME=[/Users/staffan] FOO=[bar] PATHLEN=[624]
      ```

      `PROBE_MARKER` was ambient and never in the `env` table; `PATH` came
      through at full length. **It merges.** Therefore:

      - Drop `PATH` and `HOME` from the table; replace the hedge with the fact.
      - More usefully: `HTTPS_PROXY`, `SSL_CERT_FILE`, `GIT_*` etc. already
        reach helm and git. Under the replace hypothesis they would not have,
        and installs behind a proxy would have failed mysteriously.
      - Record this in the design doc alongside the other measurements.

- [ ] **Prereleases are already filtered by mise** — no action needed beyond a
      comment. Both supported repos have `-rc.N` tags and the
      `^%d+%.%d+` filter in `hooks/backend_list_versions.lua:23` lets them
      through, but mise drops them itself: `ls-remote helm-plugin:helm-secrets`
      lists 77 versions with zero rc, and `helm-plugin:helm-secrets@4.7`
      resolves to `4.7.7`. Add a note so nobody "tightens" the regex later
      believing it mattered.

## Type stubs are decorative

- [x] **`types/mise-plugin.lua` provides no actual checking.** It doesn't
      declare `file.glob` (used at `hooks/backend_install.lua:83`) or
      `http.try_get` (used at `hooks/backend_list_versions.lua:59`), and
      `mise run lint` passes anyway — because `require("file")` returns
      `unknown`, so lua-language-server checks nothing. A 200-line stub file is
      being maintained for zero checking.

      Verified fix — annotate each require:

      ```lua
      --- @type file
      local file = require("file")
      ```

      With that, luals flags unknown fields:

      ```
      hooks/t.lua:4:17 [Warning] Undefined field `definitely_not_a_real_function`. (undefined-field)
      ```

- [x] Apply the annotation to all five requires, then **sync the stubs with
      reality** — the first run will flag `glob` and `try_get`.

## Lint and CI gaps

- [x] **Bash isn't linted at all.** `helm-plugins-sync` is the most intricate
      code in the repo (symlink lifecycle, deferred exit codes, array
      membership under `set -u`) and `hk.pkl` covers only Lua and Actions.
      Currently clean apart from two SC2012 infos in the test scripts, so
      adding it costs nothing and locks the state in:

      ```pkl
      ["shellcheck"] {
          glob = List("bin/*", "mise-tasks/*")
          check = "shellcheck -s bash {{files}}"
      }
      ```

- [x] **CI runs lint only.** `[tasks.ci]` depends on `["lint"]` and nothing
      else, so the three test tasks run only when remembered. GitHub Actions
      has network and mise installs helm, so `test-activation` and
      `test-sync-hardening` can both run on `ubuntu-latest`. Two blockers
      first (below).

- [x] **`sed -i ''` is BSD-only** — `mise-tasks/test-sync-hardening:81` fails on
      Linux. Use a temp file, or regenerate `mise.toml` from a heredoc since
      it's already built that way.

- [x] **`test-sync-hardening` mutates the real mise install dir** —
      `mise-tasks/test-sync-hardening:68` does
      `mv "$secrets_plugins" "$secrets_plugins.bak"` against
      `~/.local/share/mise`. The trap restores it on normal exit, but a
      `kill -9` or a reboot mid-run leaves the user's actual helm-secrets
      install broken. Point `MISE_DATA_DIR` at a scratch dir for the whole
      test — that also makes it hermetic enough for CI without polluting the
      runner.

- [x] **Stale task reference** — `mise.toml:31` mentions `test-env-merge`,
      which doesn't exist (renamed at some point).

- [x] **No aggregate `[tasks.test]`** — the three test tasks have to be
      remembered individually.

- [x] **`test-activation` leaves orphaned `$HELM_PLUGINS` dirs** under XDG
      state; it has no cleanup trap for them (`test-sync-hardening` and
      `test-activate-hook` both do).

## Substantive refactor

- [x] **Make the plugin registry extensible via `ctx.options`.** Done
      2026-09-02. Verified the premise first: mise forwards arbitrary tool-table
      keys to both `BackendListVersions` and `BackendInstall` as `ctx.options`,
      with `version` correctly stripped out
      (`{"repo":"helm-unittest/helm-unittest","extra":"xyz"}`). `PLUGIN.tools`
      is now a shorthand, not a gate.

- [x] **`ResolveRepo` / `ResolveRepoUrl` use `:` but never touch `self`** —
      converted to plain `.` functions as part of the same change, since they
      grew a second parameter anyway.

- [ ] **`metadata.lua` carries metadata + registry data + resolution logic.**
      If mise supports plugin-local `lib/` modules, the registry belongs there.

## Docs

- [ ] **Split PLAN.md.** It's two documents in one. §3 — the measured account
      of why `BackendExecEnv` can't do activation, with the three numbered
      constraints — is genuinely valuable and the README rightly points at it.
      The milestone checklist wrapped around it is a completed project tracker
      that git history already records, and it's drifting: milestones 5 and 7
      are done but unmarked, and the final open question (whether `--version`
      works cleanly for all target plugins) is still listed as open despite
      both supported plugins now being verified.

      Suggested: `DESIGN.md` keeps §3 and the measurements (including the new
      `cmd.exec` env finding); the tracker goes away.

- [ ] **The four-line `mise.toml` snippet is duplicated in six places** —
      README, PLAN, both examples, three test scripts, plus the error message
      in `bin/helm-plugins-sync:19-26`. The test scripts have to build it
      themselves, but the README could point at `example/1/mise.toml` as the
      single canonical copy rather than restating it.

- [ ] **No LICENSE file** though `metadata.lua:11` declares `license = "MIT"`.

- [x] **`homepage` is unverified** — was `https://github.com/staffan/...`,
      but the handle is `prtzb`. Corrected 2026-09-02 once the remote was added,
      along with `author` ("staffan" -> "Staffan Linnaeus", matching the git
      identity) and a new README "Install" section, which the repo had been
      missing entirely — there was no documented way for a consumer to install
      the plugin itself, only the local `mise plugin link` dev path.

- [ ] **`CLAUDE.md` is a bare title.** The dev/test commands from the README's
      Development section are what belong in it.

## Not problems (recorded so they don't get re-litigated)

- The `helm-plugins-sync` read loop uses a herestring, not a pipe, so
  `wanted+=` and `broken=1` correctly persist into the parent shell.
- Empty `$active` is handled: the herestring yields one blank line, caught by
  `[ -n "$tool" ] || continue`.
- The design quality is high and worth preserving through any refactor: the
  `BackendExecEnv` investigation is measured rather than assumed, the negative
  control in `test-activate-hook` (proving the test doesn't pass vacuously) is
  the kind of thing most people skip, the `--all` comment in `mise.toml:20`
  shows the same instinct, and delegating to `helm plugin install` rather than
  reimplementing it is the right call.

## Done — first batch (2026-09-02)

1. **Symlink guard** in `bin/helm-plugins-sync`, plus a `stray-dir` case in
   `test-sync-hardening`. Negative control run: with the guard stubbed out to
   `if false`, the new case fails on both assertions (exit code and the
   pollution check), so it isn't passing vacuously.
2. **`cmd.exec` env simplification** — `backend_install.lua` now passes only
   `HELM_PLUGINS`, with the measurement recorded in place of the hedge.
   Verified end-to-end by uninstalling `helm-plugin:helm-diff@3.9.0` and
   letting `test-activation` reinstall it through the new code path.
3. **`@type` annotations** on all seven requires (not five — three in
   `backend_install`, three in `backend_list_versions`, one in
   `backend_exec_env`), plus `file.glob` and `http.try_get` added to the stubs.
4. **shellcheck** added to `hk.pkl` (`glob = "{bin,mise-tasks}/*"`) and
   `shellcheck = "latest"` to `[tools]` so CI has it. The two pre-existing
   SC2012 findings were fixed by replacing `ls "$target"` with a `find`
   pipeline in both test scripts.

**Bonus finding, fixed:** turning on real type checking immediately caught a
nil-safety gap that had been invisible. `http.try_get` is typed
`HttpResponse?, string?`, and `backend_list_versions.lua` checked only `err`
before dereferencing `resp.status_code`. Correlated in practice, but a
hypothetical `(nil, nil)` would have surfaced as an "index a nil value"
traceback instead of the intended message. Now `if err or not resp then`.
This is the concrete payoff for item 3 — the stubs stopped being decorative
and found a bug on their first real run.

All three test tasks pass (`test-activation`, `test-sync-hardening`,
`test-activate-hook`), and `mise run lint` is green across all four steps.

## Done — CI batch (2026-09-02)

1. **`MISE_DATA_DIR` isolation** in `test-sync-hardening`. The corruption case
   now mutates only the test's own scratch installs; the backup/restore dance
   in `cleanup()` is gone with it, since the whole data dir is disposable.
   Cheaper than feared — the full run is ~10s, because downloads still come
   from the shared `MISE_CACHE_DIR` and only extraction repeats. Verified the
   real `~/.local/share/mise` copy of helm-secrets is untouched afterwards and
   no `.bak` directories survive.
2. **`sed -i ''` replaced** with a portable `grep -v` + `mv`, unblocking Linux.
   Swept the rest of the shell for GNU/BSD divergence (`readlink -f`,
   `stat -f/-c`, `find -printf`, `grep -P`, `sort -V`) — nothing else found.
3. **`[tasks.test]` aggregate**, running the three tests *sequentially* via
   `run` rather than in parallel via `depends`. They all call
   `mise plugin link --force helm-plugin` against the same global path and two
   install into the shared data dir, so parallel execution was a latent
   intermittent failure. Whole suite is ~8s.
4. **CI workflow** now has a `test` job alongside `lint`, both on the
   ubuntu/macos matrix, with `fail-fast: false` on `test` so one OS can't mask
   the other — the point of running both is catching exactly the GNU/BSD
   divergence fixed in (2). `[tasks.ci]` stays lint-only and hermetic so it's
   still fast to run locally; the stale `test-env-merge` comment is replaced
   with an explanation of that split.
5. **Orphaned state dirs** — `test-activation` now collects each project's
   `HELM_PLUGINS` path as it visits and removes them on exit. Verified the two
   dirs from the latest run are gone.
6. **`jq` added to `[tools]`**, so CI doesn't depend on the runner image
   happening to ship it. **README Development section** updated for
   `mise run test`, the shellcheck addition, and the scratch-data-dir note.

All three tests and all four lint steps pass.

### Housekeeping

`~/.local/state/helm-plugins/` currently holds ~9 orphans from test runs
predating fix (5) — `a-*`, `b-*`, `tmp.*`. All safe to `rm -rf`; the `1-*` and
`2-*` entries belong to `example/1` and `example/2` and should stay.

## Done — registry refactor (2026-09-02)

`PLUGIN.tools` is a shorthand rather than a gate: any GitHub-hosted plugin can
be named inline with `repo = "owner/repo"`. `ResolveRepo(tool, options)` takes
the option first, falls back to the built-in map, and validates the slug shape
so a full URL is rejected up front rather than installing and then failing to
resolve a version.

Verified before writing any code that mise really does forward arbitrary tool
options to the hooks; then end to end, that a name absent from `PLUGIN.tools`
installs, links, and is picked up by helm. `test-activation` gained a third
project reaching helm-diff purely through the inline option, plus assertions on
both error messages. Aimed at helm-diff rather than a genuinely new dependency
on purpose: helm-unittest's current releases use a `platformHooks` field that
neither helm 3.21 nor helm 4.2 understands, so it would have made the test fail
for reasons unrelated to resolution.

**Two things this turned up, both fixed or documented:**

- **The tests depended on ambient trust state.** An untrusted config with
  `[env]`/`[hooks]` doesn't parse at all, and the generated temp configs were
  only working because this machine had 66 stale trust entries from earlier
  runs. A clean CI runner has none, so the new `test` job would likely have
  failed on its first run. All three tests now `mise trust` explicitly at every
  point they write or rewrite a config — trust is recorded per content, so a
  rewrite needs re-trusting. Confirmed by deleting the stale entries and
  re-running the suite green.
- **The tool name is the identity, not the repo.** Install paths are
  `helm-plugin-<tool>/<version>`, with no repo component. Measured: project x
  pinned `samename@3.9.0` -> helm-diff, project y pinned the same name and
  version -> helm-secrets, and y was told "all tools are installed" while
  silently getting helm-diff. Not fixable from inside the plugin; documented
  under Known limitations in the README.

### Next up

Nothing below this line is started. Remaining, roughly by value: the PLAN.md
split, then the small stuff (dotglob, prerelease comment, LICENSE, CLAUDE.md).
