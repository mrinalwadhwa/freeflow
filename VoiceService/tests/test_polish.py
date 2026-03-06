#!/usr/bin/env python3
"""Test harness for polish prompt tuning.

Sends a battery of test transcripts to the /polish endpoint and checks
each result against structural validators. Each test case runs N times
(default 5) to surface non-deterministic LLM behavior.

Usage:
    # From VoiceService/:
    export VOICE_API_KEY="$(grep API_KEY secrets.yaml | cut -d' ' -f2)"
    export VOICE_SERVICE_URL="https://a9eb812238f753132652ae09963a05e9-voice.cluster.autonomy.computer"
    python3 tests/test_polish.py

    # Run a single category:
    python3 tests/test_polish.py --category lists-unordered

    # Run a single test by name:
    python3 tests/test_polish.py --name "grocery list"

    # Adjust repetitions (default 5):
    python3 tests/test_polish.py --reps 10

    # Show full output for every run (not just failures):
    python3 tests/test_polish.py --verbose
"""

import argparse
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from typing import Callable, Optional

try:
    import requests
except ImportError:
    print("ERROR: requests package required. Install with: pip3 install requests")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

BASE_URL = os.environ.get(
    "VOICE_SERVICE_URL",
    "https://a9eb812238f753132652ae09963a05e9-voice.cluster.autonomy.computer",
)
API_KEY = os.environ.get("VOICE_API_KEY", "")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def call_polish(text: str, context: Optional[dict] = None) -> str:
    """Call the /polish endpoint and return the polished text."""
    if not API_KEY:
        print("ERROR: VOICE_API_KEY not set.")
        sys.exit(1)

    url = f"{BASE_URL.rstrip('/')}/polish"
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json",
    }
    body = {"text": text}
    if context:
        body["context"] = context

    resp = requests.post(url, headers=headers, json=body, timeout=30)
    resp.raise_for_status()
    return resp.json()["text"]


# ---------------------------------------------------------------------------
# Validators
#
# Each validator is a callable(output: str) -> (bool, str).
# Returns (passed, reason).
# ---------------------------------------------------------------------------


def contains(substring: str) -> Callable[[str], tuple[bool, str]]:
    """Output must contain the substring (case-insensitive)."""
    def check(output: str) -> tuple[bool, str]:
        if substring.lower() in output.lower():
            return True, ""
        return False, f"expected to contain '{substring}'"
    check.__name__ = f"contains({substring!r})"
    return check


def not_contains(substring: str) -> Callable[[str], tuple[bool, str]]:
    """Output must NOT contain the substring (case-insensitive)."""
    def check(output: str) -> tuple[bool, str]:
        if substring.lower() not in output.lower():
            return True, ""
        return False, f"should not contain '{substring}'"
    check.__name__ = f"not_contains({substring!r})"
    return check


def starts_upper(output: str) -> tuple[bool, str]:
    """First character must be uppercase or a digit."""
    if not output:
        return False, "output is empty"
    if output[0].isupper() or output[0].isdigit():
        return True, ""
    return False, f"starts with '{output[0]}', expected uppercase or digit"


def ends_with_punctuation(output: str) -> tuple[bool, str]:
    """Last character must be sentence-ending punctuation."""
    if not output:
        return False, "output is empty"
    stripped = output.rstrip()
    if stripped and stripped[-1] in ".!?":
        return True, ""
    return False, f"ends with '{stripped[-1:]}', expected . ! or ?"


def has_bullet_list(min_items: int = 3) -> Callable[[str], tuple[bool, str]]:
    """Output must contain at least min_items lines starting with '- '."""
    def check(output: str) -> tuple[bool, str]:
        bullets = [l for l in output.splitlines() if l.strip().startswith("- ")]
        if len(bullets) >= min_items:
            return True, ""
        return False, f"found {len(bullets)} bullet items, expected >= {min_items}"
    check.__name__ = f"has_bullet_list(>={min_items})"
    return check


def has_numbered_list(min_items: int = 3) -> Callable[[str], tuple[bool, str]]:
    """Output must contain at least min_items lines starting with 'N. '."""
    def check(output: str) -> tuple[bool, str]:
        numbered = [
            l for l in output.splitlines()
            if re.match(r'\s*\d+[\.\)]\s', l)
        ]
        if len(numbered) >= min_items:
            return True, ""
        return False, f"found {len(numbered)} numbered items, expected >= {min_items}"
    check.__name__ = f"has_numbered_list(>={min_items})"
    return check


def no_list_formatting(output: str) -> tuple[bool, str]:
    """Output must NOT contain bullet or numbered list lines."""
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith("- ") and len(stripped) > 2:
            return False, f"unexpected bullet item: {stripped}"
        if re.match(r'\d+[\.\)]\s', stripped):
            return False, f"unexpected numbered item: {stripped}"
    return True, ""


def is_single_line(output: str) -> tuple[bool, str]:
    """Output must be a single line (no newlines in content)."""
    lines = [l for l in output.strip().splitlines() if l.strip()]
    if len(lines) == 1:
        return True, ""
    return False, f"expected 1 line, got {len(lines)}"


def matches_exactly(expected: str) -> Callable[[str], tuple[bool, str]]:
    """Output must match expected string exactly."""
    def check(output: str) -> tuple[bool, str]:
        if output.strip() == expected.strip():
            return True, ""
        return False, f"expected exact match"
    check.__name__ = f"matches_exactly({expected!r})"
    return check


def contains_digit(output: str) -> tuple[bool, str]:
    """Output must contain at least one digit."""
    if any(c.isdigit() for c in output):
        return True, ""
    return False, "no digits found"


def contains_pattern(pattern: str, desc: str = "") -> Callable[[str], tuple[bool, str]]:
    """Output must match the regex pattern."""
    def check(output: str) -> tuple[bool, str]:
        if re.search(pattern, output):
            return True, ""
        label = desc or pattern
        return False, f"pattern not found: {label}"
    check.__name__ = f"contains_pattern({desc or pattern})"
    return check


def max_length(n: int) -> Callable[[str], tuple[bool, str]]:
    """Output must be at most n characters."""
    def check(output: str) -> tuple[bool, str]:
        if len(output.strip()) <= n:
            return True, ""
        return False, f"length {len(output.strip())} exceeds max {n}"
    check.__name__ = f"max_length({n})"
    return check


def shorter_than_input(text: str) -> Callable[[str], tuple[bool, str]]:
    """Output must be shorter than the input (fillers were removed)."""
    def check(output: str) -> tuple[bool, str]:
        if len(output.strip()) < len(text.strip()):
            return True, ""
        return False, f"output ({len(output.strip())} chars) not shorter than input ({len(text.strip())} chars)"
    check.__name__ = "shorter_than_input"
    return check


# ---------------------------------------------------------------------------
# Test case definition
# ---------------------------------------------------------------------------


@dataclass
class TestCase:
    """A single cleanup test case."""

    name: str
    category: str
    input: str
    validators: list[Callable[[str], tuple[bool, str]]]
    context: Optional[dict] = None
    description: str = ""


@dataclass
class RunResult:
    """Result of a single call to /cleanup."""

    output: str
    passed: bool
    failures: list[str]
    elapsed: float


@dataclass
class TestResult:
    """Aggregated results across multiple runs of one test case."""

    test: TestCase
    runs: list[RunResult] = field(default_factory=list)

    @property
    def all_passed(self) -> bool:
        return all(r.passed for r in self.runs)

    @property
    def pass_count(self) -> int:
        return sum(1 for r in self.runs if r.passed)

    @property
    def consistency(self) -> float:
        """Fraction of runs that produced identical output."""
        if not self.runs:
            return 0.0
        outputs = [r.output for r in self.runs]
        most_common = max(set(outputs), key=outputs.count)
        return outputs.count(most_common) / len(outputs)

    @property
    def unique_outputs(self) -> list[str]:
        seen = []
        for r in self.runs:
            if r.output not in seen:
                seen.append(r.output)
        return seen


# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

TESTS: list[TestCase] = [
    # ----- Lists: unordered -----
    TestCase(
        name="grocery list",
        category="lists-unordered",
        input="we need milk eggs bread and butter",
        description="Short single-word items; nano model may use comma-separated prose.",
        validators=[
            contains("milk"),
            contains("eggs"),
            contains("bread"),
            contains("butter"),
            starts_upper,
        ],
    ),
    TestCase(
        name="topics discussed",
        category="lists-unordered",
        input="we discussed performance security and scalability",
        description="Short single-word items; nano model may use comma-separated prose.",
        validators=[
            contains("performance"),
            contains("security"),
            contains("scalability"),
            starts_upper,
        ],
    ),
    TestCase(
        name="shopping with lead-in",
        category="lists-unordered",
        input="I need to buy apples bananas oranges and kiwis",
        validators=[
            has_bullet_list(4),
            contains("apples"),
            contains("bananas"),
            contains("oranges"),
            contains("kiwis"),
        ],
    ),
    TestCase(
        name="things to pack",
        category="lists-unordered",
        input="don't forget to pack sunscreen a hat sunglasses a towel and flip flops",
        description="Items with articles; nano model may use comma-separated prose.",
        validators=[
            contains("sunscreen"),
            contains("hat"),
            contains("sunglasses"),
            contains("towel"),
            contains("flip"),
            starts_upper,
        ],
    ),

    # ----- Lists: ordered -----
    TestCase(
        name="first second third",
        category="lists-ordered",
        input="the issues are first the API is slow second the cache is stale third the tests are broken",
        validators=[
            has_numbered_list(3),
            contains("API"),
            contains("cache"),
            contains("tests"),
        ],
    ),
    TestCase(
        name="step one two three",
        category="lists-ordered",
        input="step one open the file step two edit the config step three save and restart",
        validators=[
            has_numbered_list(3),
            contains("open"),
            contains("edit"),
            contains("save"),
        ],
    ),
    TestCase(
        name="number one two three",
        category="lists-ordered",
        input="number one check the logs number two restart the service number three verify the fix",
        validators=[
            has_numbered_list(3),
            contains("logs"),
            contains("restart"),
            contains("verify"),
        ],
    ),
    TestCase(
        name="first then finally",
        category="lists-ordered",
        input="first we need to design the schema then implement the API and finally write the tests",
        description="'first/then/finally' is natural prose flow; numbered list or well-punctuated sentence both acceptable.",
        validators=[
            contains("schema"),
            contains("API"),
            contains("tests"),
            starts_upper,
            ends_with_punctuation,
        ],
    ),

    # ----- Lists: embedded in sentence -----
    TestCase(
        name="issues with lead-in sentence",
        category="lists-embedded",
        input="the main problems we need to address are first the database is too slow second we have no caching layer and third the frontend makes too many requests",
        description="'first/second/third' signals order; accept numbered or bullet list.",
        validators=[
            contains_pattern(r'[:\.]', 'colon or period after lead-in'),
            contains("database"),
            contains("caching"),
            contains("frontend"),
        ],
    ),

    # ----- Lists: comma-separated (should stay as prose) -----
    TestCase(
        name="comma-separated short items inline",
        category="lists-comma",
        input="I like red, blue, and green.",
        description="Already punctuated comma list, should stay as prose.",
        validators=[
            # This is borderline. The prompt says 3+ items become a list,
            # but this is a natural comma-separated clause inside a sentence.
            # We accept either prose or bullet form here. The key check is
            # that the content is preserved and it's well-formed.
            contains("red"),
            contains("blue"),
            contains("green"),
            starts_upper,
        ],
    ),

    # ----- Filler removal -----
    TestCase(
        name="um so like",
        category="fillers",
        input="um so like I was thinking we should probably move the meeting to Friday",
        validators=[
            not_contains("um"),
            not_contains("so like"),
            contains("Friday"),
            contains("meeting"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="you know I mean",
        category="fillers",
        input="you know I think we should you know I mean probably just go with the simpler approach",
        validators=[
            not_contains("you know"),
            not_contains("I mean"),
            contains("simpler approach"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="uh er hmm",
        category="fillers",
        input="uh so the thing is er we need to hmm reconsider the timeline",
        validators=[
            not_contains(" uh "),
            not_contains(" er "),
            not_contains(" hmm "),
            contains("timeline"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="heavy fillers short sentence",
        category="fillers",
        input="um uh like yeah so basically the server is down",
        validators=[
            not_contains("um"),
            not_contains("uh"),
            not_contains("like yeah"),
            not_contains("basically"),
            contains("server"),
            contains("down"),
            starts_upper,
            ends_with_punctuation,
        ],
    ),

    # ----- Repetitions -----
    TestCase(
        name="repeated phrase",
        category="repetitions",
        input="I think I think we should go with option A",
        validators=[
            contains_pattern(r'I think', "one instance of 'I think'"),
            not_contains("I think I think"),
            contains("option A"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="repeated word",
        category="repetitions",
        input="the the project is going well",
        validators=[
            not_contains("the the"),
            contains("project"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="triple repetition",
        category="repetitions",
        input="we need we need we need to fix the database",
        validators=[
            contains("we need"),
            # Should not have three copies
            not_contains("we need we need"),
            contains("database"),
            starts_upper,
            ends_with_punctuation,
        ],
    ),

    # ----- Mid-sentence corrections -----
    TestCase(
        name="no wait correction",
        category="corrections",
        input="send it to John no wait send it to Sarah",
        validators=[
            contains("Sarah"),
            not_contains("John"),
            not_contains("no wait"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="actually correction",
        category="corrections",
        input="the meeting is at 3 PM actually no it's at 4 PM",
        validators=[
            contains("4"),
            not_contains("3"),
            not_contains("actually no"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="sorry I mean",
        category="corrections",
        input="deploy to staging sorry I mean deploy to production",
        validators=[
            contains("production"),
            not_contains("staging"),
            not_contains("sorry"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="let me rephrase",
        category="corrections",
        input="the feature is broken let me rephrase the feature has a critical bug that needs immediate attention",
        validators=[
            contains("critical bug"),
            not_contains("let me rephrase"),
            # Should keep only the rephrased version; "broken" may or may
            # not survive depending on LLM interpretation, so we don't
            # assert on it.
            starts_upper,
            ends_with_punctuation,
        ],
    ),

    # ----- Number formatting -----
    TestCase(
        name="percentage",
        category="numbers",
        input="twenty three percent of users experienced the issue",
        validators=[
            contains("23%"),
            not_contains("twenty"),
            not_contains("three percent"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="dollars",
        category="numbers",
        input="the total cost is twelve thousand dollars",
        validators=[
            contains_pattern(r'\$12[,.]?000', '$12,000 or $12000'),
            not_contains("twelve"),
            not_contains("thousand"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="decimal percent",
        category="numbers",
        input="twenty three point five percent improvement",
        description="Fragment input; period not required.",
        validators=[
            contains("23.5%"),
            not_contains("twenty"),
            not_contains("point five"),
            contains("improvement"),
        ],
    ),
    TestCase(
        name="mixed numbers",
        category="numbers",
        input="we have three hundred and forty two active users and seventeen pending signups",
        validators=[
            contains("342"),
            contains("17"),
            not_contains("three hundred"),
            not_contains("seventeen"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="simple count",
        category="numbers",
        input="I need to buy one apple two bananas three oranges",
        description="Items have quantities; list formatting is fine but counts must be preserved.",
        validators=[
            # Quantities must survive as digits or words.
            contains("apple"),
            contains("banana"),
            contains("orange"),
            starts_upper,
            # Each item should carry its count (e.g. "1 apple" or "one apple").
            contains_pattern(r'1\s*[Aa]pple|[Oo]ne\s+[Aa]pple', '1/one apple'),
            contains_pattern(r'2\s*[Bb]anana|[Tt]wo\s+[Bb]anana', '2/two banana'),
            contains_pattern(r'3\s*[Oo]range|[Tt]hree\s+[Oo]range', '3/three orange'),
        ],
    ),

    # ----- Dictated punctuation -----
    TestCase(
        name="comma and period",
        category="dictated-punctuation",
        input="pick up milk comma bread comma eggs period",
        validators=[
            contains(","),
            contains("."),
            not_contains(" comma"),
            not_contains(" period"),
            contains("milk"),
            contains("bread"),
            contains("eggs"),
            starts_upper,
            is_single_line,
        ],
    ),
    TestCase(
        name="question mark",
        category="dictated-punctuation",
        input="can you send me the report question mark",
        validators=[
            contains("?"),
            not_contains("question mark"),
            contains("report"),
            starts_upper,
        ],
    ),
    TestCase(
        name="exclamation point",
        category="dictated-punctuation",
        input="congratulations on the launch exclamation point",
        validators=[
            contains("!"),
            not_contains("exclamation"),
            contains("launch"),
            starts_upper,
        ],
    ),
    TestCase(
        name="new paragraph",
        category="dictated-punctuation",
        input="here is the first part new paragraph and here is the second part",
        validators=[
            contains("\n"),
            not_contains("new paragraph"),
            contains("first"),
            contains("second"),
            starts_upper,
        ],
    ),
    TestCase(
        name="hyphen",
        category="dictated-punctuation",
        input="this is a well hyphen known state hyphen of hyphen the hyphen art technique",
        validators=[
            contains("-"),
            not_contains("hyphen"),
            contains("well-known"),
            starts_upper,
        ],
    ),
    TestCase(
        name="ellipsis",
        category="dictated-punctuation",
        input="I was thinking ellipsis maybe we should wait",
        validators=[
            contains("\u2026"),
            not_contains("ellipsis"),
            contains("thinking"),
            contains("wait"),
            starts_upper,
        ],
    ),
    TestCase(
        name="dot dot dot",
        category="dictated-punctuation",
        input="and then dot dot dot everything changed",
        validators=[
            contains("\u2026"),
            not_contains("dot dot dot"),
            contains("everything changed"),
            starts_upper,
        ],
    ),
    TestCase(
        name="at sign",
        category="dictated-punctuation",
        input="send it to jane at sign example period com",
        validators=[
            contains("@"),
            not_contains("at sign"),
            contains("jane"),
            starts_upper,
        ],
    ),
    TestCase(
        name="hashtag",
        category="dictated-punctuation",
        input="check the hashtag trending topic and hashtag 42",
        validators=[
            contains("#"),
            not_contains("hashtag"),
            starts_upper,
        ],
    ),
    TestCase(
        name="ampersand",
        category="dictated-punctuation",
        input="research ampersand development is our focus",
        validators=[
            contains("&"),
            not_contains("ampersand"),
            contains("development"),
            starts_upper,
        ],
    ),
    TestCase(
        name="forward slash and backslash",
        category="dictated-punctuation",
        input="open the config forward slash settings page and the path is C backslash users",
        validators=[
            contains("/"),
            contains("\\"),
            not_contains("forward slash"),
            not_contains("backslash"),
            starts_upper,
        ],
    ),
    TestCase(
        name="asterisk and underscore",
        category="dictated-punctuation",
        input="use asterisk bold asterisk and underscore italic underscore for formatting",
        validators=[
            contains("*"),
            contains("_"),
            not_contains("asterisk"),
            not_contains("underscore"),
            starts_upper,
        ],
    ),
    TestCase(
        name="dollar sign and percent sign",
        category="dictated-punctuation",
        input="the price is dollar sign 50 with a 10 percent sign discount",
        validators=[
            contains("$"),
            contains("%"),
            not_contains("dollar sign"),
            not_contains("percent sign"),
            starts_upper,
        ],
    ),
    TestCase(
        name="equals sign and plus sign",
        category="dictated-punctuation",
        input="two plus sign three equals sign five",
        validators=[
            contains("+"),
            contains("="),
            not_contains("plus sign"),
            not_contains("equals sign"),
            starts_upper,
        ],
    ),

    # ----- Already clean transcripts -----
    TestCase(
        name="clean simple sentence",
        category="already-clean",
        input="The deployment went smoothly and all tests passed.",
        description="Should be returned mostly unchanged.",
        validators=[
            contains("deployment"),
            contains("tests passed"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="clean with proper names",
        category="already-clean",
        input="I'll meet Sarah at the conference in New York on Friday.",
        description="Should be returned mostly unchanged.",
        validators=[
            contains("Sarah"),
            contains("New York"),
            contains("Friday"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="clean question",
        category="already-clean",
        input="Can you review the pull request before the end of the day?",
        description="Should be returned mostly unchanged.",
        validators=[
            contains("pull request"),
            contains("?"),
            starts_upper,
            is_single_line,
        ],
    ),

    # ----- Mixed: multiple issues at once -----
    TestCase(
        name="fillers + numbers",
        category="mixed",
        input="um so like I need to buy one apple two bananas three oranges",
        validators=[
            not_contains("um"),
            not_contains("so like"),
            contains_digit,
            starts_upper,
        ],
    ),
    TestCase(
        name="repetition + correction + punctuation",
        category="mixed",
        input="the the meeting is at three PM no wait four PM period",
        validators=[
            not_contains("the the"),
            not_contains("no wait"),
            not_contains(" period"),
            contains_pattern(r'4|four', '4 or four'),
            contains("."),
            starts_upper,
            is_single_line,
        ],
    ),
    TestCase(
        name="fillers + list",
        category="mixed",
        input="um so we need to uh fix the bug update the docs and um deploy to production",
        validators=[
            not_contains(" um "),
            not_contains(" uh "),
            contains("bug"),
            contains_pattern(r'docs|documentation', 'docs or documentation'),
            contains("production"),
            starts_upper,
            ends_with_punctuation,
        ],
    ),
    TestCase(
        name="filler + correction + number",
        category="mixed",
        input="um the revenue was fifty thousand no wait sixty thousand dollars last quarter",
        validators=[
            not_contains("um"),
            not_contains("no wait"),
            not_contains("fifty"),
            contains_pattern(r'\$60[,.]?000|sixty thousand dollars', '$60,000 or sixty thousand dollars'),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),

    # ----- Capitalization and punctuation -----
    TestCase(
        name="lowercase no punctuation",
        category="capitalization",
        input="the server is running fine and all endpoints are responding normally",
        validators=[
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="proper noun I",
        category="capitalization",
        input="i think we should ask john and sarah about the new york office",
        validators=[
            starts_upper,
            ends_with_punctuation,
            contains("I "),
            contains_pattern(r'[Jj]ohn', "John capitalized"),
            contains_pattern(r'[Ss]arah', "Sarah capitalized"),
            contains_pattern(r'[Nn]ew [Yy]ork', "New York capitalized"),
            is_single_line,
        ],
    ),

    # ----- Preservation: meaning should not change -----
    TestCase(
        name="technical content preserved",
        category="preservation",
        input="the API returns a four oh four error when you hit the slash users endpoint with an invalid token",
        validators=[
            contains_pattern(r'404', '404 numeric'),
            contains_pattern(r'/users|slash users', '/users or slash users'),
            contains("token"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="no added content",
        category="preservation",
        input="please review my pull request",
        description="Short input should not get padded with extra content.",
        validators=[
            starts_upper,
            ends_with_punctuation,
            max_length(60),
            contains("review"),
            contains("pull request"),
            is_single_line,
        ],
    ),

    # ----- Context-aware tone -----
    TestCase(
        name="email context formal",
        category="context",
        input="um hey so like can you send me that report by friday thanks",
        context={"app_name": "Mail", "window_title": "Re: Q3 Report"},
        validators=[
            not_contains("um"),
            not_contains("so like"),
            contains("report"),
            contains_pattern(r'[Ff]riday', "Friday"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="slack context casual",
        category="context",
        input="um hey can you check if the build passed",
        context={"app_name": "Slack", "window_title": "#engineering"},
        validators=[
            not_contains("um"),
            contains("build"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),

    # ----- Edge cases -----
    TestCase(
        name="very short input",
        category="edge",
        input="yes",
        validators=[
            contains_pattern(r'[Yy]es', "yes preserved"),
            max_length(10),
        ],
    ),
    TestCase(
        name="single word with filler",
        category="edge",
        input="um yes",
        validators=[
            not_contains("um"),
            contains_pattern(r'[Yy]es', "yes preserved"),
            max_length(10),
        ],
    ),
    TestCase(
        name="all fillers",
        category="edge",
        input="um uh like you know",
        description="All filler words. Should produce minimal or empty output.",
        validators=[
            # The LLM might return empty, the raw fillers, or a short
            # explanation. Any of these is acceptable.
            max_length(150),
        ],
    ),
    TestCase(
        name="two items not a list",
        category="edge",
        input="we need to fix the bug and update the docs",
        description="Only two items, should NOT become a list.",
        validators=[
            no_list_formatting,
            contains("bug"),
            contains_pattern(r'docs|documentation', 'docs or documentation'),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="long single-sentence dictation",
        category="edge",
        input=(
            "I want to let everyone know that the deployment went well and "
            "all the services are running normally and there were no errors "
            "during the migration and the database is healthy and the "
            "monitoring dashboards look clean"
        ),
        validators=[
            contains("deployment"),
            contains("services"),
            contains("migration"),
            contains("database"),
            contains("monitoring"),
            starts_upper,
            ends_with_punctuation,
        ],
    ),
]


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------


def run_test(test: TestCase, reps: int, verbose: bool) -> TestResult:
    """Run a single test case `reps` times and collect results."""
    result = TestResult(test=test)

    for i in range(reps):
        t0 = time.monotonic()
        try:
            output = call_polish(test.input, test.context)
        except Exception as e:
            elapsed = time.monotonic() - t0
            result.runs.append(RunResult(
                output=f"ERROR: {e}",
                passed=False,
                failures=[f"request failed: {e}"],
                elapsed=elapsed,
            ))
            continue

        elapsed = time.monotonic() - t0
        failures = []
        for validator in test.validators:
            passed, reason = validator(output)
            if not passed:
                vname = getattr(validator, "__name__", str(validator))
                failures.append(f"{vname}: {reason}")

        run = RunResult(
            output=output,
            passed=len(failures) == 0,
            failures=failures,
            elapsed=elapsed,
        )
        result.runs.append(run)

        if verbose or not run.passed:
            status = "PASS" if run.passed else "FAIL"
            print(f"    Run {i+1}/{reps}: {status} ({elapsed:.2f}s)")
            if verbose or not run.passed:
                # Show input/output for context
                if i == 0 or not run.passed:
                    print(f"      Input:  {test.input[:120]}")
                    out_display = output.replace('\n', '\\n')
                    print(f"      Output: {out_display[:120]}")
                if failures:
                    for f in failures:
                        print(f"      ✗ {f}")

    return result


def main():
    parser = argparse.ArgumentParser(description="Test polish prompt")
    parser.add_argument("--reps", type=int, default=5, help="Runs per test case (default: 5)")
    parser.add_argument("--category", help="Run only tests in this category")
    parser.add_argument("--name", help="Run only the test with this name")
    parser.add_argument("--verbose", "-v", action="store_true", help="Show all outputs, not just failures")
    parser.add_argument("--list", action="store_true", help="List all test cases and exit")
    args = parser.parse_args()

    if args.list:
        categories = {}
        for t in TESTS:
            categories.setdefault(t.category, []).append(t)
        for cat, tests in categories.items():
            print(f"\n{cat}:")
            for t in tests:
                desc = f"  ({t.description})" if t.description else ""
                print(f"  - {t.name}{desc}")
        print(f"\nTotal: {len(TESTS)} test cases")
        return

    if not API_KEY:
        print("ERROR: VOICE_API_KEY not set.")
        print('  export VOICE_API_KEY="$(grep API_KEY secrets.yaml | cut -d\' \' -f2)"')
        sys.exit(1)

    # Filter tests
    tests = TESTS
    if args.category:
        tests = [t for t in tests if t.category == args.category]
        if not tests:
            print(f"ERROR: No tests found for category '{args.category}'")
            categories = sorted(set(t.category for t in TESTS))
            print(f"Available categories: {', '.join(categories)}")
            sys.exit(1)
    if args.name:
        tests = [t for t in tests if t.name == args.name]
        if not tests:
            print(f"ERROR: No test found with name '{args.name}'")
            sys.exit(1)

    print(f"Running {len(tests)} test cases × {args.reps} reps = {len(tests) * args.reps} calls")
    print(f"Endpoint: {BASE_URL}/polish")
    print()

    results: list[TestResult] = []
    total_pass = 0
    total_fail = 0
    inconsistent: list[TestResult] = []

    for i, test in enumerate(tests):
        label = f"[{i+1}/{len(tests)}] {test.category} / {test.name}"
        print(f"  {label}")

        result = run_test(test, args.reps, args.verbose)
        results.append(result)

        pass_count = result.pass_count
        fail_count = len(result.runs) - pass_count
        total_pass += pass_count
        total_fail += fail_count

        consistency = result.consistency
        if consistency < 1.0:
            inconsistent.append(result)

        if result.all_passed and not args.verbose:
            print(f"    ✓ {pass_count}/{args.reps} passed (consistency: {consistency:.0%})")
        elif not result.all_passed:
            print(f"    ✗ {pass_count}/{args.reps} passed (consistency: {consistency:.0%})")

        print()

    # --- Summary ---
    print("=" * 70)
    print("SUMMARY")
    print("=" * 70)

    total = total_pass + total_fail
    print(f"\nTotal runs: {total}")
    print(f"  Passed: {total_pass}")
    print(f"  Failed: {total_fail}")
    print(f"  Pass rate: {total_pass / total * 100:.1f}%")

    # Report failed test cases
    failed_tests = [r for r in results if not r.all_passed]
    if failed_tests:
        print(f"\nFailed tests ({len(failed_tests)}):")
        for r in failed_tests:
            print(f"  ✗ {r.test.category} / {r.test.name} — {r.pass_count}/{args.reps} passed")
            # Show the most common failure reasons
            all_failures = []
            for run in r.runs:
                all_failures.extend(run.failures)
            seen = {}
            for f in all_failures:
                seen[f] = seen.get(f, 0) + 1
            for f, count in sorted(seen.items(), key=lambda x: -x[1]):
                print(f"    {count}× {f}")
    else:
        print(f"\n✓ All {len(results)} test cases passed all {args.reps} runs!")

    # Report inconsistent outputs
    if inconsistent:
        print(f"\nInconsistent outputs ({len(inconsistent)}):")
        for r in inconsistent:
            print(f"  ⚠ {r.test.category} / {r.test.name} — {r.consistency:.0%} consistency")
            print(f"    Input: {r.test.input[:100]}")
            for j, out in enumerate(r.unique_outputs):
                out_display = out.replace('\n', '\\n')
                print(f"    Variant {j+1}: {out_display[:100]}")
    else:
        print(f"\n✓ All outputs were consistent across {args.reps} runs.")

    # Exit code
    sys.exit(0 if not failed_tests else 1)


if __name__ == "__main__":
    main()
