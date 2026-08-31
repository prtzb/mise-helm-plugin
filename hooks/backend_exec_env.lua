--- Puts bin/helm-plugins-sync on PATH. Does NOT set HELM_PLUGINS.
--- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendexecenv
--- @param ctx {tool: string, version: string, install_path: string, options: table} Context
--- @return {env_vars: {key: string, value: string}[]}

local file = require("file")

-- This hook cannot do activation. Two measured constraints rule it out — see
-- PLAN.md §3:
--
--   1. mise does not merge same-key env_vars across tools. With two
--      helm-plugin:* tools active, HELM_PLUGINS held only one of them.
--   2. mise caches this hook's output per tool@version. It does not re-run on
--      cd, and its return value therefore cannot depend on the project — a
--      value computed in one project leaks into every other project pinning the
--      same version.
--
-- Activation instead happens in bin/helm-plugins-sync, driven by the consuming
-- project's [env] HELM_PLUGINS and [hooks] enter. See the README.
--
-- What this hook CAN usefully do is put that script on PATH, so projects can
-- write `enter = "helm-plugins-sync"` instead of hardcoding a path into mise's
-- data directory. Unlike HELM_PLUGINS this is sound: PATH is the one key mise
-- merges across tools, and the value depends only on the plugin's own location,
-- so caching it per tool@version is harmless.
function PLUGIN:BackendExecEnv(ctx) -- luacheck: ignore ctx
    return {
        env_vars = {
            { key = "PATH", value = file.join_path(RUNTIME.pluginDirPath, "bin") },
        },
    }
end
