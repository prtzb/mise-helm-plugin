-- metadata.lua
-- Backend plugin metadata and configuration
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html

PLUGIN = { -- luacheck: ignore
    name = "helm-plugin",
    version = "0.1.0",
    description = "A mise backend plugin for installing helm plugins (helm-diff, helm-secrets, ...)",
    author = "Staffan Linnaeus",
    homepage = "https://github.com/prtzb/mise-helm-plugin",
    license = "MIT",
    notes = {
        "Requires `helm` on PATH before any helm-plugin: tool is installed",
        "Requires `git`, which helm's own plugin installer shells out to",
    },
}

--- Built-in shorthands: short name -> GitHub repo. Deliberately small. Any
--- other GitHub-hosted plugin can be named inline with a `repo` option, so this
--- only needs to cover the ones worth spelling shortly.
--- @type table<string, {repo: string}>
PLUGIN.tools = {
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
function PLUGIN.ResolveRepo(tool, options)
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

    local entry = PLUGIN.tools[tool]
    if entry then
        return entry.repo
    end

    local known = {}
    for name, _ in pairs(PLUGIN.tools) do
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
function PLUGIN.ResolveRepoUrl(tool, options)
    return "https://github.com/" .. PLUGIN.ResolveRepo(tool, options)
end
