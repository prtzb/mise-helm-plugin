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

--- Resolves a short tool name to the git URL helm's installer clones from.
--- @param tool string Tool name as written in mise.toml, e.g. "helm-diff"
--- @param options table|nil ctx.options from the calling hook
--- @return string url
function M.resolve_repo_url(tool, options)
    return "https://github.com/" .. M.resolve_repo(tool, options)
end

return M
