"""Voice transcription service.

Expose a /transcribe endpoint that accepts audio and returns text.
Internally delegates to the Autonomy gateway speech-to-text API.
"""

import os

from autonomy import HttpServer, Model, Node
from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from typing import Optional

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


@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    model: str = Form("whisper-1"),
    language: Optional[str] = Form(None),
    _credentials=Depends(verify_token),
):
    """Transcribe audio to text.

    Accept a WAV audio file and return the transcribed text.
    """
    audio_bytes = await file.read()
    if not audio_bytes:
        raise HTTPException(status_code=400, detail="Empty audio file")

    stt_model = Model(model)
    try:
        text = await stt_model.speech_to_text(
            audio_file=("recording.wav", audio_bytes),
            language=language,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Transcription failed: {e}")

    return {"text": text}


Node.start(http_server=HttpServer(app=app))
