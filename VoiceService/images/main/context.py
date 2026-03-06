"""Application context for voice dictation.

The AppContext dataclass captures information about the target application
at the moment of dictation: which app is focused, the window title, any
browser URL, and the state of the text field. This context travels from
the Swift client to the server alongside the audio, and is used as a
light signal for tone adjustment during text polishing.
"""

import json
from dataclasses import dataclass
from typing import Optional


@dataclass
class AppContext:
    """Application context captured at the moment of dictation."""

    bundle_id: str = ""
    app_name: str = ""
    window_title: str = ""
    browser_url: Optional[str] = None
    focused_field_content: Optional[str] = None
    selected_text: Optional[str] = None
    cursor_position: Optional[int] = None


def parse_json(raw: str) -> AppContext:
    """Parse a JSON string into an AppContext, returning empty on failure."""
    if not raw:
        return AppContext()
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return AppContext()
    if not isinstance(data, dict):
        return AppContext()
    return _from_dict(data)


def parse_dict(data: Optional[dict]) -> AppContext:
    """Parse a dict into an AppContext, returning empty on failure."""
    if not data or not isinstance(data, dict):
        return AppContext()
    return _from_dict(data)


def _from_dict(data: dict) -> AppContext:
    """Build an AppContext from a validated dict."""
    return AppContext(
        bundle_id=data.get("bundle_id", ""),
        app_name=data.get("app_name", ""),
        window_title=data.get("window_title", ""),
        browser_url=data.get("browser_url"),
        focused_field_content=data.get("focused_field_content"),
        selected_text=data.get("selected_text"),
        cursor_position=data.get("cursor_position"),
    )
