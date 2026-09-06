-- Installs a helm plugin by delegating to `helm plugin install`.
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendinstall

--- @type cmd
local cmd = require("cmd")
--- @type file
local file = require("file")
--- @type log
local log = require("log")
local registry = require("registry")

--- POSIX single-quote escaping, for the few places a shell string is unavoidable.
--- @param s string
--- @return string
local function shq(s)
    return "'" .. s:gsub("'", [['\'']]) .. "'"
end

--- Absolute path to helm, or nil if mise can't resolve one.
---
--- The install must not run through a mise shim. A shim is mise re-execing the
--- real binary, and on the way it re-applies the project's `[env]` over the
--- environment it was given — including the HELM_PLUGINS a consuming project
--- sets. helm would then install into the project's plugin directory instead of
--- this tool's install path, and report success either way.
--- @return string|nil
local function mise_which_helm()
    local ok, out = pcall(cmd.exec, "mise which helm")
    if not ok or not out then
        return nil
    end
    local path = tostring(out):gsub("%s+$", "")
    return path ~= "" and path or nil
end

--- Whether the current config pins helm, installed or not. `mise ls --current`
--- lists it as "(missing)" when it's declared but absent, and prints nothing at
--- all when no config mentions it.
--- @return boolean
local function helm_is_pinned()
    local ok, out = pcall(cmd.exec, "mise ls --current --offline helm 2>/dev/null")
    return ok and out ~= nil and tostring(out):match("%S") ~= nil
end

--- The helm to both probe and install with.
---
--- PATH's helm is often neither the one the project pins nor safe to use: this
--- hook inherits the ambient PATH rather than the project's tools, so what it
--- finds there is a system helm of some other major, a shim, or on a macOS CI
--- runner nothing at all.
--- @return string
local function resolve_helm()
    local path = mise_which_helm()
    if path then
        return path
    end

    -- mise installs tools in parallel with no way to declare a dependency, so a
    -- project's helm is usually still installing when this hook starts. Asking
    -- for it again blocks until that finishes rather than racing it. Gated on
    -- the pin: without one this would install a helm nobody asked for, when the
    -- right answer is the system helm already on PATH.
    if helm_is_pinned() then
        pcall(cmd.exec, "mise install helm")
        path = mise_which_helm()
        if path then
            return path
        end
    end

    return "helm"
end

--- @param ctx {tool: string, version: string, install_path: string, download_path: string, options: table} Context
--- @return table Empty table on success
function PLUGIN:BackendInstall(ctx)
    local tool = ctx.tool
    local version = ctx.version
    local install_path = ctx.install_path

    if not version or version == "" then
        error("Version cannot be empty")
    end
    if not install_path or install_path == "" then
        error("Install path cannot be empty")
    end

    local repo_url = registry.resolve_repo_url(tool, ctx.options)
    local plugins_dir = file.join_path(install_path, "plugins")

    -- helm's installer expects HELM_PLUGINS to exist.
    cmd.exec("mkdir -p " .. shq(plugins_dir))

    -- Delegate to helm's own installer rather than reimplementing it: it knows
    -- about platform-specific archives and plugin.yaml install hooks.
    --
    -- cmd.exec's `env` merges with the inherited environment, so HELM_PLUGINS is
    -- the only key worth setting — PATH, HOME and the proxy and TLS variables
    -- git needs all come through on their own.
    local env = { HELM_PLUGINS = plugins_dir }

    -- One binary for both the probe and the install below. helm 4 verifies
    -- plugin signatures by default and refuses every git source, helm 3 has no
    -- --verify flag at all, and probing a different helm than the one doing the
    -- install gets that flag wrong in whichever direction they disagree.
    local helm = shq(resolve_helm())

    local verify_flag = ""
    local ok_version, version_out = pcall(cmd.exec, helm .. " version --short", { env = env })
    if ok_version then
        local major = tonumber(tostring(version_out):match("v(%d+)%."))
        if major and major >= 4 then
            verify_flag = " --verify=false"
        end
        log.debug("helm version: " .. tostring(version_out) .. " (major " .. tostring(major) .. ")")
    else
        log.warn("could not determine helm version, assuming helm 3: " .. tostring(version_out))
    end

    local install_cmd =
        string.format("%s plugin install %s --version %s%s", helm, shq(repo_url), shq(version), verify_flag)

    log.debug("running: " .. install_cmd .. " (HELM_PLUGINS=" .. plugins_dir .. ")")

    local ok, result = pcall(cmd.exec, install_cmd, { env = env })

    if not ok then
        error(string.format("helm plugin install failed for %s@%s: %s", tool, version, tostring(result)))
    end

    -- Check something actually landed, rather than leaving a half-installed
    -- version that mise records as successful. The directory is named after
    -- plugin.yaml's `name`, which need not match `tool`.
    local manifests = file.glob(file.join_path(plugins_dir, "*", "plugin.yaml"))
    if #manifests == 0 then
        error(
            string.format(
                "helm plugin install reported success for %s@%s but no plugin.yaml was found under %s. "
                    .. "If helm ran through a mise shim, HELM_PLUGINS was overridden and the plugin landed "
                    .. "in the project's plugin directory instead. Output: %s",
                tool,
                version,
                plugins_dir,
                tostring(result)
            )
        )
    end

    log.debug(string.format("installed %s@%s -> %s", tool, version, manifests[1]))

    return {}
end
