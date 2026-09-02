-- Installs a helm plugin by delegating to `helm plugin install`.
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendinstall

--- @type cmd
local cmd = require("cmd")
--- @type file
local file = require("file")
--- @type log
local log = require("log")

--- POSIX single-quote escaping, for the few places a shell string is unavoidable.
--- @param s string
--- @return string
local function shq(s)
    return "'" .. s:gsub("'", [['\'']]) .. "'"
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

    local repo_url = PLUGIN:ResolveRepoUrl(tool)
    local plugins_dir = file.join_path(install_path, "plugins")

    -- helm's installer expects HELM_PLUGINS to exist.
    cmd.exec("mkdir -p " .. shq(plugins_dir))

    -- Deliberately NOT reimplementing helm's plugin installer: helm handles
    -- platform-specific archives and plugin.yaml install hooks (make, go build,
    -- prebuilt binary downloads), and we inherit correctness from it.
    --
    -- HELM_PLUGINS is passed structurally via cmd.exec's env option rather than
    -- prefixed onto a shell command line, so there's nothing to quote.
    --
    -- cmd.exec's `env` merges with the inherited environment rather than
    -- replacing it (measured 2026-09-01: a variable set only in the calling
    -- shell was visible to the command, and PATH arrived at full length). So
    -- HELM_PLUGINS is the only key worth setting — PATH and HOME, plus the
    -- proxy and TLS variables git needs, all come through on their own.
    local env = { HELM_PLUGINS = plugins_dir }

    -- helm 4 verifies plugin signatures by default and refuses any git source
    -- with "plugin source does not support verification", which is every plugin
    -- we install. helm 3 has no --verify flag at all, so the flag has to be
    -- conditional on the helm actually being used — which is whichever one PATH
    -- resolves to, and differs between an activated and non-activated shell.
    local verify_flag = ""
    local ok_version, version_out = pcall(cmd.exec, "helm version --short", { env = env })
    if ok_version then
        local major = tonumber(tostring(version_out):match("v(%d+)%."))
        if major and major >= 4 then
            verify_flag = " --verify=false"
        end
        log.debug("helm version: " .. tostring(version_out) .. " (major " .. tostring(major) .. ")")
    else
        log.warn("could not determine helm version, assuming helm 3: " .. tostring(version_out))
    end

    local install_cmd = string.format("helm plugin install %s --version %s%s", shq(repo_url), shq(version), verify_flag)

    log.debug("running: " .. install_cmd .. " (HELM_PLUGINS=" .. plugins_dir .. ")")

    local ok, result = pcall(cmd.exec, install_cmd, { env = env })

    if not ok then
        error(string.format("helm plugin install failed for %s@%s: %s", tool, version, tostring(result)))
    end

    -- helm names the directory after the `name` field in plugin.yaml, which is
    -- not necessarily `tool` and never the version. Verify something actually
    -- landed rather than leaving a half-installed version that mise records as
    -- successful.
    local manifests = file.glob(file.join_path(plugins_dir, "*", "plugin.yaml"))
    if #manifests == 0 then
        error(
            string.format(
                "helm plugin install reported success for %s@%s but no plugin.yaml was found under %s. Output: %s",
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
