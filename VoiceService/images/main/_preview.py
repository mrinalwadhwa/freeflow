"""
Minimal local preview server for viewing zone web pages.

Serves Jinja2 templates with mock data so you can preview the UI
without running the full FastAPI server, auth service, or database.

Usage:
    cd apps/voice/main/VoiceService/images/main
    source .venv/bin/activate
    python _preview.py

Then open http://127.0.0.1:5555/ in your browser.
"""

import http.server
import os
import urllib.parse
from datetime import datetime, timedelta
from jinja2 import Environment, FileSystemLoader

PORT = 5555
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
TEMPLATE_DIR = os.path.join(BASE_DIR, "templates")
STATIC_DIR = os.path.join(BASE_DIR, "static")

env = Environment(loader=FileSystemLoader(TEMPLATE_DIR))

# ---------------------------------------------------------------------------
# Mock data
# ---------------------------------------------------------------------------

MOCK_INVITES = [
    {
        "id": "inv-001",
        "label": "Design team",
        "token": "abc123",
        "max_uses": 5,
        "use_count": 2,
        "revoked": False,
        "expires_at": datetime.now() + timedelta(days=7),
        "created_at": datetime.now() - timedelta(days=1),
    },
    {
        "id": "inv-002",
        "label": "Engineering",
        "token": "def456",
        "max_uses": 1,
        "use_count": 1,
        "revoked": False,
        "expires_at": None,
        "created_at": datetime.now() - timedelta(days=5),
    },
    {
        "id": "inv-003",
        "label": "Old invite",
        "token": "ghi789",
        "max_uses": 3,
        "use_count": 1,
        "revoked": True,
        "expires_at": None,
        "created_at": datetime.now() - timedelta(days=14),
    },
]

MOCK_USERS = [
    {
        "id": "u-001",
        "name": "Alice Admin",
        "email": "alice@example.com",
        "has_email": True,
        "is_admin": True,
        "created_at": datetime.now() - timedelta(days=10),
    },
    {
        "id": "u-002",
        "name": "Bob Builder",
        "email": "bob@example.com",
        "has_email": True,
        "is_admin": False,
        "created_at": datetime.now() - timedelta(days=3),
    },
    {
        "id": "u-003",
        "name": "Carol",
        "email": None,
        "has_email": False,
        "is_admin": False,
        "created_at": datetime.now() - timedelta(days=1),
    },
]


class _Obj:
    """Dict wrapper that allows attribute access for Jinja2 templates."""

    def __init__(self, d):
        for k, v in d.items():
            setattr(self, k, v)

    def __getitem__(self, k):
        return getattr(self, k)

    def get(self, k, default=None):
        return getattr(self, k, default)


def obj_list(dicts):
    return [_Obj(d) for d in dicts]


COMMON_CTX = {
    "app_name": "Voice",
    "base_url": f"http://127.0.0.1:{PORT}",
    "admin_user": True,
    "flash_success": None,
    "flash_error": None,
}


def make_ctx(**extra):
    ctx = dict(COMMON_CTX)
    ctx.update(extra)
    return ctx


# ---------------------------------------------------------------------------
# Route table: path -> (template, extra context)
# ---------------------------------------------------------------------------

ROUTES = {
    "/": (
        "index.html",
        {
            "user_count": 3,
            "invite_count": 1,
            "with_email_count": 2,
            "used_invite_count": 1,
            "revoked_invite_count": 1,
        },
    ),
    "/public": (
        "index.html",
        {
            "admin_user": False,
        },
    ),
    "/invite/abc123": (
        "invite.html",
        {
            "token": "abc123",
            "token_valid": True,
            "token_error": None,
            "is_admin_token": False,
            "admin_user": None,
            "voice_url": "voice://connect?url=http://127.0.0.1:5555&token=abc123",
        },
    ),
    "/invite/admin": (
        "invite.html",
        {
            "token": "admin",
            "token_valid": True,
            "token_error": None,
            "is_admin_token": True,
            "admin_user": None,
            "voice_url": "voice://connect?url=http://127.0.0.1:5555&token=admin",
        },
    ),
    "/invite/invalid": (
        "invite.html",
        {
            "token": "invalid",
            "token_valid": False,
            "token_error": "This invite link has expired.",
            "is_admin_token": False,
            "admin_user": None,
        },
    ),
    "/admin/": (
        "admin/dashboard.html",
        {
            "nav_active": "dashboard",
            "user_count": 3,
            "with_email_count": 2,
            "invite_count": 1,
            "used_invite_count": 1,
            "revoked_invite_count": 1,
        },
    ),
    "/admin/invites": (
        "admin/invites.html",
        {
            "nav_active": "invites",
            "invites": obj_list(MOCK_INVITES),
        },
    ),
    "/admin/users": (
        "admin/users.html",
        {
            "nav_active": "users",
            "users": obj_list(MOCK_USERS),
        },
    ),
    "/admin/settings": (
        "admin/settings.html",
        {
            "nav_active": "settings",
        },
    ),
    "/onboarding/": (
        "onboarding/index.html",
        {
            "is_admin": True,
        },
    ),
    "/account/add-email": (
        "account/add-email.html",
        {},
    ),
    "/account/sign-in": (
        "account/sign-in.html",
        {},
    ),
}


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------


class PreviewHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        # Serve static files
        if path.startswith("/static/"):
            rel = path[len("/static/"):]
            fpath = os.path.join(STATIC_DIR, rel)
            if os.path.isfile(fpath):
                self.send_response(200)
                if fpath.endswith(".css"):
                    self.send_header("Content-Type", "text/css; charset=utf-8")
                elif fpath.endswith(".js"):
                    self.send_header("Content-Type", "application/javascript; charset=utf-8")
                else:
                    self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                with open(fpath, "rb") as f:
                    self.wfile.write(f.read())
                return

        # Serve template routes
        if path in ROUTES:
            template_name, extra = ROUTES[path]
            ctx = make_ctx(**extra)
            try:
                tmpl = env.get_template(template_name)
                html = tmpl.render(**ctx)
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                self.wfile.write(html.encode("utf-8"))
            except Exception as e:
                self.send_response(500)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(f"Template error: {e}".encode("utf-8"))
            return

        # Index page listing all routes
        if path == "/routes":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            links = "".join(
                f'<li><a href="{r}">{r}</a> &rarr; {t}</li>'
                for r, (t, _) in sorted(ROUTES.items())
            )
            self.wfile.write(
                f"<h1>Preview Routes</h1><ul>{links}</ul>".encode("utf-8")
            )
            return

        self.send_response(404)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"404 Not Found. Try /routes for a list.")

    def log_message(self, format, *args):
        # Simpler log line
        print(f"  {args[0]}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), PreviewHandler)
    print(f"Preview server running at http://127.0.0.1:{PORT}/")
    print(f"Route index: http://127.0.0.1:{PORT}/routes")
    print()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
