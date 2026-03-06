"""Text polishing pipeline for voice dictation.

Takes a raw speech-to-text transcript and produces polished written text
ready for injection. The pipeline has three stages:

1. **Substitute dictated punctuation** — deterministic regex replacements
   for spoken formatting commands ("new paragraph", "comma", "period")
   that the nano LLM handles unreliably. Newer symbol commands (ellipsis,
   ampersand, etc.) are wrapped in <keep> tags so the LLM preserves them.

2. **Skip heuristic** — if the transcript is already well-formed (proper
   capitalization, punctuation, no fillers or spelled-out numbers), skip
   the LLM entirely and return the text as-is. Saves 0.3–1.4s.

3. **LLM refinement** — send the transcript to a small model that removes
   fillers, fixes repetitions, formats lists and numbers, and adjusts
   tone based on optional app context. The model is instructed to preserve
   <keep> tags and their content verbatim. After the LLM responds, the
   tags are stripped, leaving only the symbols.
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
#
# Each entry is (pattern, replacement, protect). When protect is True the
# substituted symbol is wrapped in <keep>…</keep> tags so the LLM knows
# to preserve it verbatim. The original 18 patterns (period, comma, etc.)
# are well-understood by the LLM and don't need protection. The newer
# symbol commands (ellipsis, ampersand, asterisk, etc.) do, because
# gpt-4.1-nano tends to remove ellipsis, convert & to "and", reinterpret
# * as markdown, etc.
# ---------------------------------------------------------------------------

_DICTATED_PUNCT_SUBS: list[tuple[re.Pattern, str, bool]] = [
    # Paragraph and line breaks (must come before "period" to avoid
    # partial matches on "new paragraph period").
    (re.compile(r'\bnew paragraph\b', re.IGNORECASE), '\n\n', False),
    (re.compile(r'\bnew line\b', re.IGNORECASE), '\n', False),
    (re.compile(r'\bnewline\b', re.IGNORECASE), '\n', False),
    # Sentence-ending punctuation.
    (re.compile(r'\bperiod\b', re.IGNORECASE), '.', False),
    (re.compile(r'\bfull stop\b', re.IGNORECASE), '.', False),
    (re.compile(r'\bquestion mark\b', re.IGNORECASE), '?', False),
    (re.compile(r'\bexclamation point\b', re.IGNORECASE), '!', False),
    (re.compile(r'\bexclamation mark\b', re.IGNORECASE), '!', False),
    # Inline punctuation.
    (re.compile(r'\bcomma\b', re.IGNORECASE), ',', False),
    (re.compile(r'\bcolon\b', re.IGNORECASE), ':', False),
    (re.compile(r'\bsemicolon\b', re.IGNORECASE), ';', False),
    # Brackets and quotes.
    (re.compile(r'\bopen paren(?:thesis)?\b', re.IGNORECASE), '(', False),
    (re.compile(r'\bclose paren(?:thesis)?\b', re.IGNORECASE), ')', False),
    (re.compile(r'\bopen quote\b', re.IGNORECASE), '\u201c', False),
    (re.compile(r'\b(?:close|end) quote\b', re.IGNORECASE), '\u201d', False),
    (re.compile(r'\bunquote\b', re.IGNORECASE), '\u201d', False),
    (re.compile(r'\bopen bracket\b', re.IGNORECASE), '[', False),
    (re.compile(r'\bclose bracket\b', re.IGNORECASE), ']', False),
    # Symbols.
    # Only unambiguous commands are included here. Common English words
    # that also name symbols (tab, dash, hash, slash, star, equals) are
    # excluded because they collide with natural speech ("a dash of salt",
    # "close the tab", "five star review"). Users can say the longer
    # multi-word form or the technical name instead.
    (re.compile(r'\bdot dot dot\b', re.IGNORECASE), '\u2026', True),
    (re.compile(r'\bellipsis\b', re.IGNORECASE), '\u2026', True),
    (re.compile(r'\bhyphen\b', re.IGNORECASE), '-', True),
    (re.compile(r'\bampersand\b', re.IGNORECASE), '&', True),
    (re.compile(r'\bat sign\b', re.IGNORECASE), '@', True),
    (re.compile(r'\bhashtag\b', re.IGNORECASE), '#', True),
    (re.compile(r'\bforward slash\b', re.IGNORECASE), '/', True),
    (re.compile(r'\bbackslash\b', re.IGNORECASE), '\\', True),
    (re.compile(r'\basterisk\b', re.IGNORECASE), '*', True),
    (re.compile(r'\bunderscore\b', re.IGNORECASE), '_', True),
    (re.compile(r'\bpercent sign\b', re.IGNORECASE), '%', True),
    (re.compile(r'\bdollar sign\b', re.IGNORECASE), '$', True),
    (re.compile(r'\bequals sign\b', re.IGNORECASE), '=', True),
    (re.compile(r'\bplus sign\b', re.IGNORECASE), '+', True),
]

# Keep-tag pattern for stripping after LLM.
_KEEP_TAG_PATTERN = re.compile(r'<keep>(.*?)</keep>')


def substitute_dictated_punctuation(text: str) -> str:
    """Replace spoken punctuation commands with actual symbols.

    Protected symbols are wrapped in <keep> tags so the LLM preserves
    them. Returns the text with substitutions applied and whitespace
    cleaned up.
    """
    for pattern, replacement, protect in _DICTATED_PUNCT_SUBS:
        if protect:
            # Use a function to avoid re.sub interpreting backslash in
            # the replacement string.
            def _wrap(m: re.Match, _r: str = replacement) -> str:
                return f'<keep>{_r}</keep>'
            text = pattern.sub(_wrap, text)
        else:
            text = pattern.sub(replacement, text)

    # Clean up whitespace around punctuation introduced by substitution.
    # Remove spaces before punctuation that attaches to the preceding word.
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
    # Capitalize very first character (skip if it starts with a tag).
    if text and text[0].isalpha():
        text = text[0].upper() + text[1:]

    return text.strip()


def strip_keep_tags(text: str) -> str:
    """Remove <keep> tags, leaving their content in place.

    Also cleans up whitespace around the revealed symbols:
    - Hyphens, @, /, \\ attach on both sides (no spaces).
    - # and $ attach to the following word (no space after).
    - % and ellipsis attach to the preceding word (no space before).
    """
    text = _KEEP_TAG_PATTERN.sub(r'\1', text)

    # Clean up whitespace around symbols that were inside tags.
    text = re.sub(r' +([.,;:?!\)\]\u201d\u2026%])', r'\1', text)
    text = re.sub(r'([\(\[\u201c#$]) +', r'\1', text)
    text = re.sub(r' *([\-@/\\]) +', r'\1', text)
    text = re.sub(r' {2,}', ' ', text)

    return text


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
    r'|dot dot dot|ellipsis'
    r'|hyphen'
    r'|ampersand|at sign'
    r'|hashtag'
    r'|forward slash|backslash'
    r'|asterisk|underscore'
    r'|percent sign|dollar sign'
    r'|equals sign|plus sign'
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
       Protected symbols are wrapped in <keep> tags.
    2. Skip LLM if the transcript is already clean.
    3. Call the LLM for filler removal, list formatting, etc.
       The LLM preserves <keep> tags and their content.
    4. Strip <keep> tags and clean up whitespace.

    Returns the raw text as fallback if the LLM call fails.
    """
    trimmed = raw_text.strip()
    if not trimmed:
        return raw_text

    # Stage 1: deterministic punctuation substitution.
    # Protected symbols are wrapped in <keep>…</keep> tags.
    trimmed = substitute_dictated_punctuation(trimmed)

    # Stage 2: skip heuristic.
    # Strip <keep> tags before checking so they don't interfere with
    # the clean-text heuristics (tags would fail starts-upper, etc.).
    text_for_check = strip_keep_tags(trimmed)
    if is_clean(text_for_check):
        print("[polish] Skipping LLM (transcript is clean)")
        return text_for_check

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
                return strip_keep_tags(polished)
    except Exception as e:
        print(f"[polish] LLM call failed, using raw transcription: {e}")

    return strip_keep_tags(trimmed)
