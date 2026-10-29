--[[
==============================================================================
 DaVinci Resolve Free Edition - Secure AI File-Polling Bridge
 File: CustomAILink.lua
 Description: Zero-dependency, non-blocking polling bridge running inside
              DaVinci Resolve's native scripting engine. Allows external AI
              agents (MCP servers, Claude, Cursor, CLI) to safely control
              DaVinci Resolve Free and Studio via atomic file transactions.
==============================================================================
--]]

-- Enable unbuffered stdout for real-time console feedback (when available)
if io and io.stdout and io.stdout.setvbuf then
    pcall(function() io.stdout:setvbuf("no") end)
end

-- Detect Operating System & Directory Separator safely (without assuming package table exists)
local is_windows = false
if package and package.config then
    is_windows = (package.config:sub(1, 1) == "\\")
elseif os and (os.getenv("WINDIR") or os.getenv("SystemRoot") or (os.getenv("OS") and tostring(os.getenv("OS")):match("Windows"))) then
    is_windows = true
end
local sep = is_windows and "\\" or "/"

-- Resolve Bridge Working Directory
local function get_bridge_dir()
    local custom_dir = os.getenv("DAVINCI_BRIDGE_DIR") or os.getenv("RESOLVE_BRIDGE_DIR")
    if custom_dir and #custom_dir > 0 then
        if custom_dir:sub(-1) == sep then
            return custom_dir:sub(1, -2)
        end
        return custom_dir
    end

    if is_windows then
        local temp_base = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
        if temp_base:sub(-1) == "\\" then temp_base = temp_base:sub(1, -2) end
        return temp_base .. "\\davinci_resolve_bridge"
    else
        return "/tmp/davinci_resolve_bridge"
    end
end

local BRIDGE_DIR = get_bridge_dir()

-- Ensure the directory exists
local function ensure_dir(path)
    if bmd and bmd.direxists and bmd.direxists(path) then
        return true
    end
    if bmd and bmd.createdir then
        bmd.createdir(path)
        return true
    end
    if is_windows then
        os.execute('mkdir "' .. path .. '" 2>nul')
    else
        os.execute('mkdir -p "' .. path .. '" 2>/dev/null')
    end
    return true
end

ensure_dir(BRIDGE_DIR)

-- Define File Paths
local fallback_root = is_windows and (os.getenv("TEMP") or "C:\\Temp") or "/tmp"
if fallback_root:sub(-1) == sep then
    fallback_root = fallback_root:sub(1, -2)
end

local PATHS = {
    BRIDGE_DIR = BRIDGE_DIR,
    CMD_JSON = BRIDGE_DIR .. sep .. "resolve_cmd.json",
    RESP_JSON = BRIDGE_DIR .. sep .. "resolve_resp.json",
    CMD_TXT = BRIDGE_DIR .. sep .. "resolve_cmd.txt",
    RESP_TXT = BRIDGE_DIR .. sep .. "resolve_resp.txt",
    -- Fallback paths for direct root /tmp / %TEMP% usage (matches simple CLI scripts)
    LEGACY_CMD_TXT = fallback_root .. sep .. "resolve_cmd.txt",
    LEGACY_CMD_JSON = fallback_root .. sep .. "resolve_cmd.json",
    LEGACY_RESP_TXT = fallback_root .. sep .. "resolve_resp.txt",
    LEGACY_RESP_JSON = fallback_root .. sep .. "resolve_resp.json"
}

-- ==============================================================================
-- Pure Lua JSON Encoder & Decoder (Zero External Dependencies)
-- ==============================================================================
local JSON = {}

local function escape_str(s)
    local escapes = {
        ['\\'] = '\\\\',
        ['"'] = '\\"',
        ['\n'] = '\\n',
        ['\r'] = '\\r',
        ['\t'] = '\\t',
        ['\b'] = '\\b',
        ['\f'] = '\\f'
    }
    return (s:gsub('[\\"\n\r\t\b\f]', escapes))
end

local function is_array(t)
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then return false end
    end
    return true
end

function JSON.encode(val)
    local t = type(val)
    if t == 'nil' then
        return 'null'
    elseif t == 'boolean' then
        return val and 'true' or 'false'
    elseif t == 'number' then
        if val ~= val or val >= math.huge or val <= -math.huge then
            return 'null'
        end
        return tostring(val)
    elseif t == 'string' then
        return '"' .. escape_str(val) .. '"'
    elseif t == 'table' then
        if is_array(val) then
            local items = {}
            for i, v in ipairs(val) do
                table.insert(items, JSON.encode(v))
            end
            return '[' .. table.concat(items, ',') .. ']'
        else
            local items = {}
            for k, v in pairs(val) do
                table.insert(items, '"' .. escape_str(tostring(k)) .. '":' .. JSON.encode(v))
            end
            return '{' .. table.concat(items, ',') .. '}'
        end
    else
        return '"' .. escape_str(tostring(val)) .. '"'
    end
end

function JSON.decode(str)
    if type(str) ~= 'string' or str:match('^%s*$') then
        return nil, "empty or non-string input"
    end

    local pos = 1
    local len = #str

    local function skip_whitespace()
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
                pos = pos + 1
            else
                break
            end
        end
    end

    local parse_value -- forward declaration

    local function parse_string()
        pos = pos + 1 -- skip opening quote
        local start = pos
        local chars = {}
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == '"' then
                table.insert(chars, str:sub(start, pos - 1))
                pos = pos + 1
                return table.concat(chars)
            elseif c == '\\' then
                table.insert(chars, str:sub(start, pos - 1))
                pos = pos + 1
                local esc = str:sub(pos, pos)
                if esc == '"' then table.insert(chars, '"')
                elseif esc == '\\' then table.insert(chars, '\\')
                elseif esc == '/' then table.insert(chars, '/')
                elseif esc == 'b' then table.insert(chars, '\b')
                elseif esc == 'f' then table.insert(chars, '\f')
                elseif esc == 'n' then table.insert(chars, '\n')
                elseif esc == 'r' then table.insert(chars, '\r')
                elseif esc == 't' then table.insert(chars, '\t')
                elseif esc == 'u' then
                    local hex = str:sub(pos + 1, pos + 4)
                    if #hex == 4 and hex:match('^%x+$') then
                        local cp = tonumber(hex, 16)
                        if cp < 128 then
                            table.insert(chars, string.char(cp))
                        else
                            table.insert(chars, '?')
                        end
                        pos = pos + 4
                    end
                else
                    table.insert(chars, esc)
                end
                pos = pos + 1
                start = pos
            else
                pos = pos + 1
            end
        end
        error("unterminated string")
    end

    local function parse_number()
        local start = pos
        if str:sub(pos, pos) == '-' then pos = pos + 1 end
        while pos <= len and str:sub(pos, pos):match('[0-9]') do
            pos = pos + 1
        end
        if pos <= len and str:sub(pos, pos) == '.' then
            pos = pos + 1
            while pos <= len and str:sub(pos, pos):match('[0-9]') do
                pos = pos + 1
            end
        end
        if pos <= len and (str:sub(pos, pos) == 'e' or str:sub(pos, pos) == 'E') then
            pos = pos + 1
            if pos <= len and (str:sub(pos, pos) == '+' or str:sub(pos, pos) == '-') then
                pos = pos + 1
            end
            while pos <= len and str:sub(pos, pos):match('[0-9]') do
                pos = pos + 1
            end
        end
        local num_str = str:sub(start, pos - 1)
        local num = tonumber(num_str)
        if not num then error("invalid number at " .. start .. ": " .. num_str) end
        return num
    end

    local function parse_array()
        pos = pos + 1 -- skip '['
        skip_whitespace()
        local arr = {}
        if pos <= len and str:sub(pos, pos) == ']' then
            pos = pos + 1
            return arr
        end
        while pos <= len do
            local val = parse_value()
            table.insert(arr, val)
            skip_whitespace()
            local c = str:sub(pos, pos)
            if c == ']' then
                pos = pos + 1
                return arr
            elseif c == ',' then
                pos = pos + 1
                skip_whitespace()
            else
                error("expected ',' or ']' at position " .. pos)
            end
        end
        error("unterminated array")
    end

    local function parse_object()
        pos = pos + 1 -- skip '{'
        skip_whitespace()
        local obj = {}
        if pos <= len and str:sub(pos, pos) == '}' then
            pos = pos + 1
            return obj
        end
        while pos <= len do
            skip_whitespace()
            if str:sub(pos, pos) ~= '"' then
                error("expected string key at position " .. pos)
            end
            local key = parse_string()
            skip_whitespace()
            if str:sub(pos, pos) ~= ':' then
                error("expected ':' at position " .. pos)
            end
            pos = pos + 1
            skip_whitespace()
            local val = parse_value()
            obj[key] = val
            skip_whitespace()
            local c = str:sub(pos, pos)
            if c == '}' then
                pos = pos + 1
                return obj
            elseif c == ',' then
                pos = pos + 1
                skip_whitespace()
            else
                error("expected ',' or '}' at position " .. pos)
            end
        end
        error("unterminated object")
    end

    parse_value = function()
        skip_whitespace()
        if pos > len then error("unexpected end of input") end
        local c = str:sub(pos, pos)
        if c == '{' then
            return parse_object()
        elseif c == '[' then
            return parse_array()
        elseif c == '"' then
            return parse_string()
        elseif c == '-' or c:match('[0-9]') then
            return parse_number()
        elseif str:sub(pos, pos + 3) == 'true' then
            pos = pos + 4
            return true
        elseif str:sub(pos, pos + 4) == 'false' then
            pos = pos + 5
            return false
        elseif str:sub(pos, pos + 3) == 'null' then
            pos = pos + 4
            return nil
        else
            error("unexpected token '" .. c .. "' at position " .. pos)
        end
    end

    local ok, res = pcall(function()
        local v = parse_value()
        skip_whitespace()
        return v
    end)

    if ok then
        return res, nil
    else
        return nil, res
    end
end

-- ==============================================================================
-- DaVinci Resolve Connection & Helper Functions
-- ==============================================================================
local cached_resolve = nil
local function get_resolve()
    if cached_resolve then return cached_resolve end
    if resolve then
        cached_resolve = resolve
        return resolve
    end
    if Resolve and type(Resolve) == "function" then
        local ok, r = pcall(Resolve)
        if ok and r then
            cached_resolve = r
            return r
        end
    end
    if app and app.GetResolve then
        local ok, r = pcall(function() return app:GetResolve() end)
        if ok and r then
            cached_resolve = r
            return r
        end
    end
    if bmd and bmd.scriptapp then
        local ok, r = pcall(function() return bmd.scriptapp("Resolve") end)
        if ok and r then
            cached_resolve = r
            return r
        end
    end
    return nil
end

local function get_current_project()
    local r = get_resolve()
    if not r then return nil, "DaVinci Resolve instance not found" end
    local pm = r:GetProjectManager()
    if not pm then return nil, "Could not acquire ProjectManager" end
    local proj = pm:GetCurrentProject()
    if not proj then return nil, "No project currently open in DaVinci Resolve" end
    return proj, nil
end

-- ==============================================================================
-- Sandboxed & Cross-Platform File Operations (Supports Resolve GUI & fuscript)
-- Uses LuaJIT FFI with libc for direct raw byte I/O, bypassing sandbox limits
-- ==============================================================================
local has_ffi, ffi = pcall(require, "ffi")
if has_ffi then
    pcall(function()
        ffi.cdef[[
            void* fopen(const char* filename, const char* mode);
            size_t fread(void* ptr, size_t size, size_t count, void* stream);
            size_t fwrite(const void* ptr, size_t size, size_t count, void* stream);
            int fclose(void* stream);
            int fseek(void* stream, long int offset, int origin);
            long int ftell(void* stream);
            int remove(const char* filename);
            int rename(const char* oldpath, const char* newpath);
            int usleep(unsigned int useconds);
        ]]
    end)
end

local function safe_sleep(seconds)
    if bmd and bmd.wait then
        local ok = pcall(bmd.wait, seconds)
        if ok then return end
    end
    if has_ffi and ffi and ffi.C and ffi.C.usleep then
        local ok = pcall(function() ffi.C.usleep(math.floor(seconds * 1000000)) end)
        if ok then return end
    end
    if os and os.execute then
        if is_windows then
            pcall(os.execute, "timeout /t 1 /nobreak >nul 2>&1")
        else
            pcall(os.execute, "sleep " .. tostring(seconds) .. " 2>/dev/null || sleep 1")
        end
    end
end

local function file_read(path)
    if has_ffi and ffi and ffi.C and ffi.C.fopen then
        local fp = ffi.C.fopen(path, "rb")
        if fp ~= nil then
            ffi.C.fseek(fp, 0, 2) -- SEEK_END
            local sz = tonumber(ffi.C.ftell(fp))
            ffi.C.fseek(fp, 0, 0) -- SEEK_SET
            if sz <= 0 then
                ffi.C.fclose(fp)
                return ""
            end
            local buf = ffi.new("char[?]", sz)
            local n = ffi.C.fread(buf, 1, sz, fp)
            ffi.C.fclose(fp)
            return ffi.string(buf, n)
        end
    end
    if io and io.open then
        local f = io.open(path, "rb")
        if f then
            local c = f:read("*a")
            f:close()
            return c
        end
    end
    if bmd and bmd.readfile then
        local c = bmd.readfile(path)
        if c and #c > 0 then return c end
    end
    return nil
end

local function file_write(path, content)
    if has_ffi and ffi and ffi.C and ffi.C.fopen then
        local fp = ffi.C.fopen(path, "wb")
        if fp ~= nil then
            if content and #content > 0 then
                ffi.C.fwrite(content, 1, #content, fp)
            end
            ffi.C.fclose(fp)
            return true
        end
    end
    if io and io.open then
        local f = io.open(path, "wb")
        if f then
            if content and #content > 0 then f:write(content) end
            f:flush()
            f:close()
            return true
        end
    end
    if bmd and bmd.writefile then
        local ok = bmd.writefile(path, content)
        if ok then return true end
    end
    return false
end

local function file_remove(path)
    if has_ffi and ffi and ffi.C and ffi.C.remove then
        ffi.C.remove(path)
        return
    end
    if os and os.remove then
        pcall(function() os.remove(path) end)
    end
end

local function log_bridge(level, msg)
    local timestamp = (os and os.date and os.date("%H:%M:%S")) or ""
    local line = string.format("[AI Bridge %s] [%s] %s", timestamp, level, msg)
    print(line)
    if io and io.flush then pcall(io.flush) end

    -- Also append to persistent log for external troubleshooting
    local log_entry = (os and os.date and os.date("%Y-%m-%d ") or "") .. line .. "\n"
    local prev = file_read("/tmp/davinci_bridge.log") or ""
    file_write("/tmp/davinci_bridge.log", prev .. log_entry)
end

-- ==============================================================================
-- Atomic File I/O Helpers
-- ==============================================================================
local function write_atomic(dest_path, content)
    local tmp_path = dest_path .. ".tmp"
    local ok = file_write(tmp_path, content)
    if not ok then
        return file_write(dest_path, content)
    end

    -- On Windows, destination must be removed before rename
    if is_windows then
        file_remove(dest_path)
    end

    if has_ffi and ffi and ffi.C and ffi.C.rename then
        if ffi.C.rename(tmp_path, dest_path) == 0 then
            return true
        end
    end

    if os and os.rename then
        local ren_ok = os.rename(tmp_path, dest_path)
        if ren_ok then return true end
    end

    -- Fallback: direct write and remove tmp
    file_write(dest_path, content)
    file_remove(tmp_path)
    return true
end

local function send_response(req_id, command_name, success, data, err_msg, is_legacy, origin_path)
    local response_obj = {
        id = req_id or ("resp_" .. tostring(os.time())),
        command = command_name or "UNKNOWN",
        status = success and "success" or "error",
        data = data or {},
        error = err_msg,
        timestamp = os.time()
    }

    local encoded_json = JSON.encode(response_obj)

    -- Primary JSON response
    write_atomic(PATHS.RESP_JSON, encoded_json)

    -- Also write to legacy path if triggered from legacy location
    if is_legacy then
        write_atomic(PATHS.LEGACY_RESP_JSON, encoded_json)
        local txt_resp = string.format("%s: %s\n", response_obj.status:upper(), err_msg or JSON.encode(data or {}))
        write_atomic(PATHS.LEGACY_RESP_TXT, txt_resp)
        write_atomic(PATHS.RESP_TXT, txt_resp)
    else
        local txt_resp = string.format("%s: %s\n", response_obj.status:upper(), err_msg or JSON.encode(data or {}))
        write_atomic(PATHS.RESP_TXT, txt_resp)
    end
end

-- ==============================================================================
-- Secure Command Handlers (Allowlist Dispatch)
-- ==============================================================================
local COMMANDS = {}

-- Ping & Connectivity Check
COMMANDS["PING"] = function(params)
    local r = get_resolve()
    return {
        pong = true,
        bridge_dir = PATHS.BRIDGE_DIR,
        product_name = r and r:GetProductName() or "Unknown",
        version = r and r:GetVersionString() or "Unknown",
        is_studio = r and r:IsStudio() or false
    }
end

-- Project Status & Metadata
COMMANDS["GET_STATUS"] = function(params)
    local r = get_resolve()
    if not r then error("Resolve API not available") end
    local pm = r:GetProjectManager()
    local proj = pm and pm:GetCurrentProject()

    local result = {
        connected = true,
        product = r:GetProductName(),
        version = r:GetVersionString(),
        is_studio = r:IsStudio(),
        current_page = r:GetCurrentPage()
    }

    if proj then
        result.project_loaded = true
        result.project_name = proj:GetName()
        result.timeline_count = proj:GetTimelineCount()

        local tl = proj:GetCurrentTimeline()
        if tl then
            result.active_timeline = {
                name = tl:GetName(),
                start_frame = tl:GetStartFrame(),
                end_frame = tl:GetEndFrame(),
                current_timecode = tl:GetCurrentTimecode()
            }
        end
    else
        result.project_loaded = false
    end

    return result
end

-- Save Active Project
COMMANDS["SAVE_PROJECT"] = function(params)
    local r = get_resolve()
    if not r then error("Resolve API not available") end
    local pm = r:GetProjectManager()
    if not pm then error("ProjectManager not found") end
    local proj = pm:GetCurrentProject()
    if not proj then error("No active project to save") end

    local ok = pm:SaveProject()
    if not ok then error("Failed to save project") end

    return { saved = true, project = proj:GetName() }
end

-- List Projects in Current Folder
COMMANDS["LIST_PROJECTS"] = function(params)
    local r = get_resolve()
    if not r then error("Resolve API not available") end
    local pm = r:GetProjectManager()
    if not pm then error("ProjectManager not found") end

    local list = pm:GetProjectListInCurrentFolder() or {}
    return { projects = list }
end

-- Create New Project
COMMANDS["CREATE_PROJECT"] = function(params)
    local name = params and params.name
    if not name or #name == 0 then error("Param 'name' is required for CREATE_PROJECT") end

    local r = get_resolve()
    if not r then error("Resolve API not available") end
    local pm = r:GetProjectManager()
    local proj = pm:CreateProject(name)
    if not proj then error("Failed to create project '" .. name .. "' (it may already exist)") end

    return { created = true, name = proj:GetName() }
end

-- Load Project by Name
COMMANDS["LOAD_PROJECT"] = function(params)
    local name = params and params.name
    if not name or #name == 0 then error("Param 'name' is required for LOAD_PROJECT") end

    local r = get_resolve()
    if not r then error("Resolve API not available") end
    local pm = r:GetProjectManager()
    local proj = pm:LoadProject(name)
    if not proj then error("Failed to load project '" .. name .. "'") end

    return { loaded = true, name = proj:GetName() }
end

-- Switch Workspace Page
COMMANDS["OPEN_PAGE"] = function(params)
    local page = (params and (params.page or params.name) or ""):lower()
    local valid_pages = { media = true, cut = true, edit = true, fusion = true, color = true, fairlight = true, deliver = true }
    if not valid_pages[page] then
        error("Invalid page name: '" .. tostring(page) .. "'. Must be one of: media, cut, edit, fusion, color, fairlight, deliver")
    end

    local r = get_resolve()
    if not r then error("Resolve API not available") end
    local ok = r:OpenPage(page)
    return { success = ok, page = r:GetCurrentPage() }
end

-- Create Empty Timeline
COMMANDS["CREATE_TIMELINE"] = function(params)
    local proj, err = get_current_project()
    if not proj then error(err) end

    local mp = proj:GetMediaPool()
    if not mp then error("MediaPool not accessible") end

    local name = (params and params.name) or ("Timeline " .. os.date("%Y-%m-%d %H%M%S"))
    local tl = mp:CreateEmptyTimeline(name)
    if not tl then error("Failed to create empty timeline: " .. tostring(name)) end

    return {
        created = true,
        timeline_name = tl:GetName(),
        start_frame = tl:GetStartFrame(),
        current_timecode = tl:GetCurrentTimecode()
    }
end

-- List All Timelines
COMMANDS["GET_TIMELINES"] = function(params)
    local proj, err = get_current_project()
    if not proj then error(err) end

    local count = proj:GetTimelineCount() or 0
    local timelines = {}
    local active_tl = proj:GetCurrentTimeline()
    local active_name = active_tl and active_tl:GetName()

    for i = 1, count do
        local tl = proj:GetTimelineByIndex(i)
        if tl then
            table.insert(timelines, {
                index = i,
                name = tl:GetName(),
                is_active = (tl:GetName() == active_name),
                start_frame = tl:GetStartFrame(),
                end_frame = tl:GetEndFrame(),
                current_timecode = tl:GetCurrentTimecode()
            })
        end
    end

    return { count = count, timelines = timelines }
end

-- Set Current Timeline by Name or Index
COMMANDS["SET_CURRENT_TIMELINE"] = function(params)
    local proj, err = get_current_project()
    if not proj then error(err) end

    local target_name = params and params.name
    local target_idx = params and params.index

    local count = proj:GetTimelineCount() or 0
    local found_tl = nil

    if target_idx and target_idx >= 1 and target_idx <= count then
        found_tl = proj:GetTimelineByIndex(target_idx)
    elseif target_name then
        for i = 1, count do
            local tl = proj:GetTimelineByIndex(i)
            if tl and tl:GetName() == target_name then
                found_tl = tl
                break
            end
        end
    else
        error("Either 'name' or 'index' is required for SET_CURRENT_TIMELINE")
    end

    if not found_tl then
        error("Timeline not found with specified criteria")
    end

    local ok = proj:SetCurrentTimeline(found_tl)
    if not ok then error("Failed to switch timeline") end

    return { active_timeline = found_tl:GetName() }
end

-- Playhead Timecode Control
COMMANDS["GET_CURRENT_TIME"] = function(params)
    local proj, err = get_current_project()
    if not proj then error(err) end
    local tl = proj:GetCurrentTimeline()
    if not tl then error("No active timeline open") end

    return {
        timeline = tl:GetName(),
        current_timecode = tl:GetCurrentTimecode(),
        start_frame = tl:GetStartFrame(),
        end_frame = tl:GetEndFrame()
    }
end

COMMANDS["SET_CURRENT_TIME"] = function(params)
    local timecode = params and (params.timecode or params.time)
    if not timecode then error("Param 'timecode' (e.g. '01:00:10:00') is required") end

    local proj, err = get_current_project()
    if not proj then error(err) end
    local tl = proj:GetCurrentTimeline()
    if not tl then error("No active timeline open") end

    local ok = tl:SetCurrentTimecode(timecode)
    return { success = ok, timecode = tl:GetCurrentTimecode() }
end

-- Timeline Markers
COMMANDS["ADD_MARKER"] = function(params)
    local proj, err = get_current_project()
    if not proj then error(err) end
    local tl = proj:GetCurrentTimeline()
    if not tl then error("No active timeline open") end

    local frame_id = params and (params.frameId or params.frame)
    if not frame_id then
        -- Default to start frame
        frame_id = tl:GetStartFrame() or 0
    end

    local color = (params and params.color) or "Blue"
    local name = (params and params.name) or "AI Marker"
    local note = (params and params.note) or ""
    local duration = (params and params.duration) or 1
    local custom_data = (params and params.customData) or ""

    local ok = tl:AddMarker(frame_id, color, name, note, duration, custom_data)
    if not ok then error("AddMarker failed at frame " .. tostring(frame_id)) end

    return {
        added = true,
        frame_id = frame_id,
        color = color,
        name = name,
        note = note
    }
end

COMMANDS["GET_MARKERS"] = function(params)
    local proj, err = get_current_project()
    if not proj then error(err) end
    local tl = proj:GetCurrentTimeline()
    if not tl then error("No active timeline open") end

    local markers = tl:GetMarkers() or {}
    return { markers = markers }
end

COMMANDS["DELETE_MARKER"] = function(params)
    local frame_id = params and (params.frameId or params.frame)
    if not frame_id then error("Param 'frameId' is required for DELETE_MARKER") end

    local proj, err = get_current_project()
    if not proj then error(err) end
    local tl = proj:GetCurrentTimeline()
    if not tl then error("No active timeline open") end

    local ok = tl:DeleteMarkerByFrame(frame_id)
    return { deleted = ok, frame_id = frame_id }
end

-- Media Pool Operations
COMMANDS["IMPORT_MEDIA"] = function(params)
    local proj, err = get_current_project()
    if not proj then error(err) end
    local mp = proj:GetMediaPool()
    if not mp then error("MediaPool not available") end

    local raw_paths = params and (params.paths or params.path)
    if not raw_paths then error("Param 'paths' (string or array of paths) is required") end

    local paths = {}
    if type(raw_paths) == "string" then
        table.insert(paths, raw_paths)
    elseif type(raw_paths) == "table" then
        paths = raw_paths
    end

    local imported_items = mp:ImportMedia(paths)
    local imported_names = {}
    if imported_items then
        for _, item in ipairs(imported_items) do
            if item and item.GetName then
                table.insert(imported_names, item:GetName())
            end
        end
    end

    return {
        success = (imported_items ~= nil and #imported_items > 0),
        imported_count = #imported_names,
        items = imported_names
    }
end

COMMANDS["CREATE_BIN"] = function(params)
    local name = params and params.name
    if not name or #name == 0 then error("Param 'name' is required for CREATE_BIN") end

    local proj, err = get_current_project()
    if not proj then error(err) end
    local mp = proj:GetMediaPool()
    if not mp then error("MediaPool not available") end

    local cur_folder = mp:GetCurrentFolder() or mp:GetRootFolder()
    local new_folder = mp:AddSubFolder(cur_folder, name)
    if not new_folder then error("Failed to create subfolder '" .. name .. "'") end

    return { created = true, folder = new_folder:GetName() }
end

-- Render Queue
COMMANDS["START_RENDER"] = function(params)
    local proj, err = get_current_project()
    if not proj then error(err) end

    local ok = proj:StartRendering()
    return { started = ok, is_rendering = proj:IsRenderingInProgress() }
end

COMMANDS["STOP_RENDER"] = function(params)
    local proj, err = get_current_project()
    if not proj then error(err) end

    proj:StopRendering()
    return { stopped = true }
end

COMMANDS["GET_RENDER_STATUS"] = function(params)
    local proj, err = get_current_project()
    if not proj then error(err) end

    return { is_rendering = proj:IsRenderingInProgress() }
end

-- ==============================================================================
-- Command Parser & Dispatcher
-- ==============================================================================
local function parse_and_execute(raw_content, is_legacy, origin_path)
    local req_id = nil
    local cmd_name = nil
    local params = {}

    -- Try parsing as JSON first
    local parsed, json_err = JSON.decode(raw_content)
    if parsed and type(parsed) == "table" then
        req_id = parsed.id
        cmd_name = parsed.command and parsed.command:upper()
        params = parsed.params or {}
    else
        -- Fallback to plain text format (e.g. "CREATE_TIMELINE My Timeline" or "SAVE_PROJECT")
        local trimmed = raw_content:match("^%s*(.-)%s*$")
        if not trimmed or #trimmed == 0 then
            return nil
        end
        local space_idx = trimmed:find("%s")
        if space_idx then
            cmd_name = trimmed:sub(1, space_idx - 1):upper()
            local rest = trimmed:sub(space_idx + 1):match("^%s*(.-)%s*$")
            params = { name = rest, value = rest }
        else
            cmd_name = trimmed:upper()
            params = {}
        end
    end

    if not cmd_name or #cmd_name == 0 then
        log_bridge("WARN", "Received empty command, ignoring.")
        return nil
    end

    -- Special internal commands
    if cmd_name == "EXIT" or cmd_name == "QUIT" or cmd_name == "SHUTDOWN" then
        log_bridge("INFO", "Shutdown command received. Halting listener loop.")
        send_response(req_id, cmd_name, true, { message = "AI Bridge listener stopped gracefully" }, nil, is_legacy, origin_path)
        return "EXIT"
    end

    -- Security: Validate against Allowlist
    local handler = COMMANDS[cmd_name]
    if not handler then
        local err = "Command not recognized or not permitted: '" .. tostring(cmd_name) .. "'"
        log_bridge("WARN", err)
        send_response(req_id, cmd_name, false, nil, err, is_legacy, origin_path)
        return true
    end

    log_bridge("EXEC", "Executing: " .. cmd_name)

    -- Protected execution
    local ok, res_or_err = pcall(handler, params)
    if ok then
        log_bridge("OK", "Command " .. cmd_name .. " completed successfully.")
        send_response(req_id, cmd_name, true, res_or_err, nil, is_legacy, origin_path)
    else
        local clean_err = tostring(res_or_err):gsub(".-:%d+: ", "")
        log_bridge("ERROR", "Command " .. cmd_name .. " failed: " .. clean_err)
        send_response(req_id, cmd_name, false, nil, clean_err, is_legacy, origin_path)
    end

    return true
end

-- ==============================================================================
-- Main Listener Loop
-- ==============================================================================
local function process_file(file_path, is_legacy)
    local content = file_read(file_path)
    if not content or #content == 0 then
        return nil
    end

    -- Remove command file immediately to prevent reprocessing
    file_remove(file_path)

    return parse_and_execute(content, is_legacy, file_path)
end

local function run_bridge_listener()
    local r = get_resolve()
    local header = [[
==================================================================
 DaVinci Resolve Free AI File-Polling Bridge (CustomAILink)
 Status: ACTIVE & LISTENING
 Bridge Directory: ]] .. PATHS.BRIDGE_DIR .. "\n" ..
 [[ Watching Files:
   - JSON: ]] .. PATHS.CMD_JSON .. "\n" ..
 [[   - TXT:  ]] .. PATHS.CMD_TXT
    if PATHS.LEGACY_CMD_TXT ~= PATHS.CMD_TXT then
        header = header .. "\n   - Fallback TXT:  " .. PATHS.LEGACY_CMD_TXT
    end
    if r then
        header = header .. "\n Connected To: " .. tostring(r:GetProductName()) .. " v" .. tostring(r:GetVersionString())
    else
        header = header .. "\n Note: Running in standalone or unattached mode."
    end
    header = header .. "\n=================================================================="
    print(header)
    if io and io.flush then pcall(io.flush) end

    -- Also record startup in /tmp/davinci_bridge.log
    local prev = file_read("/tmp/davinci_bridge.log") or ""
    local startup_msg = (os and os.date and os.date("%Y-%m-%d %H:%M:%S") or "") .. " [STARTUP] Listener initialized successfully\n"
    file_write("/tmp/davinci_bridge.log", prev .. startup_msg)

    local running = true
    local poll_interval = 0.25 -- 250ms interval

    while running do
        local ok, res = pcall(process_file, PATHS.CMD_JSON, false)
        if ok and res == "EXIT" then break end
        if not ok then log_bridge("ERROR", "Error in CMD_JSON: " .. tostring(res)) end

        ok, res = pcall(process_file, PATHS.CMD_TXT, false)
        if ok and res == "EXIT" then break end
        if not ok then log_bridge("ERROR", "Error in CMD_TXT: " .. tostring(res)) end

        if PATHS.LEGACY_CMD_TXT ~= PATHS.CMD_TXT then
            ok, res = pcall(process_file, PATHS.LEGACY_CMD_TXT, true)
            if ok and res == "EXIT" then break end
        end

        if PATHS.LEGACY_CMD_JSON ~= PATHS.CMD_JSON then
            ok, res = pcall(process_file, PATHS.LEGACY_CMD_JSON, true)
            if ok and res == "EXIT" then break end
        end

        safe_sleep(poll_interval)
    end

    log_bridge("INFO", "AI Bridge listener exited.")
end

-- Start Listener
run_bridge_listener()
