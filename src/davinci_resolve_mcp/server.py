"""MCP server exposing DaVinci Resolve (via the CustomAILink bridge) as tools."""

from typing import Optional

from mcp.server.fastmcp import FastMCP

from .client import send_command

mcp = FastMCP("davinci-resolve")


@mcp.tool()
def ping() -> dict:
    """Check that the bridge is running inside DaVinci Resolve."""
    return send_command("PING")


@mcp.tool()
def get_status() -> dict:
    """Get Resolve version, current page, open project and active timeline."""
    return send_command("GET_STATUS")


@mcp.tool()
def save_project() -> dict:
    """Save the currently open project."""
    return send_command("SAVE_PROJECT")


@mcp.tool()
def list_projects() -> dict:
    """List projects in the current database folder."""
    return send_command("LIST_PROJECTS")


@mcp.tool()
def create_project(name: str) -> dict:
    """Create a new project."""
    return send_command("CREATE_PROJECT", {"name": name})


@mcp.tool()
def load_project(name: str) -> dict:
    """Load an existing project by name."""
    return send_command("LOAD_PROJECT", {"name": name})


@mcp.tool()
def open_page(page: str) -> dict:
    """Switch page: media, cut, edit, fusion, color, fairlight or deliver."""
    return send_command("OPEN_PAGE", {"page": page})


@mcp.tool()
def create_timeline(name: Optional[str] = None) -> dict:
    """Create an empty timeline in the current project."""
    return send_command("CREATE_TIMELINE", {"name": name} if name else {})


@mcp.tool()
def get_timelines() -> dict:
    """List all timelines in the current project."""
    return send_command("GET_TIMELINES")


@mcp.tool()
def set_current_timeline(name: Optional[str] = None, index: Optional[int] = None) -> dict:
    """Activate a timeline by name or 1-based index."""
    params = {}
    if name is not None:
        params["name"] = name
    if index is not None:
        params["index"] = index
    return send_command("SET_CURRENT_TIMELINE", params)


@mcp.tool()
def get_current_time() -> dict:
    """Get the playhead timecode of the active timeline."""
    return send_command("GET_CURRENT_TIME")


@mcp.tool()
def set_current_time(timecode: str) -> dict:
    """Move the playhead, e.g. '01:00:10:00'."""
    return send_command("SET_CURRENT_TIME", {"timecode": timecode})


@mcp.tool()
def add_marker(
    frame_id: Optional[int] = None,
    color: str = "Blue",
    name: str = "AI Marker",
    note: str = "",
    duration: int = 1,
) -> dict:
    """Add a marker to the active timeline (defaults to the start frame)."""
    params = {"color": color, "name": name, "note": note, "duration": duration}
    if frame_id is not None:
        params["frameId"] = frame_id
    return send_command("ADD_MARKER", params)


@mcp.tool()
def get_markers() -> dict:
    """Get markers on the active timeline."""
    return send_command("GET_MARKERS")


@mcp.tool()
def delete_marker(frame_id: int) -> dict:
    """Delete the marker at a frame."""
    return send_command("DELETE_MARKER", {"frameId": frame_id})


@mcp.tool()
def import_media(paths: list[str]) -> dict:
    """Import media files (absolute paths) into the Media Pool."""
    return send_command("IMPORT_MEDIA", {"paths": paths}, timeout=60)


@mcp.tool()
def create_bin(name: str) -> dict:
    """Create a Media Pool bin."""
    return send_command("CREATE_BIN", {"name": name})


@mcp.tool()
def start_render() -> dict:
    """Start rendering the current render queue."""
    return send_command("START_RENDER")


@mcp.tool()
def stop_render() -> dict:
    """Stop the active render."""
    return send_command("STOP_RENDER")


@mcp.tool()
def get_render_status() -> dict:
    """Check whether a render is in progress."""
    return send_command("GET_RENDER_STATUS")


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
