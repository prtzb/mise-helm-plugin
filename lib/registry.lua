-- Which GitHub repo a helm plugin name refers to, and how a project can say so
-- itself. Split out of metadata.lua so that file stays what its name promises:
-- the plugin's own manifest.
--
-- mise puts <plugin>/lib on package.path alongside the plugin root and hooks/
-- (measured 2026-09-03), so this is `require("registry")` from a hook.

--- @class registry
local M = {}

--- Built-in shorthands: short name -> GitHub repo. Deliberately small. Any
--- other GitHub-hosted plugin can be named inline with a `repo` option, so this
--- only needs to cover the ones worth spelling shortly.
--- @type table<string, {repo: string}>
M.tools = {
    ["helm-diff"] = { repo = "databus23/helm-diff" },
    ["helm-secrets"] = { repo = "jkroepke/helm-secrets" },
}

--- "owner/repo" — the form the GitHub tags API needs. A full URL is rejected
--- rather than quietly normalised: BackendListVersions can only enumerate
--- versions for a GitHub repo, so a plugin hosted anywhere else would install
--- and then fail to resolve a version, which is a worse place to find out.
local REPO_PATTERN = "^[%w._-]+/[%w._-]+$"

--- Resolves a short tool name to its "owner/repo" GitHub slug.
---
--- A project can name a plugin that isn't built in by passing `repo` inline;
--- mise forwards it to every hook as ctx.options (measured 2026-09-02):
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

--- Resolves a short tool name to the git URL helm's installer clones from.
--- @param tool string Tool name as written in mise.toml, e.g. "helm-diff"
--- @param options table|nil ctx.options from the calling hook
--- @return string url
function M.resolve_repo_url(tool, options)
    return "https://github.com/" .. M.resolve_repo(tool, options)
end

return M
