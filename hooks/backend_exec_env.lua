-- Puts bin/helm-plugins-sync on PATH and announces this tool's install path.
-- Does NOT set HELM_PLUGINS.
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendexecenv

--- @type file
local file = require("file")

-- Prefix for the per-tool variables helm-plugins-sync reads. Deliberately not
-- MISE_*, which mise's own zsh activation fingerprints with `typeset +m`, and
-- not HELM_PLUGIN_*, which is helm's namespace for the variables it passes to a
-- running plugin.
local SRC_PREFIX = "HELM_PLUGINS_SYNC_"

-- This hook cannot set HELM_PLUGINS itself. Two measured constraints rule it
-- out — see DESIGN.md §3:
--
--   1. mise does not merge *same-key* env_vars across tools. With two
--      helm-plugin:* tools active, HELM_PLUGINS held only one of them.
--   2. mise caches this hook's output per tool@version. It does not re-run on
--      cd, and its return value therefore cannot depend on the project — a
--      value computed in one project leaks into every other project pinning the
--      same version.
--
-- Both of those are survivable if you stay inside them, which is what the two
-- variables below do. Constraint 1 is specifically about key *collisions*:
-- distinct keys merge fine, so one variable per tool reaches the shell intact
-- (measured 2026-09-02 with three tools active). Constraint 2 is about values
-- that depend on the project, and neither of these does — the plugin's own bin
-- directory and the tool's install path are both pure functions of things mise
-- already keys the cache on.
--
-- That gives helm-plugins-sync the active set without shelling out to
-- `mise ls --current --json` and parsing it with jq. mise unsets the variables
-- on the way out of a project, so the set is always exactly what's active here.
--- @param ctx {tool: string, version: string, install_path: string, options: table} Context
--- @return {env_vars: {key: string, value: string}[]}
function PLUGIN:BackendExecEnv(ctx)
    -- Environment variable names can't hold every character a tool name can, so
    -- the name is carried in the value rather than recovered from the key.
    local key = SRC_PREFIX .. ctx.tool:gsub("%W", "_")

    return {
        env_vars = {
            { key = "PATH", value = file.join_path(RUNTIME.pluginDirPath, "bin") },
            { key = key, value = ctx.tool .. "\t" .. ctx.install_path },
        },
    }
end
