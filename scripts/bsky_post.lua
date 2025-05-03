local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("dkjson")
local socket = require("socket")

local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = require 'mp.options'

package.path = mp.command_native({"expand-path", "~~/script-modules/?.lua;"})..package.path
local uin = require "user-input-module"

local o = {
    handle = '',
    password = ''
}
options.read_options(o)

local function is_empty(str)
    return str == nil or str == ''
end

local function timestamp()
    local now = os.time()
    local ms = tostring(math.floor((socket.gettime() % 1) * 1000))
    ms = string.rep("0", 3 - #ms) .. ms
    return os.date("!%Y-%m-%dT%H:%M:%S", now) .. "." .. ms .. "Z"
end

local function seconds_to_hms(seconds)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = math.floor(seconds % 60)
    return string.format("%02d:%02d:%02d", hours, minutes, secs)
end

local function http_post_blob(url, payload, token, content_type)
    local body = {}
    assert(type(payload) == "string", "Payload must be a string")

    local headers = {
        ["Content-Type"] = content_type or "application/octet-stream",
        ["Accept"] = "application/json",
        ["Content-Length"] = tostring(#payload),
    }

    if token then
        headers["Authorization"] = "Bearer " .. token
    end

    local res, code, response_headers, status = http.request{
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(body),
    }

    if not res then
        msg.error("HTTP request failed: ", status or "unknown error")
        return nil
    end

    local response_text = table.concat(body)
    local ok, result = pcall(json.decode, response_text)
    if not ok then
        msg.error("Failed to decode JSON: ", result)
        return nil
    end

    return result
end

local function http_post(url, payload_table, token)
    local body = {}
    local payload = json.encode(payload_table)

    local headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
        ["Content-Length"] = tostring(#payload)
    }
    if token then
        headers["Authorization"] = "Bearer " .. token
    end

    local res, code, response_headers, status = http.request{
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(body)
    }

    if code ~= 200 then
        msg.info("HTTP response code: " .. tostring(code))
        msg.info("HTTP response body: " .. table.concat(body))
        return nil
    end
    
    return json.decode(table.concat(body)) or nil
end

local function http_get(url)
    local body = {}
    local res, code, headers, status = http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(body)
    }
    if not res then return nil end
    return json.decode(table.concat(body)) or nil
end

local function get_did_doc(did)
    local url
    if did:sub(1, 8) == "did:web:" then
        local domain = did:match("^did:web:(.+)")
        url = "https://" .. domain .. "/.well-known/did.json"
    else
        url = "https://plc.directory/" .. did
    end
    return http_get(url)
end

local function get_service_endpoint(did)
    local doc = get_did_doc(did)
    if is_empty(doc.service) then return nil end

    for _, service in ipairs(doc.service) do
        if service.type == "AtprotoPersonalDataServer" then
            return service.serviceEndpoint
        end
    end

    return nil
end

local function get_session(username, password, service_endpoint)
    local url = service_endpoint .. '/xrpc/com.atproto.server.createSession'
    local payload = {
        identifier = username,
        password = password
    }
    return http_post(url, payload)
end

local function create_record(session, service_endpoint, record)
    local token = session["accessJwt"]
    local api = service_endpoint .. "/xrpc/com.atproto.repo.createRecord"
    local payload = {
        repo = session["did"],
        collection = record["$type"],
        record = record
    }
    local res = http_post(api, payload, token)
    return res.uri or nil
end

local function resolve_handle(handle)
    if string.sub(handle, 1, 4) == "did:" then return handle end
    if string.sub(handle, 1, 1) == "@" then handle = string.sub(handle, 2) end
    if is_empty(handle) then return nil end
    local url = 'https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle?handle='..handle
    local res = http_get(url)
    return res.did
end

local function upload_screenshot_blob(session, service_endpoint)
    msg.info("Uploading blob...")
    mp.osd_message("Uploading blob...", 5)

    local temp_file = '/tmp/mpv-screenshot.png'
    mp.commandv('screenshot-to-file', temp_file)
    local cmd = { 'pngquant', "--quality=30-50", '--output', temp_file, '--force', temp_file }
    local result = mp.command_native({
        name           = "subprocess",
        args           = cmd,
        capture_stdout = false,
        capture_stderr = false,
    })
    if result.error or result.status ~= 0 then
        msg.error("pngquant failed with status ", result.status or result.error)
        return nil
    end
    msg.info("Screenshot compressed")

    local file = io.open(temp_file, "rb")
    if not file then
        msg.error("Failed to open screenshot file")
        return nil
    end
    local blob_bytes = file:read("*all")
    file:close()

    local size_kb = #blob_bytes / 1024
    if size_kb > 1000 then
        msg.error(string.format("Screenshot is too large to upload (%.1f KB).", size_kb))
        return nil
    end

    local url = service_endpoint .. "/xrpc/com.atproto.repo.uploadBlob"
    local token = session["accessJwt"]
    local response = http_post_blob(url, blob_bytes, token, "image/png")
    return response.blob or nil
end

local function bsky_post(input)
    local did = resolve_handle(o.handle)
    if is_empty(did) then
        msg.info("Failed to resolve handle")
        mp.osd_message("Failed to resolve handle. Post cancelled.", 2)
        return
    end

    local service = get_service_endpoint(did)
    if is_empty(service) then
        msg.info("Failed to get service endpoint")
        mp.osd_message("Failed to get service endpoint. Post cancelled.", 2)
        return
    end

    local session = get_session(did, o.password, service)
    if is_empty(session) then
        msg.info("Failed to get session")
        mp.osd_message("Failed to get session. Post cancelled.", 2)
        return
    end

    local blob = upload_screenshot_blob(session, service)
    if not blob then
        msg.info("Failed to upload blob")
        mp.osd_message("Failed to upload blob. Post cancelled.", 2)
        return
    end

    local title = mp.get_property("media-title") or "Untitled"
    local subs = mp.get_property("sub-text") or ""
    local time = seconds_to_hms(mp.get_property("time-pos") or 0)
    local alt_text = title .. '\n' .. time .. '\n' .. subs

    local record = {
        text = input,
        ["$type"] = "app.bsky.feed.post",
        langs = { "en" },
        createdAt = timestamp(),
        embed = {
            ["$type"] = "app.bsky.embed.images",
            images = {{
                alt = alt_text,
                image = blob,
                aspectRatio = {
                    width = mp.get_property_native("osd-width"),
                    height = mp.get_property_native("osd-height")
                }
            }}
        }
    }

    local uri = create_record(session, service, record)
    if is_empty(uri) then
        msg.info("Bluesky post creation failed.")
        mp.osd_message("Bluesky post creation failed.", 2)
    end
    msg.info("Bluesky post sucessfully created: "..uri)
    mp.osd_message("Bluesky post created: "..uri, 2)
end

local function input_manager(input, err, flag)
    if is_empty(o.handle) or is_empty(o.password) then
        msg.info("Missing credentials in ~/.config/mpv/scripts/bsky_post.lua")
        mp.osd_message("Missing credentials in ~/.config/mpv/scripts/bsky_post.lua", 3)
        return
    end
    if not input or input == 'exit' or input == 'quit' then -- allow ''
        msg.info("Cancelled post creation.")
        mp.osd_message("Cancelled post creation", 1)
        return
    end
    bsky_post(input)
end

mp.add_key_binding("Alt+B", "bsky_post", function()
    uin.get_user_input(input_manager, {
        request_text = "Enter post text:",
        replace = true
    }, "replace")
end)
