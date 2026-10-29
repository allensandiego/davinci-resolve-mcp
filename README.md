# DaVinci Resolve Free Edition AI Bridge

A transparent, zero-dependency, local file-polling bridge that allows external AI agents, MCP servers, and CLI tools to control **DaVinci Resolve Free** (and Studio).

Unlike the Studio edition, the Free version blocks external Python connections (`DaVinciResolveScript`) and the built-in MCP server. This project bypasses that restriction securely using native Lua scripting and local atomic file transactions—**no third-party extensions, no network sockets, and no compiled binaries required.**

---

## 🚀 How It Works

1. The **Lua Script** ([`CustomAILink.lua`](lua/CustomAILink.lua)) runs inside DaVinci Resolve's native Lua scripting engine.
2. It uses non-blocking polling (`bmd.wait()`) every 250ms, yielding execution so Resolve's user interface never stutters or freezes.
3. Your **AI Agent / CLI / MCP Server** writes a command to the bridge directory:
   - **Structured JSON**: `resolve_cmd.json` (includes request `id`, `command`, and typed `params`).
   - **Plain Text**: `resolve_cmd.txt` (simple single-line commands).
4. Resolve reads the command, verifies it against an **allowlist**, safely executes the operation via the official Resolve API, and atomically writes the result to `resolve_resp.json`.

---

## 🛠️ Installation & Setup

### Step 1: Copy the Script to Resolve
On macOS/Linux, run `scripts/install_lua.sh` to copy it into the per-user `Scripts/Utility` folder. Otherwise copy [`lua/CustomAILink.lua`](lua/CustomAILink.lua) manually to your DaVinci Resolve scripts directory:

* **macOS:**
  - *Utility (accessible from all pages - Recommended):*  
    `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/`
  - *Comp (Fusion page):*  
    `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Comp/`
* **Windows:**
  - *Utility (Recommended):*  
    `%APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility\`
  - *Comp:*  
    `%APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Comp\`
* **Linux:**
  - *Utility:*  
    `$HOME/.local/share/DaVinciResolve/Fusion/Scripts/Utility/`

### Step 2: Start the Bridge
1. Open DaVinci Resolve Free and load any project.
2. In the top menu, go to **Workspace > Scripts > Utility > CustomAILink** (or **Scripts > Comp > CustomAILink**).
3. The DaVinci Resolve Console will open, displaying:
   ```text
   ==================================================================
    DaVinci Resolve Free AI File-Polling Bridge (CustomAILink)
    Status: ACTIVE & LISTENING
    Bridge Directory: /tmp/davinci_resolve_bridge
    Watching Files:
      - JSON: /tmp/davinci_resolve_bridge/resolve_cmd.json
      - TXT:  /tmp/davinci_resolve_bridge/resolve_cmd.txt
    Connected To: DaVinci Resolve v...
   ==================================================================
   ```

---

## 🤖 Interacting with the Bridge

### 1. Structured JSON (Recommended for AI Agents & MCP Servers)

Write to `/tmp/davinci_resolve_bridge/resolve_cmd.json` (or `%TEMP%\davinci_resolve_bridge\resolve_cmd.json` on Windows):

```json
{
  "id": "req-001",
  "command": "CREATE_TIMELINE",
  "params": {
    "name": "Rough Cut - Episode 1"
  }
}
```

Resolve executes the command and atomically writes `/tmp/davinci_resolve_bridge/resolve_resp.json`:

```json
{
  "id": "req-001",
  "command": "CREATE_TIMELINE",
  "status": "success",
  "data": {
    "created": true,
    "timeline_name": "Rough Cut - Episode 1",
    "current_timecode": "01:00:00:00",
    "start_frame": 86400
  },
  "error": null,
  "timestamp": 1730172900
}
```

### 2. Quick Plain Text (CLI / Terminal)

You can also send quick terminal commands directly:

```bash
# macOS / Linux
echo "CREATE_TIMELINE Rough Cut" > /tmp/resolve_cmd.txt
echo "SAVE_PROJECT" > /tmp/resolve_cmd.txt
echo "OPEN_PAGE edit" > /tmp/resolve_cmd.txt

# Windows (Command Prompt)
echo CREATE_TIMELINE Rough Cut > %TEMP%\resolve_cmd.txt
echo SAVE_PROJECT > %TEMP%\resolve_cmd.txt
```

---

## 🔌 MCP Server & CLI

The Python package wraps the bridge and exposes every command as a typed MCP tool.
It requires the Lua bridge to be running inside Resolve.

```bash
python3 -m venv .venv
.venv/bin/pip install -e .          # add '.[dev]' to run the tests
```

Add to your MCP client config (e.g. Claude Desktop), using the absolute path:

```json
{
  "mcpServers": {
    "davinci-resolve": {
      "command": "/path/to/davinci-resolve-mcp/.venv/bin/davinci-resolve-mcp"
    }
  }
}
```

Test the bridge by hand:

```bash
.venv/bin/resolve-cli ping
.venv/bin/resolve-cli create_timeline '{"name": "Rough Cut"}'
```

Run the tests (they launch the Lua bridge under Resolve's `fuscript`; set `FUSCRIPT` if it is installed elsewhere):

```bash
.venv/bin/pytest
```

Set `DAVINCI_BRIDGE_DIR` to override the bridge directory (must match on both sides).

## 🗂️ Project Layout

```text
lua/CustomAILink.lua        Resolve-side bridge (runs inside Resolve)
src/davinci_resolve_mcp/    Python package: client.py, server.py (MCP), cli.py
tests/                      pytest integration tests (use fuscript)
scripts/install_lua.sh      Installs the Lua script into Resolve
```

---

## 📜 Supported Command Reference

| Command | Parameters | Description |
|---|---|---|
| `PING` | *none* | Health check; returns product version, bridge directory, and Studio flag. |
| `GET_STATUS` | *none* | Retrieves active project status, timeline count, active timeline, and current page. |
| `SAVE_PROJECT` | *none* | Saves the currently open project. |
| `LIST_PROJECTS` | *none* | Lists all projects in the current database folder. |
| `CREATE_PROJECT` | `{"name": "string"}` | Creates a new project in the active database folder. |
| `LOAD_PROJECT` | `{"name": "string"}` | Loads a project by name. |
| `OPEN_PAGE` | `{"page": "edit"}` | Switches workspace page (`media`, `cut`, `edit`, `fusion`, `color`, `fairlight`, `deliver`). |
| `CREATE_TIMELINE` | `{"name": "string"}` | Creates an empty timeline in the active project. |
| `GET_TIMELINES` | *none* | Returns a list of all timelines, their start/end frames, and current timecodes. |
| `SET_CURRENT_TIMELINE` | `{"name": "string"}` or `{"index": number}` | Activates the specified timeline. |
| `GET_CURRENT_TIME` | *none* | Gets current playhead timecode and frame bounds. |
| `SET_CURRENT_TIME` | `{"timecode": "01:00:10:00"}` | Moves the playhead to the specified timecode. |
| `ADD_MARKER` | `{"frameId": int, "color": "Blue", "name": "...", "note": "..."}` | Adds a marker to the active timeline. Colors: Blue, Cyan, Green, Yellow, Red, Pink, Purple, Fuchsia, Rose, Lavender, Sky, Mint, Lemon, Sand, Cocoa, Cream. |
| `GET_MARKERS` | *none* | Returns all markers on the current timeline. |
| `DELETE_MARKER` | `{"frameId": int}` | Removes a marker at the specified frame ID. |
| `IMPORT_MEDIA` | `{"paths": ["/path/to/clip.mp4"]}` | Imports media files into the active project's Media Pool. |
| `CREATE_BIN` | `{"name": "B-Roll"}` | Creates a subfolder/bin inside the Media Pool. |
| `START_RENDER` | *none* | Starts rendering the current render queue. |
| `STOP_RENDER` | *none* | Stops an active render job. |
| `GET_RENDER_STATUS`| *none* | Checks if rendering is currently in progress. |
| `EXIT` | *none* | Gracefully stops the listener loop inside Resolve. |

---

## 🛡️ Security & Hardening

1. **Strict Command Allowlist**: All incoming commands are dispatched through a fixed whitelist table. The bridge rejects any unknown commands and **never** evaluates dynamic code via `loadstring` or `os.execute`.
2. **Protected Error Isolation (`pcall`)**: Every Resolve API interaction runs within protected calls. Unhandled API errors or missing open projects return structured error payloads without crashing the listener loop.
3. **Atomic File Operations**: Responses are written to temporary files (`.tmp`) and swapped atomically using rename semantics to prevent race conditions or half-read payloads by client agents.
4. **Zero Network Attack Surface**: Communicates strictly via local filesystem transactions in secure temporary directories (`/tmp/davinci_resolve_bridge` or `%TEMP%`).

---

## 📄 License
MIT License.
