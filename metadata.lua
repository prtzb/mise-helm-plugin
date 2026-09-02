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

--- Registry of supported helm plugins: short name -> GitHub repo.
--- Deliberately small — this is not a general-purpose registry of every helm
--- plugin in existence. Add entries as projects actually need them.
--- @type table<string, {repo: string}>
PLUGIN.tools = {
    ["helm-diff"] = { repo = "databus23/helm-diff" },
    ["helm-secrets"] = { repo = "jkroepke/helm-secrets" },
}

--- Resolves a short tool name to its "owner/repo" GitHub slug.
--- @param tool string Tool name as written in mise.toml, e.g. "helm-diff"
--- @return string repo The "owner/repo" slug
function PLUGIN:ResolveRepo(tool)
    if not tool or tool == "" then
        error("Tool name cannot be empty")
    end

    local entry = PLUGIN.tools[tool]
    if not entry then
        local known = {}
        for name, _ in pairs(PLUGIN.tools) do
            table.insert(known, name)
        end
        table.sort(known)
        error(
            string.format(
                "unknown helm plugin %q. Supported: %s. Add it to PLUGIN.tools in metadata.lua.",
                tool,
                table.concat(known, ", ")
            )
        )
    end

    return entry.repo
end

--- Resolves a short tool name to the git URL helm's installer clones from.
--- @param tool string Tool name as written in mise.toml, e.g. "helm-diff"
--- @return string url
function PLUGIN:ResolveRepoUrl(tool)
    return "https://github.com/" .. PLUGIN:ResolveRepo(tool)
end
