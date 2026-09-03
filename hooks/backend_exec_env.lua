-- Puts bin/helm-plugins-sync on PATH and announces this tool's install path.
-- Does NOT set HELM_PLUGINS.
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendexecenv

--- @type file
local file = require("file")

-- Prefix for the per-tool variables helm-plugins-sync reads. Not MISE_*, which
-- mise's zsh activation fingerprints with `typeset +m`, and not HELM_PLUGIN_*,
-- which is helm's own namespace.
local SRC_PREFIX = "HELM_PLUGINS_SYNC_"

-- This hook cannot set HELM_PLUGINS itself: mise doesn't merge same-key
-- env_vars across tools, and it caches the hook per tool@version, so the value
-- can't depend on the project (DESIGN.md §3). Both variables below stay inside
-- those limits — distinct keys do merge, and neither value depends on anything
-- but (tool, version). helm-plugins-sync assembles the directory from them.
--- @param ctx {tool: string, version: string, install_path: string, options: table} Context
--- @return {env_vars: {key: string, value: string}[]}
function PLUGIN:BackendExecEnv(ctx)
    -- Variable names can't hold every character a tool name can, so the name is
    -- carried in the value rather than recovered from the key.
    local key = SRC_PREFIX .. ctx.tool:gsub("%W", "_")

    return {
        env_vars = {
            { key = "PATH", value = file.join_path(RUNTIME.pluginDirPath, "bin") },
            { key = key, value = ctx.tool .. "\t" .. ctx.install_path },
        },
    }
end
