-- Backend plugin manifest. Repo resolution lives in lib/registry.lua.
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
