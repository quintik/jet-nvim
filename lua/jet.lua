--- Jet

local fn = vim.fn

-- List of all plugins.
local registry = {}

-- Path to pack dir.
-- Note that jet_packpath must also be added
-- to vim's packpath variable by the user.
local pack_path = (vim.g.jet_packpath or fn.stdpath('config')) .. "/pack/"

--- UTIL FUNCTIONS

-- Joins two lists together.
local function list_join(a, b)
    local joint = {}
    for _, v in ipairs(a) do
        joint[#joint + 1] = v
    end
    for _, v in ipairs(b) do
        joint[#joint + 1] = v
    end
    return joint
end

-- Returns first item that evalutes
-- to true when `f` is applied.
local function list_find(list, f)
    for _, v in ipairs(list) do
        if f(v) then return v end
    end
end

-- Returns plugin matching `name`.
local function find_plugin(name)
    return list_find(registry, function(p) return p.name == name end)
end

-- Path to `pack`'s start/opt dir.
local function get_path(opt, pack)
    return pack_path .. pack .. "/" .. opt .. "/"
end


--- ERROR HANDLING

-- Jet errors.
local errs = {
    [11] = "entries must be either strings or tables.",
    [12] = "'uri' field is required for all table entries.",
    [20] = "'git' not found. Some commands may not work."
}

-- Get formatted error string from error code.
local function get_err_str(code)
    return "Jet E" .. code .. ": " .. errs[code]
end

-- Logs error message with error highlighting.
local function echo_err(code)
    vim.cmd("echohl Error")
    vim.cmd("echom '" .. get_err_str(code) .. "'")
    vim.cmd("echohl None")
end


--- JET BUFFER

-- Sets window/buffer options
-- and header for the jet buffer.
local function prep_jet_buf()
    vim.cmd("setfiletype Jet")

    vim.bo.bufhidden = "hide"
    vim.bo.buftype = "nofile"
    vim.bo.swapfile = false
    vim.bo.buflisted = false
    vim.bo.syntax = "markdown"
    vim.wo.statusline = "%= Jet %="

    fn.setline(1, "# Jet")
    fn.setline(2, "")
end

-- Opens a custom buffer for Jet.
local function open_jet_buf()
    local winnr = fn.bufwinnr("Jet")

    -- Return if buffer window is already open.
    if winnr == fn.winnr() then
        return
    elseif winnr < 0 then
        -- First, store if the buffer already existed.
        local existed = fn.bufnr("Jet") > 0
        -- Get the bufnr, creating it if it didn't already exist.
        local bufnr = fn.bufnr("Jet", 1)
        -- Open a window and load the buffer.
        vim.cmd("vertical topleft new | b" .. bufnr)
        -- Prepare buffer if new one was created.
        if not existed then
            prep_jet_buf()
        end
    else
        -- If buf window was already open, switch to it.
        fn.execute(winnr .. "wincmd w")
    end
end


--- LOGGING

-- Logs to the custom Jet buffer. Takes
-- multiple args, each logged to a new line.
local function log(...)
    open_jet_buf()
    vim.opt_local.modifiable = true

    local args = {...}
    for _, val in ipairs(args) do
        fn.append(fn.line("$"), val)
    end

    vim.opt_local.modifiable = false
end

-- Remember line numbers for logs.
local log_lines = {}

-- Logs to a fixed line, based on it's id.
local function log_to(id, text)
    open_jet_buf()
    vim.opt_local.modifiable = true

    local str = "<" .. id .. "> " .. text

    local line_nr = log_lines[id]
    if line_nr == nil then
        -- Get the last line of the buffer.
        line_nr = fn.line("$")
        -- Store the line nr + 1, since append
        -- writes to the line below.
        log_lines[id] = line_nr + 1
        fn.append(line_nr, str)
    else
        fn.setline(line_nr, str)
    end

    vim.opt_local.modifiable = false
end

-- Clear previous contents of Jet buf
-- and reset log_lines.
local function clear_jet_buf()
    open_jet_buf()

    vim.opt_local.modifiable = true
    fn.deletebufline("Jet", 2, fn.line("$"))
    vim.opt_local.modifiable = false

    log_lines = {}
end


--- OPTSYNCING

-- Check if a plugin is optsynced. We consider a plugin
-- optsynced if its .git/HEAD file is readable in the
-- directory specified by `plugin.dir`. If .git/HEAD is
-- readable in either the <pack>/start/<plugin> or
-- <pack>/opt/<plugin> dir, we consider it installed but not
-- optsynced. This function returns 1 for optsynced, 0 for
-- installed, and -1 otherwise.
local function is_optsynced(plugin)
    local found_synced = io.open(plugin.dir .. "/.git/HEAD", "r")
    if found_synced then
        io.close(found_synced)
        return 1
    end

    local alt_dir  = plugin.opt and "start" or "opt"
    local alt_path = get_path(alt_dir, plugin.pack) .. plugin.name
    local found_installed = io.open(alt_path .. "/.git/HEAD", "r")
    if found_installed then
        io.close(found_installed)
        return 0
    end

    return -1
end

-- Sync a plugin to it's appropriate opt/start
-- directory. Returns true if synced successfully,
-- otherwise false (meaning plugin is not installed).
local function optsync_plugin(plugin)
    local sync_status = is_optsynced(plugin)

    if sync_status == 1 then
        return true
    elseif sync_status == 0 then
        -- If it's an opt plugin, rename from startpath to
        -- current dir (i.e optpath), otherwise vice versa.
        if plugin.opt then
            local old = get_path("start", plugin.pack) .. plugin.name
            fn.mkdir(plugin.dir, "p")
            os.rename(old, plugin.dir)
        else
            local old = get_path("opt", plugin.pack) .. plugin.name
            fn.mkdir(plugin.dir, "p")
            os.rename(old, plugin.dir)
        end
        return true
    else
        return false
    end
end


--- PLUGIN-RELATED UTILS

-- Returns plugin name if provided by user,
-- otherwise obtains name from plugin uri.
local function get_plugin_name(plugin)
    if type(plugin) == "string" then
        -- Ignore .git extension at the end of the uri.
        local has_ext = string.match(plugin, "%.git$")
        local pat = has_ext and ".*/(.*).git$" or ".*/(.*)$"
        return string.match(plugin, pat)
    end

    -- If name isn't provided, recurse and use the uri.
    return plugin.name and plugin.name or get_plugin_name(plugin.uri)
end

-- Returns git process flags if provided by user,
-- otherwise the defaults.
local function get_plugin_flags(plugin)
    if type(plugin) == "string" or plugin.flags == nil then
        return { "--depth", "1" }
    end
    return plugin.flags
end

-- Loads a specific plugin and runs it's cfg function.
local function load_plugin(name)
    local plugin = find_plugin(name)
    vim.cmd("packadd " .. name)
    if plugin.cfg then plugin.cfg() end
end


--- LAZY LOADING

-- Initializes plugin's lazy loading autocmd.
local function init_lazy_load(plugin)
    if plugin.opt and plugin.on then
        local grp = "JetLazyLoad"
        local evt = table.concat(plugin.on, ",")
        local lst = plugin.pat and table.concat(plugin.pat, ",")
        local pat = lst or "*"

        local subcmd = "lua " .. "Jet.load('" .. plugin.name .. "')"
        local cmdlist = {"au", grp, evt, pat, "++once", subcmd}
        vim.cmd("augroup JetLazyLoad")
        vim.cmd(table.concat(cmdlist, " "))
    end
end


--- INIT PACK/PLUGIN

-- Initialize a plugin object, and
-- store it in the registry.
local function init_plugin(pack, data)
    local name  = get_plugin_name(data)
    local flags = get_plugin_flags(data)
    local uri   = (type(data) == 'string') and data or data.uri
    local opt   = (type(data.opt) == 'nil') and false or data.opt
    local dir   = pack_path .. pack .. (opt and "/opt/" or "/start/") .. name

    return {
        name  = name,
        pack  = pack,
        flags = flags,
        uri   = uri,
        opt   = opt,
        dir   = dir,
        on    = data.on,
        pat   = data.pat,
        cfg   = data.cfg
    }
end

-- Returns a function that takes a list of plugin configs,
-- adds them to the registry and initializes them.
local function init_pack(pack)
    local register_pack_plugins = function(list)
        for _, data in ipairs(list) do
            local data_t = type(data)
            if data_t ~= 'string' and data_t ~= 'table' then
                echo_err(11)
                return
            elseif data_t == "table" and data.uri == nil then
                echo_err(12)
                return
            else
                local plugin = init_plugin(pack, data)
                table.insert(registry, plugin)
                local optsynced = optsync_plugin(plugin)

                if plugin.opt then
                    init_lazy_load(plugin)
                elseif optsynced then
                    load_plugin(plugin.name)
                end
            end
        end
    end

    return register_pack_plugins
end


--- GIT SPAWN

-- Store handles for easy access.
local spawned_handles = {}

-- Spawn git process to update a plugin.
local function git_spawn(subcmd, plugin)
    local logid = plugin.pack .. ":" .. plugin.name
    -- To read command output.
    local stdout = vim.loop.new_pipe(false)
    local stderr = vim.loop.new_pipe(false)

    -- Wrap so that Nvim API can be called inside loop.
    local on_read = vim.schedule_wrap(function (err, data)
        if err then
            log_to(logid, err)
        elseif data then
            -- Ignore whitespace/newlines.
            local lines = string.gmatch(data, "%s*([^\r\n]*)%s*")
            for line in lines do
                -- Don't log empty lines.
                if string.match(line, "[^%s]") then
                    log_to(logid, line)
                end
            end
        end
    end)

    -- Prepare command.
    local cmdargs = { subcmd, plugin.uri, plugin.dir, "--progress" }
    local opts = {
        args = list_join(cmdargs, plugin.flags),
        detached = true,
        hide = true,
        stdio = {nil, stdout, stderr}
    }

    local on_exit = vim.schedule_wrap(function ()
        spawned_handles[plugin.uri]:close()
        stdout:close()
        stderr:close()
        log_to(logid, "Finished.")
    end)

    -- Run command and store handle to close later.
    local handle = vim.loop.spawn("git", opts, on_exit)
    spawned_handles[plugin.uri] = handle

    -- Start reading command output.
    vim.loop.read_start(stdout, on_read)
    vim.loop.read_start(stderr, on_read)
end


--- INSTALL

-- Spawns git process to install missing plugins.
-- If optional `pack` arg is given, only missing
-- plugins from that pack will be installed.
local function install_plugins(pack)
    clear_jet_buf()
    log("", "Install", "-------")

    local installed = 0
    for _, plugin in ipairs(registry) do
        if not pack or plugin.pack == pack then
            if not is_installed(plugin) then
                git_spawn("clone", plugin)
                installed = installed + 1
            end
        end
    end

    if installed == 0 then
        log("Nothing to install!")
    end
end


--- UPDATE

-- Spawns git process to update each plugin.
-- If optional `pack` arg is given, only plugins
-- from that pack will be installed.
local function update_plugins(pack)
    clear_jet_buf()
    log("", "Update", "------")

    for _, plugin in ipairs(registry) do
        if not pack or plugin.pack == pack then
            git_spawn("pull", plugin)
        end
    end
end


--- CLEAN PLUGINS

-- Cleans unused plugins from the given `dir`.
-- Returns number of plugins removed.
local function clean_dir(dir)
    local count = 0
    if fn.isdirectory(dir) ~= 0 then
        local plugin_dirs = fn.readdir(dir)
        for _, plugin in ipairs(plugin_dirs) do
            local found = find_plugin(plugin)
            if not found then
                log("Removing unused plugin: " .. plugin)
                fn.delete(dir .. "/" .. plugin)
                count = count + 1
            end
        end
    end
    return count
end

-- Cleans unused packs/plugins from pack_path
local function clean_plugins()
    clear_jet_buf()
    log("", "Clean", "-----")

    local packs = {}
    -- Set pack name as keys to handle duplicates
    -- Also optsync plugins just in case.
    for _, plugin in ipairs(registry) do
        packs[plugin.pack] = plugin.pack
        optsync_plugin(plugin)
    end

    local pack_count = 0
    local plugin_count = 0
    local pack_dirs = fn.readdir(pack_path)
    for _, pack_dir in ipairs(pack_dirs) do
        if packs[pack_dir] then
            local optpath = get_path("opt", pack_dir)
            local startpath = get_path("start", pack_dir)
            plugin_count = plugin_count + clean_dir(optpath)
            plugin_count = plugin_count + clean_dir(startpath)
        else
            log("Removing unused pack: " .. pack_dir)
            fn.delete(pack_path .. pack_dir, "rf")
            pack_count = pack_count + 1
        end
    end

    if pack_count > 0 then
        log("", "Removed " .. pack_count .. " unused packs.")
    else
        log("", "No unused packs to remove.")
    end
    if plugin_count > 0 then
        log("", "Removed " .. plugin_count .. " unused plugins.")
    else
        log("", "No unused plugins to remove.")
    end
end


-- LIST PLUGINS ---------------------------------------------------------------

-- Log which plugins are installed/missing.
local function list_plugins()
    clear_jet_buf()
    log("", "Plugins", "-------")

    local prev_pack = ""
    for _, plugin in ipairs(registry) do
        if plugin.pack ~= prev_pack then
            log("")
            prev_pack = plugin.pack
        end

        local msg = is_installed(plugin) and "OK!" or "missing!"
        local id = plugin.pack .. ":" .. plugin.name
        log_to(id, msg)
   end
end


-- ADD PACK -------------------------------------------------------------------

-- Immediately loads all plugins for the
-- given `pack`.
local function add_pack(pack)
    for _, plugin in ipairs(registry) do
        if plugin.pack == pack then
            vim.cmd("packadd " .. plugin.name)
            if plugin.cfg then plugin.cfg() end
        end
    end
end

-- INITIALIZE -----------------------------------------------------------------

if fn.executable("git") ~= 1 then echo_err(20) end

vim.cmd([[
    command -nargs=? JetInstall lua Jet.install(<f-args>)
    command -nargs=? JetUpdate  lua Jet.update(<f-args>)
    command -nargs=0 JetClean   lua Jet.clean()
    command -nargs=0 JetList    lua Jet.list()
    command -nargs=1 JetAdd     lua Jet.add(<f-args>)
]])

Jet = {
    pack     = init_pack,
    load     = load_plugin,
    install  = install_plugins,
    update   = update_plugins,
    clean    = clean_plugins,
    list     = list_plugins,
    add      = add_pack,
    registry = registry
}
