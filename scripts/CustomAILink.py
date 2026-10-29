#!/usr/bin/env python3
"""
==============================================================================
 DaVinci Resolve Free Edition - Secure AI File-Polling Bridge (Python)
 File: CustomAILink.py
 Description: Zero-dependency, non-blocking polling bridge running inside
              DaVinci Resolve's native scripting engine. Allows external AI
              agents (MCP servers, Claude, Cursor, CLI) to safely control
              DaVinci Resolve Free and Studio via atomic file transactions.
==============================================================================
"""

import json
import os
import sys
import time

def get_bridge_dir():
    custom = os.environ.get("DAVINCI_BRIDGE_DIR") or os.environ.get("RESOLVE_BRIDGE_DIR")
    if custom:
        return custom
    if sys.platform.startswith("win"):
        temp_base = os.environ.get("TEMP") or os.environ.get("TMP") or "C:\\Temp"
        return os.path.join(temp_base, "davinci_resolve_bridge")
    return "/tmp/davinci_resolve_bridge"

BRIDGE_DIR = get_bridge_dir()
os.makedirs(BRIDGE_DIR, exist_ok=True)

CMD_JSON = os.path.join(BRIDGE_DIR, "resolve_cmd.json")
RESP_JSON = os.path.join(BRIDGE_DIR, "resolve_resp.json")
CMD_TXT = os.path.join(BRIDGE_DIR, "resolve_cmd.txt")
RESP_TXT = os.path.join(BRIDGE_DIR, "resolve_resp.txt")
LOG_FILE = "/tmp/davinci_bridge.log"

def log_bridge(level, msg):
    ts = time.strftime("%H:%M:%S")
    line = f"[AI Bridge {ts}] [{level}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d ')}{line}\n")
    except Exception:
        pass

def write_atomic(dest_path, data):
    tmp = dest_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        if isinstance(data, (dict, list)):
            json.dump(data, f)
        else:
            f.write(str(data))
    os.replace(tmp, dest_path)

def send_response(req_id, cmd_name, success, data=None, err_msg=None):
    resp = {
        "id": req_id or f"resp_{int(time.time())}",
        "command": cmd_name or "UNKNOWN",
        "status": "success" if success else "error",
        "data": data or {},
        "error": err_msg,
        "timestamp": int(time.time())
    }
    write_atomic(RESP_JSON, resp)
    txt_status = "SUCCESS" if success else "ERROR"
    txt_body = json.dumps(data or {}) if success else (err_msg or "Unknown error")
    write_atomic(RESP_TXT, f"{txt_status}: {txt_body}\n")

# Resolve Connection
def get_resolve():
    if "resolve" in globals() and globals()["resolve"] is not None:
        return globals()["resolve"]
    if "bmd" in globals() and hasattr(globals()["bmd"], "scriptapp"):
        try:
            r = globals()["bmd"].scriptapp("Resolve")
            if r: return r
        except Exception:
            pass
    try:
        import __main__
        if hasattr(__main__, "resolve") and __main__.resolve:
            return __main__.resolve
        if hasattr(__main__, "bmd") and hasattr(__main__.bmd, "scriptapp"):
            r = __main__.bmd.scriptapp("Resolve")
            if r: return r
    except Exception:
        pass
    try:
        import DaVinciResolveScript as bmd
        return bmd.scriptapp("Resolve")
    except Exception:
        pass
    return None

def get_current_project():
    r = get_resolve()
    if not r:
        raise RuntimeError("DaVinci Resolve instance not found")
    pm = r.GetProjectManager()
    if not pm:
        raise RuntimeError("Could not acquire ProjectManager")
    proj = pm.GetCurrentProject()
    if not proj:
        raise RuntimeError("No project currently open in DaVinci Resolve")
    return proj

# Command Handlers
COMMANDS = {}

def cmd_ping(params):
    r = get_resolve()
    return {
        "pong": True,
        "bridge_dir": BRIDGE_DIR,
        "product_name": r.GetProductName() if r else "Unknown",
        "version": r.GetVersionString() if r else "Unknown",
        "is_studio": r.IsStudio() if r else False
    }
COMMANDS["PING"] = cmd_ping

def cmd_get_status(params):
    r = get_resolve()
    if not r: raise RuntimeError("Resolve not available")
    pm = r.GetProjectManager()
    proj = pm.GetCurrentProject() if pm else None
    cur_tl = proj.GetCurrentTimeline() if proj else None
    return {
        "product_name": r.GetProductName(),
        "version": r.GetVersionString(),
        "is_studio": r.IsStudio(),
        "current_page": r.GetCurrentPage(),
        "project_name": proj.GetName() if proj else None,
        "timeline_name": cur_tl.GetName() if cur_tl else None,
        "timeline_count": proj.GetTimelineCount() if proj else 0
    }
COMMANDS["GET_STATUS"] = cmd_get_status

def cmd_save_project(params):
    proj = get_current_project()
    r = get_resolve()
    pm = r.GetProjectManager()
    return {"saved": bool(pm.SaveProject()), "project": proj.GetName()}
COMMANDS["SAVE_PROJECT"] = cmd_save_project

def cmd_list_projects(params):
    r = get_resolve()
    pm = r.GetProjectManager()
    return {"projects": pm.GetProjectListInCurrentFolder() or []}
COMMANDS["LIST_PROJECTS"] = cmd_list_projects

def cmd_create_project(params):
    name = params.get("name")
    if not name: raise ValueError("Missing project name")
    r = get_resolve()
    pm = r.GetProjectManager()
    proj = pm.CreateProject(name)
    if not proj: raise RuntimeError(f"Failed to create project '{name}'")
    return {"created": True, "name": proj.GetName()}
COMMANDS["CREATE_PROJECT"] = cmd_create_project

def cmd_load_project(params):
    name = params.get("name")
    if not name: raise ValueError("Missing project name")
    r = get_resolve()
    pm = r.GetProjectManager()
    proj = pm.LoadProject(name)
    if not proj: raise RuntimeError(f"Failed to load project '{name}'")
    return {"loaded": True, "name": proj.GetName()}
COMMANDS["LOAD_PROJECT"] = cmd_load_project

def cmd_open_page(params):
    page = params.get("page")
    if not page: raise ValueError("Missing page name")
    r = get_resolve()
    ok = r.OpenPage(page)
    return {"success": bool(ok), "current_page": r.GetCurrentPage()}
COMMANDS["OPEN_PAGE"] = cmd_open_page

def cmd_create_timeline(params):
    proj = get_current_project()
    mp = proj.GetMediaPool()
    name = params.get("name")
    tl = mp.CreateEmptyTimeline(name) if name else mp.CreateEmptyTimeline()
    if not tl: raise RuntimeError("Failed to create timeline")
    return {"created": True, "name": tl.GetName(), "id": tl.GetUniqueId()}
COMMANDS["CREATE_TIMELINE"] = cmd_create_timeline

def cmd_get_timelines(params):
    proj = get_current_project()
    count = proj.GetTimelineCount()
    timelines = []
    cur_tl = proj.GetCurrentTimeline()
    cur_name = cur_tl.GetName() if cur_tl else None
    for i in range(1, count + 1):
        tl = proj.GetTimelineByIndex(i)
        if tl:
            timelines.append({
                "index": i,
                "name": tl.GetName(),
                "id": tl.GetUniqueId(),
                "is_current": (tl.GetName() == cur_name)
            })
    return {"count": count, "timelines": timelines}
COMMANDS["GET_TIMELINES"] = cmd_get_timelines

def cmd_set_current_timeline(params):
    proj = get_current_project()
    target_tl = None
    if "index" in params:
        target_tl = proj.GetTimelineByIndex(int(params["index"]))
    elif "name" in params:
        name = params["name"]
        for i in range(1, proj.GetTimelineCount() + 1):
            tl = proj.GetTimelineByIndex(i)
            if tl and tl.GetName() == name:
                target_tl = tl
                break
    if not target_tl: raise RuntimeError("Timeline not found")
    ok = proj.SetCurrentTimeline(target_tl)
    return {"success": bool(ok), "name": target_tl.GetName()}
COMMANDS["SET_CURRENT_TIMELINE"] = cmd_set_current_timeline

def cmd_get_current_time(params):
    proj = get_current_project()
    tl = proj.GetCurrentTimeline()
    if not tl: raise RuntimeError("No current timeline")
    return {"timecode": tl.GetCurrentTimecode()}
COMMANDS["GET_CURRENT_TIME"] = cmd_get_current_time

def cmd_set_current_time(params):
    tc = params.get("timecode")
    if not tc: raise ValueError("Missing timecode")
    proj = get_current_project()
    tl = proj.GetCurrentTimeline()
    if not tl: raise RuntimeError("No current timeline")
    ok = tl.SetCurrentTimecode(tc)
    return {"success": bool(ok), "timecode": tl.GetCurrentTimecode()}
COMMANDS["SET_CURRENT_TIME"] = cmd_set_current_time

def cmd_add_marker(params):
    proj = get_current_project()
    tl = proj.GetCurrentTimeline()
    if not tl: raise RuntimeError("No current timeline")
    frame_id = int(params.get("frameId") or tl.GetStartFrame())
    color = params.get("color", "Blue")
    name = params.get("name", "AI Marker")
    note = params.get("note", "")
    duration = int(params.get("duration", 1))
    ok = tl.AddMarker(frame_id, color, name, note, duration)
    return {"success": bool(ok), "frameId": frame_id, "color": color, "name": name}
COMMANDS["ADD_MARKER"] = cmd_add_marker

def cmd_get_markers(params):
    proj = get_current_project()
    tl = proj.GetCurrentTimeline()
    if not tl: raise RuntimeError("No current timeline")
    return {"markers": tl.GetMarkers() or {}}
COMMANDS["GET_MARKERS"] = cmd_get_markers

def cmd_delete_marker(params):
    proj = get_current_project()
    tl = proj.GetCurrentTimeline()
    if not tl: raise RuntimeError("No current timeline")
    frame_id = int(params.get("frameId"))
    ok = tl.DeleteMarkerAtFrame(frame_id)
    return {"success": bool(ok), "frameId": frame_id}
COMMANDS["DELETE_MARKER"] = cmd_delete_marker

def cmd_import_media(params):
    proj = get_current_project()
    mp = proj.GetMediaPool()
    paths = params.get("paths", [])
    if isinstance(paths, str): paths = [paths]
    clips = mp.ImportMedia(paths)
    imported = [c.GetName() for c in (clips or []) if c]
    return {"count": len(imported), "imported_clips": imported}
COMMANDS["IMPORT_MEDIA"] = cmd_import_media

def cmd_create_bin(params):
    proj = get_current_project()
    mp = proj.GetMediaPool()
    name = params.get("name")
    if not name: raise ValueError("Missing bin name")
    cur_folder = mp.GetCurrentFolder() or mp.GetRootFolder()
    new_folder = mp.AddSubFolder(cur_folder, name)
    if not new_folder: raise RuntimeError(f"Failed to create bin '{name}'")
    return {"created": True, "folder": new_folder.GetName()}
COMMANDS["CREATE_BIN"] = cmd_create_bin

def cmd_start_render(params):
    proj = get_current_project()
    ok = proj.StartRendering()
    return {"started": bool(ok), "is_rendering": proj.IsRenderingInProgress()}
COMMANDS["START_RENDER"] = cmd_start_render

def cmd_stop_render(params):
    proj = get_current_project()
    proj.StopRendering()
    return {"stopped": True}
COMMANDS["STOP_RENDER"] = cmd_stop_render

def cmd_get_render_status(params):
    proj = get_current_project()
    return {"is_rendering": proj.IsRenderingInProgress()}
COMMANDS["GET_RENDER_STATUS"] = cmd_get_render_status

def process_file(file_path):
    if not os.path.exists(file_path):
        return None
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            raw = f.read().strip()
    except Exception:
        return None
    try:
        os.remove(file_path)
    except Exception:
        pass
    if not raw:
        return None

    raw = raw.strip()
    if raw.startswith("return [=[") and "]=]" in raw:
        start_idx = len("return [=[")
        end_idx = raw.rfind("]=]")
        raw = raw[start_idx:end_idx].strip()

    req_id = None
    cmd_name = None
    params = {}
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, dict):
            req_id = parsed.get("id")
            cmd_name = (parsed.get("command") or "").upper()
            params = parsed.get("params") or {}
    except Exception:
        parts = raw.split(None, 1)
        cmd_name = parts[0].upper() if parts else None
        rest = parts[1] if len(parts) > 1 else ""
        params = {"name": rest, "value": rest}

    if not cmd_name:
        return None

    if cmd_name in ("EXIT", "QUIT", "SHUTDOWN"):
        log_bridge("INFO", "Shutdown command received. Halting listener.")
        send_response(req_id, cmd_name, True, {"message": "Stopped gracefully"})
        return "EXIT"

    handler = COMMANDS.get(cmd_name)
    if not handler:
        err = f"Command not recognized or not permitted: '{cmd_name}'"
        log_bridge("WARN", err)
        send_response(req_id, cmd_name, False, None, err)
        return True

    log_bridge("EXEC", f"Executing: {cmd_name}")
    try:
        res = handler(params)
        log_bridge("OK", f"Command {cmd_name} completed successfully.")
        send_response(req_id, cmd_name, True, res)
    except Exception as e:
        log_bridge("ERROR", f"Command {cmd_name} failed: {e}")
        send_response(req_id, cmd_name, False, None, str(e))

    return True

def run():
    r = get_resolve()
    header = (
        "==================================================================\n"
        " DaVinci Resolve Free AI File-Polling Bridge (Python)\n"
        " Status: ACTIVE & LISTENING\n"
        f" Bridge Directory: {BRIDGE_DIR}\n"
        f" Watching Files:\n"
        f"   - JSON: {CMD_JSON}\n"
        f"   - TXT:  {CMD_TXT}\n"
    )
    if r:
        header += f" Connected To: {r.GetProductName()} v{r.GetVersionString()}\n"
    else:
        header += " Note: Running in standalone or unattached mode.\n"
    header += "=================================================================="
    print(header, flush=True)

    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} [STARTUP] Python listener initialized\n")
    except Exception:
        pass

    while True:
        try:
            if process_file(CMD_JSON) == "EXIT": break
            if process_file(CMD_TXT) == "EXIT": break
        except Exception as e:
            log_bridge("ERROR", f"Loop exception: {e}")
        time.sleep(0.25)

    log_bridge("INFO", "Python Bridge listener exited.")

# Start Listener
run()
