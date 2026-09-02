-- Lists available versions for a helm plugin by reading its GitHub tags.
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendlistversions

--- @type http
local http = require("http")
--- @type json
local json = require("json")
--- @type semver
local semver = require("semver")

-- GitHub caps per_page at 100; a few pages is plenty for any helm plugin.
local PER_PAGE = 100
local MAX_PAGES = 5

--- Normalizes a git tag into a bare version string, or nil if it isn't one.
--- @param name string
--- @return string|nil
local function normalize_tag(name)
    if not name or name == "" then
        return nil
    end

    local version = name:gsub("^v", "")

    -- Ignore tags that aren't recognisable versions (e.g. "latest", "release-2020").
    if not version:match("^%d+%.%d+") then
        return nil
    end

    return version
end

--- @return table<string, string> headers
local function github_headers()
    local headers = {
        ["Accept"] = "application/vnd.github+json",
        ["User-Agent"] = "mise-helm-plugin",
    }

    -- Unauthenticated GitHub API allows 60 req/hr, which `mise ls-remote` can
    -- burn through quickly. Use a token when one is present.
    local token = os.getenv("GITHUB_TOKEN") or os.getenv("GITHUB_API_TOKEN")
    if token and token ~= "" then
        headers["Authorization"] = "Bearer " .. token
    end

    return headers
end

--- @param ctx {tool: string, options: table} Context
--- @return {versions: string[]} Available versions, ascending
function PLUGIN:BackendListVersions(ctx)
    local tool = ctx.tool
    local repo = PLUGIN:ResolveRepo(tool)
    local headers = github_headers()

    local versions = {}

    for page = 1, MAX_PAGES do
        local url = string.format("https://api.github.com/repos/%s/tags?per_page=%d&page=%d", repo, PER_PAGE, page)

        -- try_get signals failure as (nil, err), so `err` alone ought to be
        -- enough — but checking `resp` too keeps a hypothetical (nil, nil) from
        -- surfacing as an "index a nil value" traceback instead of this message.
        local resp, err = http.try_get({ url = url, headers = headers })
        if err or not resp then
            error(string.format("failed to fetch tags for %s from %s: %s", tool, repo, err or "no response"))
        end
        if resp.status_code ~= 200 then
            error(string.format("GitHub API returned status %d for %s (%s)", resp.status_code, tool, repo))
        end

        local tags = json.decode(resp.body)
        if #tags == 0 then
            break
        end

        for _, tag in ipairs(tags) do
            local version = normalize_tag(tag.name)
            if version then
                table.insert(versions, version)
            end
        end

        -- Short page means we've reached the end.
        if #tags < PER_PAGE then
            break
        end
    end

    if #versions == 0 then
        error(string.format("no versions found for %s (%s)", tool, repo))
    end

    return { versions = semver.sort(versions) }
end
