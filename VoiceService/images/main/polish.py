"""Text polishing pipeline for voice dictation.

Takes a raw speech-to-text transcript and produces polished written text
ready for injection. The pipeline has three stages:

1. **Substitute dictated punctuation** — deterministic regex replacements
   for spoken formatting commands ("new paragraph", "comma", "period")
   that the nano LLM handles unreliably.

2. **Skip heuristic** — if the transcript is already well-formed (proper
   capitalization, punctuation, no fillers or spelled-out numbers), skip
   the LLM entirely and return the text as-is. Saves 0.3–1.4s.

3. **LLM refinement** — send the transcript to a small model that removes
   fillers, fixes repetitions, formats lists and numbers, and adjusts
   tone based on optional app context.
"""

import os
import re
from typing import Optional

from autonomy import Model

from context import AppContext


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

POLISH_MODEL = "gpt-4.1-nano"


# ---------------------------------------------------------------------------
# System prompt (loaded once at import time)
# ---------------------------------------------------------------------------

def _load_prompt() -> str:
    """Load the system prompt from polish_prompt.txt."""
    prompt_path = os.path.join(os.path.dirname(__file__), "polish_prompt.txt")
    with open(prompt_path) as f:
        return f.read()


SYSTEM_PROMPT = _load_prompt()


# ---------------------------------------------------------------------------
# Stage 1: Dictated punctuation substitution
#
# The nano model cannot reliably distinguish spoken formatting commands
# ("new paragraph", "comma", "period") from literal content. These are
# unambiguous substitutions that don't need LLM judgment, so we handle
# them with regex before the LLM sees the text.
# ---------------------------------------------------------------------------

_DICTATED_PUNCT_SUBS: list[tuple[re.Pattern, str]] = [
    # Paragraph and line breaks (must come before "period" to avoid
    # partial matches on "new paragraph period").
    (re.compile(r'\bnew paragraph\b', re.IGNORECASE), '\n\n'),
    (re.compile(r'\bnew line\b', re.IGNORECASE), '\n'),
    (re.compile(r'\bnewline\b', re.IGNORECASE), '\n'),
    # Sentence-ending punctuation.
    (re.compile(r'\bperiod\b', re.IGNORECASE), '.'),
    (re.compile(r'\bfull stop\b', re.IGNORECASE), '.'),
    (re.compile(r'\bquestion mark\b', re.IGNORECASE), '?'),
    (re.compile(r'\bexclamation point\b', re.IGNORECASE), '!'),
    (re.compile(r'\bexclamation mark\b', re.IGNORECASE), '!'),
    # Inline punctuation.
    (re.compile(r'\bcomma\b', re.IGNORECASE), ','),
    (re.compile(r'\bcolon\b', re.IGNORECASE), ':'),
    (re.compile(r'\bsemicolon\b', re.IGNORECASE), ';'),
    # Brackets and quotes.
    (re.compile(r'\bopen paren(?:thesis)?\b', re.IGNORECASE), '('),
    (re.compile(r'\bclose paren(?:thesis)?\b', re.IGNORECASE), ')'),
    (re.compile(r'\bopen quote\b', re.IGNORECASE), '\u201c'),
    (re.compile(r'\b(?:close|end) quote\b', re.IGNORECASE), '\u201d'),
    (re.compile(r'\bunquote\b', re.IGNORECASE), '\u201d'),
    (re.compile(r'\bopen bracket\b', re.IGNORECASE), '['),
    (re.compile(r'\bclose bracket\b', re.IGNORECASE), ']'),
]


def substitute_dictated_punctuation(text: str) -> str:
    """Replace spoken punctuation commands with actual symbols.

    Returns the text with substitutions applied and whitespace cleaned up.
    """
    for pattern, replacement in _DICTATED_PUNCT_SUBS:
        text = pattern.sub(replacement, text)

    # Clean up whitespace around punctuation introduced by substitution.
    # Remove spaces before punctuation marks.
    text = re.sub(r' +([.,;:?!\)\]\u201d])', r'\1', text)
    # Remove spaces after opening brackets/quotes.
    text = re.sub(r'([\(\[\u201c]) +', r'\1', text)
    # Collapse multiple spaces.
    text = re.sub(r' {2,}', ' ', text)
    # Trim whitespace around line breaks.
    text = re.sub(r' *\n *', '\n', text)
    # Capitalize first letter after sentence-ending punctuation + space/newline.
    def _capitalize_after(m: re.Match) -> str:
        return m.group(1) + m.group(2).upper()
    text = re.sub(r'([.?!]\s+)(\w)', _capitalize_after, text)
    # Capitalize very first character.
    if text and text[0].isalpha():
        text = text[0].upper() + text[1:]

    return text.strip()


# ---------------------------------------------------------------------------
# Stage 2: Clean transcript detection
# ---------------------------------------------------------------------------

# Filler words and verbal corrections that indicate messy speech.
_FILLER_PATTERN = re.compile(
    r'\b('
    r'um+|uh+|er+|ah+|hmm+'
    r'|you know|I mean'
    r'|no wait|no,? wait'
    r'|actually,? (?:no|wait)'
    r'|sorry,? I mean'
    r'|let me rephrase'
    r')\b',
    re.IGNORECASE,
)

# Dictated punctuation that should be converted to actual marks.
_DICTATED_PUNCT_PATTERN = re.compile(
    r'\b('
    r'period|comma|question mark|exclamation (?:point|mark)'
    r'|colon|semicolon'
    r'|new line|newline|new paragraph'
    r'|open (?:paren|parenthesis|quote|bracket)'
    r'|close (?:paren|parenthesis|quote|bracket)'
    r'|(?:end |un)quote'
    r')\b',
    re.IGNORECASE,
)

# Repeated consecutive words or short phrases: "I think I think".
_REPETITION_PATTERN = re.compile(
    r'\b(\w+(?:\s+\w+){0,2})\s+\1\b',
    re.IGNORECASE,
)

# Spelled-out numbers that the LLM would format as digits.
_SPELLED_NUMBER_PATTERN = re.compile(
    r'\b('
    r'zero|one|two|three|four|five|six|seven|eight|nine|ten'
    r'|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen'
    r'|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy'
    r'|eighty|ninety|hundred|thousand|million|billion|trillion'
    r'|percent|dollar|dollars'
    r')\b',
    re.IGNORECASE,
)


def is_clean(text: str) -> bool:
    """Check if a transcript is clean enough to skip LLM polishing.

    Returns True when the text has no markers that the LLM would fix:
    no filler words, no dictated punctuation, no repeated phrases, no
    spelled-out numbers, starts capitalized, and ends with sentence
    punctuation.

    Conservative: when in doubt, return False so the LLM gets called.
    """
    if not text:
        return False

    # Must start with an uppercase letter.
    if text[0].islower():
        return False

    # Must end with sentence-final punctuation.
    if text[-1] not in '.!?':
        return False

    if _FILLER_PATTERN.search(text):
        return False

    if _DICTATED_PUNCT_PATTERN.search(text):
        return False

    if _REPETITION_PATTERN.search(text):
        return False

    if _SPELLED_NUMBER_PATTERN.search(text):
        return False

    return True


# ---------------------------------------------------------------------------
# Stage 3: LLM refinement
# ---------------------------------------------------------------------------

def _build_user_prompt(text: str, context: AppContext) -> str:
    """Build the user prompt for the LLM polishing call."""
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


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

async def polish_text(raw_text: str, context: AppContext) -> str:
    """Refine a raw transcription into polished written text.

    Runs the full three-stage pipeline:
    1. Substitute dictated punctuation (regex, deterministic).
    2. Skip LLM if the transcript is already clean.
    3. Call the LLM for filler removal, list formatting, etc.

    Returns the raw text as fallback if the LLM call fails.
    """
    trimmed = raw_text.strip()
    if not trimmed:
        return raw_text

    # Stage 1: deterministic punctuation substitution.
    trimmed = substitute_dictated_punctuation(trimmed)

    # Stage 2: skip heuristic.
    if is_clean(trimmed):
        print("[polish] Skipping LLM (transcript is clean)")
        return trimmed

    # Stage 3: LLM refinement.
    llm = Model(POLISH_MODEL)
    user_prompt = _build_user_prompt(trimmed, context)
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": user_prompt},
    ]

    try:
        response = await llm.complete_chat(messages, stream=False)
        if hasattr(response, "choices") and len(response.choices) > 0:
            polished = response.choices[0].message.content.strip()
            if polished:
                return polished
    except Exception as e:
        print(f"[polish] LLM call failed, using raw transcription: {e}")

    return trimmed
