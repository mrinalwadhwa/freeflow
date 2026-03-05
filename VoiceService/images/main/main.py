"""Voice dictation service.

Expose a /dictate endpoint that accepts a WAV audio file and application
context, and returns polished text ready for injection. If cleanup fails,
the raw transcription is returned as fallback.
"""

import json
import os

from dataclasses import dataclass
from typing import Optional

from autonomy import HttpServer, Model, Node
from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

app = FastAPI()
security = HTTPBearer()

API_KEY = os.environ.get("API_KEY", "")


def verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)):
    """Verify the bearer token matches the configured API key."""
    if not API_KEY:
        raise HTTPException(status_code=500, detail="Server API key not configured")
    if credentials.credentials != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return credentials


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

STT_MODEL = "whisper-1"
COMPOSE_MODEL = "claude-sonnet-4-5"


# ---------------------------------------------------------------------------
# Composition prompt
# ---------------------------------------------------------------------------


COMPOSE_SYSTEM_PROMPT = """\
You are a voice-to-text cleanup assistant. The user dictated text and a \
speech-to-text engine transcribed it. Your job is to clean up the \
transcription into polished written text.

Speech-to-text engines produce messy output. Fix these problems:

1. Filler words and false starts: remove "um", "uh", "like", "you know", \
"I mean", and similar verbal fillers.
2. Repetitions: "I think I think we should" becomes "I think we should".
3. Mid-sentence corrections: when the speaker restarts or says "no wait", \
"actually", "I mean", or "sorry", keep only the corrected version. \
For example "send it to John no wait send it to Sarah" becomes \
"send it to Sarah".
4. Punctuation and capitalization: add proper sentence punctuation, \
capitalize sentence starts, and fix obvious capitalization (proper \
nouns, "I", etc.).
5. Lists: when the speaker dictates items in sequence ("first X second Y \
third Z" or "one X two Y three Z"), format as a list.
6. Numbers and formatting: "twenty three point five percent" becomes \
"23.5%", "twelve dollars" becomes "$12", etc.
7. Dictated punctuation: "period", "comma", "question mark", \
"exclamation point", "new line", "new paragraph" should be converted \
to the actual punctuation or whitespace.

Preserve the user's meaning exactly. Do not add content, opinions, or \
rephrase beyond cleanup. If the transcription is already clean, return \
it unchanged.

Do not wrap your output in quotes or add any preamble. Return only the \
cleaned text.

Keep the same language as the transcription. Do not translate.

You may also receive context about the target application (app name, \
window title, field content). Use it as a light signal for tone: \
keep email formal, chat casual, code comments technical. But do not \
over-adapt. The cleanup rules above are the priority.
"""


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


def build_compose_prompt(text: str, context: AppContext) -> str:
    """Build the user prompt for the composition LLM call."""
    parts = [f"Transcription:\n{text}"]

    ctx_lines = []
    if context.app_name:
        ctx_lines.append(f"App: {context.app_name}")
    if context.window_title:
        ctx_lines.append(f"Window: {context.window_title}")
    if context.browser_url:
        ctx_lines.append(f"URL: {context.browser_url}")
    if context.focused_field_content is not None:
        # Show a truncated view of the field content around the cursor to
        # keep the prompt compact while giving the model enough context.
        content = context.focused_field_content
        if len(content) > 2000:
            original_len = len(content)
            pos = context.cursor_position or original_len
            start = max(0, pos - 1000)
            end = min(original_len, pos + 1000)
            content = content[start:end]
            if start > 0:
                content = "..." + content
            if end < original_len:
                content = content + "..."
        ctx_lines.append(f"Field content:\n{content}")
    if context.cursor_position is not None:
        ctx_lines.append(f"Cursor position: {context.cursor_position}")
    if context.selected_text:
        ctx_lines.append(f"Selected text: {context.selected_text}")

    if ctx_lines:
        parts.append("Context:\n" + "\n".join(ctx_lines))

    return "\n\n".join(parts)


async def compose_text(raw_text: str, context: AppContext) -> str:
    """Refine raw transcription via LLM. Returns raw text on failure."""
    trimmed = raw_text.strip()
    if not trimmed:
        return raw_text

    llm = Model(COMPOSE_MODEL)
    user_prompt = build_compose_prompt(trimmed, context)
    messages = [
        {"role": "system", "content": COMPOSE_SYSTEM_PROMPT},
        {"role": "user", "content": user_prompt},
    ]

    try:
        response = await llm.complete_chat(messages, stream=False)
        if hasattr(response, "choices") and len(response.choices) > 0:
            composed = response.choices[0].message.content.strip()
            if composed:
                return composed
    except Exception as e:
        print(f"[compose] LLM composition failed, using raw transcription: {e}")

    return trimmed


# ---------------------------------------------------------------------------
# Dictate (STT + composition in one call)
# ---------------------------------------------------------------------------


def parse_context(raw: str) -> AppContext:
    """Parse a JSON string into an AppContext, returning empty on failure."""
    if not raw:
        return AppContext()
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return AppContext()
    if not isinstance(data, dict):
        return AppContext()
    return AppContext(
        bundle_id=data.get("bundle_id", ""),
        app_name=data.get("app_name", ""),
        window_title=data.get("window_title", ""),
        browser_url=data.get("browser_url"),
        focused_field_content=data.get("focused_field_content"),
        selected_text=data.get("selected_text"),
        cursor_position=data.get("cursor_position"),
    )


@app.post("/dictate")
async def dictate(
    file: UploadFile = File(...),
    context: str = Form("{}"),
    language: Optional[str] = Form(None),
    _credentials=Depends(verify_token),
):
    """Convert spoken audio into clean written text.

    Accept a WAV audio file and application context. Returns polished
    text ready for injection. The raw transcription is also included
    for logging.
    """
    audio_bytes = await file.read()
    if not audio_bytes:
        raise HTTPException(status_code=400, detail="Empty audio file")

    model = Model(STT_MODEL)
    try:
        raw_text = await model.speech_to_text(
            audio_file=("recording.wav", audio_bytes),
            language=language,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Transcription failed: {e}")

    if not raw_text or not raw_text.strip():
        return {"text": "", "raw": ""}

    app_context = parse_context(context)
    composed = await compose_text(raw_text, app_context)

    return {"text": composed, "raw": raw_text}


Node.start(http_server=HttpServer(app=app))
