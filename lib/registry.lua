-- Which GitHub repo a helm plugin name refers to. mise puts <plugin>/lib on
-- package.path, so hooks reach this as `require("registry")`.

--- @class registry
local M = {}

--- Built-in shorthands: short name -> GitHub repo. Deliberately small — any
--- other GitHub-hosted plugin can be named inline with a `repo` option.
--- @type table<string, {repo: string}>
M.tools = {
    ["helm-diff"] = { repo = "databus23/helm-diff" },
    ["helm-secrets"] = { repo = "jkroepke/helm-secrets" },
}

--- "owner/repo" — the form the GitHub tags API needs. A URL is rejected rather
--- than normalised: version listing only works against GitHub, so a plugin
--- hosted elsewhere would install and then fail to resolve a version.
local REPO_PATTERN = "^[%w._-]+/[%w._-]+$"

--- Resolves a short tool name to its "owner/repo" GitHub slug. A project can
--- name a plugin that isn't built in by passing `repo` inline, which mise
--- forwards to the hooks as ctx.options:
---
---     "helm-plugin:helm-unittest" = { version = "0.9.2", repo = "helm-unittest/helm-unittest" }
---
--- @param tool string Tool name as written in mise.toml, e.g. "helm-diff"
--- @param options table|nil ctx.options from the calling hook
--- @return string repo The "owner/repo" slug
function M.resolve_repo(tool, options)
    if not tool or tool == "" then
        error("Tool name cannot be empty")
    end

    local repo = options and options.repo
    if repo and repo ~= "" then
        if not repo:match(REPO_PATTERN) then
            error(
                string.format(
                    'invalid repo %q for %q: expected an "owner/repo" GitHub slug, e.g. "databus23/helm-diff"',
                    repo,
                    tool
                )
            )
        end
        return repo
    end

    local entry = M.tools[tool]
    if entry then
        return entry.repo
    end

    local known = {}
    for name, _ in pairs(M.tools) do
        table.insert(known, name)
    end
    table.sort(known)
    error(
        string.format(
            "unknown helm plugin %q. Built in: %s. For any other GitHub-hosted plugin, "
                .. 'name the repo inline: "helm-plugin:%s" = { version = "...", repo = "owner/%s" }',
            tool,
            table.concat(known, ", "),
            tool,
            tool
        )
    )
end

--- Where helm should install a plugin from.
---
--- By default that's the repo itself, which helm clones and checks out at the
--- requested version. A project can instead name a release asset, for plugins
--- published as archives rather than installable from a checkout:
---
---     "helm-plugin:helm-secrets-getter" = {
---         version = "4.7.7",
---         repo = "jkroepke/helm-secrets",
---         asset = "secrets-getter-{version}.tgz",
---     }
---
--- `{version}` expands to the pinned version. Single braces, because mise runs
--- config values through its own templating first and rewrites `{{version}}` to
--- `{version}` on the way (measured 2026-09-09) — both spellings are accepted
--- here for that reason. A bare name is resolved against the repo's release for
--- tag `v<version>`; an asset given as a full https URL is used as-is, for
--- releases that tag differently or host elsewhere.
--- @param tool string Tool name as written in mise.toml, e.g. "helm-diff"
--- @param version string The pinned version, e.g. "4.7.7"
--- @param options table|nil ctx.options from the calling hook
--- @return {kind: "git"|"asset", url: string}
function M.resolve_source(tool, version, options)
    local repo = M.resolve_repo(tool, options)

    local asset = options and options.asset
    if not asset or asset == "" then
        return { kind = "git", url = "https://github.com/" .. repo }
    end
    if not version or version == "" then
        error(string.format("asset for %q needs a version to expand", tool))
    end

    -- Double braces first: the single-brace pattern would otherwise match the
    -- inside of one and leave the outer pair behind.
    local url = asset:gsub("{{%s*version%s*}}", version):gsub("{%s*version%s*}", version)
    if not url:match("^https://") then
        if url:match("/") then
            error(
                string.format(
                    'invalid asset %q for %q: expected a release asset filename, e.g. "secrets-getter-{{version}}.tgz", or a full https URL',
                    asset,
                    tool
                )
            )
        end
        url = string.format("https://github.com/%s/releases/download/v%s/%s", repo, version, url)
    end

    return { kind = "asset", url = url }
end

return M
