local msg = require 'mp.msg'
local utils = require 'mp.utils'

function format_search_str(search_str)
    if not search_str then return "" end
    return search_str:gsub('%b()', ''):gsub('%b[]', ''):gsub('%d', ''):gsub('[%_]', ' ')
end

function try_anilist(path, script_dir, final)
    if not path then msg.info("No path provided to try_anilist.") return false end
    search_str = format_search_str(path)
    if not search_str then msg.info("search_str after formatting is null") return false end
    msg.info("SEARCH_STR: "..search_str)
    local table = {}
    table.name = "subprocess"
    table.args = {"python", script_dir.."open-anilist-page.py", search_str}
    local result, err = mp.command_native(table)
    if result.status == 0 then
        mp.osd_message("Launched browser", 1)
        return true
    else
        if final then 
            mp.osd_message("Unable to find Anilist URL.", 3)
        else
            msg.info("AniList query failed. Trying again.")
        end
        return false
    end
end

function anilist_manager(path, script_dir)
    local path_parts = {}
    for part in path:gmatch("[^/]+") do
        table.insert(path_parts, part)
    end
    if #path_parts >= 2 then
        table.remove(path_parts, 1)
        table.remove(path_parts, 1)
    else
        msg.info("Not enough path parts.")
        return
    end
    -- try parent directory first, then reverse loop through remaining parts
    if #path_parts >= 2 then 
        if try_anilist(path_parts[#path_parts - 1], script_dir, false) then return true end
        table.remove(path_parts, #path_parts - 1)
    end
    for i = #path_parts, 1, -1 do
        local final = (i == 1)
        if try_anilist(path_parts[i], script_dir, final) then break end
    end
end

function try_woaf(path, script_dir)
    local table = {}
    table.name = "subprocess"
    table.args = {'sh', script_dir..'open-woaf.sh', path}
    local result, err = mp.command_native(table)
    if result.status == 0 then
        mp.osd_message("Launched browser for audio link", 1)
        return true
    else
        msg.info("Failed to find WOAF metadata. Querying AniList.")
        return false
    end
end

function open_webpage()
    local script_dir = debug.getinfo(1).source:match("@?(.*/)")
    local path = mp.get_property('path')
    msg.info("PATH: "..path)
    mp.osd_message("Finding Audio URL...", 30)
    if not try_woaf(path, script_dir) then
        mp.osd_message("Finding Anilist URL...", 30)
        anilist_manager(path, script_dir)
        -- if not try_anilist(path_parts[#path_parts - 1], script_dir, false) then -- check parent dir
        --     try_anilist(path_parts[#path_parts], script_dir, true) -- check filename
        -- end
    end
end

mp.register_script_message("launch-anilist", open_webpage)