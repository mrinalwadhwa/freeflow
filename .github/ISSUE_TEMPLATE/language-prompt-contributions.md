---
name: "Language Prompt: Add detailed prompt for [language]"
about: "Contribute a detailed polishing prompt for a specific language"
title: "Language Prompt: [Language Name]"
labels: ["language-prompt", "good first issue", "help wanted"]
---

## What this is about

FreeFlow is a voice-to-text app that supports 57 languages. After the speech-to-text engine transcribes audio, a "polishing" step cleans up the raw transcript: removing filler words, fixing repetitions, adding punctuation, formatting numbers, and so on.

**The problem:** English has a detailed, 136-line polishing prompt with 10 carefully tuned rules. All 56 other languages share a single minimal 18-line prompt with 9 generic rules. The minimal prompt works, but it misses language-specific nuances that only a native speaker would know.

**Your contribution:** Write a detailed polishing prompt for **[Language Name]** (`[language_code]`) that handles the unique characteristics of this language.

---

## The English prompt as reference

The English prompt (`FreeFlowService/images/main/polish_prompt.txt`) has 10 rules:

| # | Rule | What it does |
|---|------|-------------|
| 1 | **Filler words** | Removes "um", "uh", "like", "you know", "I mean" |
| 2 | **Repetitions** | "I think I think we should" → "I think we should" |
| 3 | **Mid-sentence corrections** | Detects "no wait", "actually", "let me rephrase" and keeps only the corrected version |
| 4 | **Punctuation & capitalization** | Adds periods, commas, capitalizes sentence starts and proper nouns |
| 5 | **Lists** | 3+ enumerated items become vertical lists; numbered (1. 2. 3.) if ordered, bulleted (- ) if unordered |
| 6 | **Numbers & formatting** | "twenty three point five percent" → "23.5%", "twelve dollars" → "$12" |
| 7 | **Dictated punctuation** | Spoken commands like "period", "comma", "question mark" become the actual symbols |
| 8 | **`<keep>` tag preservation** | Symbols wrapped in `<keep>...</keep>` tags are preserved exactly as-is |
| 9 | **Wording preservation** | Never substitute verbs, swap phrases, or rewrite sentences; only clean up |
| 10 | **No fabricated text** | Never insert words the speaker did not say |

The current minimal prompt (`FreeFlowService/images/main/polish_prompt_minimal.txt`) covers the basics but lacks language-specific examples, dictated punctuation mappings, and nuanced rules.

---

## Checklist: what your language-specific prompt should address

Please research and address each of these for **[Language Name]**. Not all will apply to every language; skip any that are not relevant and note why.

- [ ] **Filler words and hesitation sounds**
  List the common fillers in this language. Examples:
  - French: "euh", "ben", "donc", "en fait", "tu vois", "quoi"
  - Spanish: "este", "eh", "bueno", "o sea", "pues"
  - German: "ähm", "äh", "also", "halt", "sozusagen"
  - Japanese: "えーと", "あのー", "まあ", "ちょっと", "なんか"
  - Chinese: "那个", "嗯", "就是", "然后"

- [ ] **Mid-sentence correction signals**
  What phrases do speakers use to self-correct? In English it's "no wait", "actually", "I mean", "sorry", "let me rephrase". What are the equivalents in this language?

- [ ] **Dictated punctuation commands**
  What would a native speaker say to dictate punctuation? Map spoken words to symbols:
  - "period" / "full stop" equivalent → .
  - "comma" equivalent → ,
  - "question mark" equivalent → ?
  - "exclamation point" equivalent → !
  - "colon" equivalent → :
  - "semicolon" equivalent → ;
  - "open/close parenthesis" equivalents → ( )
  - "open/close quote" equivalents → " "
  - Any other language-specific punctuation (e.g., « » for French, 「」for Japanese)

- [ ] **Number and currency formatting**
  - Decimal separator: comma or period? (e.g., "23,5%" in French vs "23.5%" in English)
  - Thousands separator: period, comma, space, or none?
  - Currency symbol placement: before or after the number? With space?
  - Examples of spelled-out numbers → digit conversion in this language

- [ ] **List formatting patterns**
  - How do speakers signal ordered lists? (equivalents of "first/second/third", "step one/step two", "number one/number two")
  - How do speakers signal unordered enumerations?

- [ ] **Script-specific rules** (if applicable)
  - Does this language use multiple scripts? (e.g., Hindi should use Devanagari, not Urdu/Nastaliq)
  - Are there mixed-script issues with loanwords or transliteration?
  - Character-specific punctuation (e.g., Japanese uses 。instead of . and 、instead of ,)

- [ ] **Honorifics and formality** (if applicable)
  - Japanese: keigo (敬語) levels should be preserved, not simplified
  - Korean: honorific speech levels (존댓말/반말) should be preserved
  - German: Sie/du distinction should be preserved
  - Other languages with T-V distinction or formality systems

- [ ] **`<keep>` tag preservation**
  This rule is universal. Include it in your prompt. Symbols wrapped in `<keep>...</keep>` tags must be preserved exactly.

- [ ] **Wording preservation**
  This rule is universal. Include it. Never rewrite the speaker's words.

- [ ] **No fabricated text**
  This rule is universal. Include it. Never insert content the speaker did not say.

- [ ] **Concrete examples**
  For every rule, provide before/after examples in the target language, just like the English prompt does. Examples are critical for LLM prompt quality.

---

## How the prompt system works

1. **File:** Prompts live in `FreeFlowService/images/main/`. The English prompt is `polish_prompt.txt`, the minimal fallback is `polish_prompt_minimal.txt`.

2. **Loading:** `polish.py` loads prompts at startup using `_load_prompt_file()`:
   ```python
   SYSTEM_PROMPT = _load_prompt_file("polish_prompt.txt")            # English
   SYSTEM_PROMPT_MINIMAL = _load_prompt_file("polish_prompt_minimal.txt")  # all others
   ```

3. **Routing:** `polish_text()` checks the language code. English goes through a three-stage pipeline (regex + skip heuristic + LLM). Non-English goes straight to LLM with the minimal prompt. Your new prompt would replace the minimal prompt for this specific language.

4. **Model:** The prompt is sent as the system message to `gpt-4.1-nano`. Keep the prompt concise but thorough; the model is small and benefits from explicit examples.

---

## How to contribute

### 1. Create the prompt file

Create: `FreeFlowService/images/main/polish_prompt_[language_code].txt`

For example, for French: `polish_prompt_fr.txt`

Use the English prompt as a structural template. Your prompt should:
- Start with "You are a speech-to-text cleanup assistant. The user dictated text in [Language Name] and a speech-to-text engine transcribed it."
- Include numbered rules with concrete before/after examples in the target language
- End with the same closing instructions (return only cleaned text, no preamble, no translation, etc.)

### 2. Wire it up in `polish.py`

Add the prompt loading at the top alongside the existing prompts:

```python
SYSTEM_PROMPT_FR = _load_prompt_file("polish_prompt_fr.txt")
```

Then update `_polish_minimal()` (or `polish_text()`) to check for the language code and use the specific prompt:

```python
# In polish_text() or a new routing function:
if language and language.lower().startswith("fr"):
    system_prompt = SYSTEM_PROMPT_FR
else:
    system_prompt = SYSTEM_PROMPT_MINIMAL
```

### 3. Add test cases

Test cases are just as valuable as the prompt itself. They validate that your prompt works, catch regressions if the model or prompt changes later, and document exactly what your prompt handles. The English prompt has 48 test cases across 15 categories. Your language contribution should include at least 8-12 test cases.

#### How the test harness works

The test suite lives at `FreeFlowService/tests/test_polish.py`. Each test case is a `TestCase` object with:
- `name` — short identifier (e.g., `"french filler euh"`)
- `category` — group name with your language code suffix (e.g., `"fillers-fr"`)
- `input` — the messy transcript to clean up
- `language` — ISO-639-1 code (e.g., `"fr"`) so the server routes to your prompt
- `validators` — structural checks on the output
- `context` — optional app context dict (app name, window title); separate from `language`
- `description` — optional note about what this tests

The harness sends each input to the `/polish` endpoint multiple times (default 5) to surface non-deterministic LLM behavior, then checks every run against the validators. Each `TestCase` has a `language` field (ISO-639-1 code) that the harness passes as a top-level field to the `/polish` endpoint. This is separate from the `context` field, which carries app metadata (app name, window title). Existing English tests leave `language=None` and behave as before.

#### Running your tests

```bash
cd FreeFlowService

# If you set up FreeFlow via the app, read credentials from Keychain:
eval "$(./scripts/dev-token.sh --from-keychain)"

# Or if you have secrets.yaml (developer workflow):
export FREEFLOW_SERVICE_URL="https://YOUR-CLUSTER-ID-freeflow.cluster.autonomy.computer"
export FREEFLOW_SESSION_TOKEN="$(./scripts/dev-token.sh)"

# Run only your language's tests
python3 tests/test_polish.py --category fillers-fr

# Run a single test by name
python3 tests/test_polish.py --name "french filler euh"

# More repetitions for consistency checking
python3 tests/test_polish.py --category fillers-fr --reps 10

# See all outputs, not just failures
python3 tests/test_polish.py --category fillers-fr --verbose

# List all available test cases
python3 tests/test_polish.py --list
```

#### Available validators

Use these in your test cases. Each returns pass/fail with a reason:

| Validator | What it checks |
|-----------|---------------|
| `contains("text")` | Output contains the substring (case-insensitive) |
| `not_contains("text")` | Output does NOT contain the substring |
| `starts_upper` | Output starts with an uppercase letter |
| `ends_with_punctuation` | Output ends with `.` `!` `?` `)` `"` |
| `has_bullet_list(n)` | Output has at least `n` lines starting with `- ` |
| `has_numbered_list(n)` | Output has at least `n` lines starting with `1.` `2.` etc. |
| `no_list_formatting` | Output has no bullet or numbered list markers |
| `is_single_line` | Output is a single line (no newlines) |
| `matches_exactly("text")` | Output matches exactly (case-insensitive, stripped) |
| `contains_digit` | Output contains at least one digit |
| `contains_pattern(r"regex", "desc")` | Output matches the regex |
| `max_length(n)` | Output is at most `n` characters |
| `shorter_than_input` | Output is shorter than the input |

#### Complete example: French test cases

Copy this pattern and adapt for your language. Add these to the `TESTS` list in `test_polish.py`:

```python
    # ----- French: filler removal -----
    TestCase(
        name="french filler euh",
        category="fillers-fr",
        input="euh donc je pense qu'on devrait euh reporter la réunion",
        language="fr",
        description="Common French fillers: euh, donc.",
        validators=[
            not_contains("euh"),
            not_contains("donc"),
            contains("reporter"),
            contains("réunion"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),
    TestCase(
        name="french filler en fait tu vois",
        category="fillers-fr",
        input="en fait tu vois le problème c'est que ben on n'a pas assez de temps quoi",
        language="fr",
        description="Conversational French fillers: en fait, tu vois, ben, quoi.",
        validators=[
            not_contains("en fait"),
            not_contains("tu vois"),
            not_contains(" ben "),
            not_contains(" quoi"),
            contains("problème"),
            contains("temps"),
            starts_upper,
            ends_with_punctuation,
        ],
    ),

    # ----- French: mid-sentence corrections -----
    TestCase(
        name="french correction non attendez",
        category="corrections-fr",
        input="envoyez le rapport à Jean non attendez envoyez-le à Marie",
        language="fr",
        description="French self-correction signal: non attendez.",
        validators=[
            contains("Marie"),
            not_contains("Jean"),
            not_contains("non attendez"),
            starts_upper,
            ends_with_punctuation,
            is_single_line,
        ],
    ),

    # ----- French: number formatting -----
    TestCase(
        name="french percentage decimal comma",
        category="numbers-fr",
        input="le taux est de vingt-trois virgule cinq pour cent",
        language="fr",
        description="French uses decimal comma: 23,5 % (with space before %).",
        validators=[
            contains_pattern(r'23,5\s?%', '23,5 % or 23,5%'),
            not_contains("vingt"),
            not_contains("virgule"),
            starts_upper,
            ends_with_punctuation,
        ],
    ),
    TestCase(
        name="french euros",
        category="numbers-fr",
        input="ça coûte douze euros cinquante",
        language="fr",
        description="French currency: 12,50 € (symbol after, with space).",
        validators=[
            contains_pattern(r'12[,.]50\s?€', '12,50 € or 12.50€'),
            not_contains("douze"),
            starts_upper,
            ends_with_punctuation,
        ],
    ),

    # ----- French: dictated punctuation -----
    TestCase(
        name="french dictated point and virgule",
        category="punctuation-fr",
        input="bonjour virgule comment allez-vous point d'interrogation",
        language="fr",
        description="French dictated punctuation: virgule → , and point d'interrogation → ?",
        validators=[
            contains(","),
            contains("?"),
            not_contains("virgule"),
            not_contains("point d'interrogation"),
            contains("bonjour"),
        ],
    ),

    # ----- French: ordered list -----
    TestCase(
        name="french ordered list premièrement",
        category="lists-fr",
        input="les priorités sont premièrement la sécurité deuxièmement la performance troisièmement l'accessibilité",
        language="fr",
        description="French ordered signals: premièrement/deuxièmement/troisièmement.",
        validators=[
            has_numbered_list(3),
            contains("sécurité"),
            contains("performance"),
            contains("accessibilité"),
        ],
    ),

    # ----- French: repetition -----
    TestCase(
        name="french repetition",
        category="repetitions-fr",
        input="je pense je pense qu'on devrait changer l'approche",
        language="fr",
        description="Repeated phrase in French.",
        validators=[
            contains("je pense"),
            not_contains("je pense je pense"),
            contains("approche"),
            starts_upper,
            ends_with_punctuation,
        ],
    ),

    # ----- French: no translation -----
    TestCase(
        name="french stays french",
        category="no-translate-fr",
        input="le projet avance bien et les résultats sont encourageants",
        language="fr",
        description="Clean French input must NOT be translated to English.",
        validators=[
            not_contains("project"),
            not_contains("results"),
            not_contains("encouraging"),
            contains("projet"),
            contains("résultats"),
            starts_upper,
            ends_with_punctuation,
        ],
    ),
```

**Important:** The `language="fr"` field tells the `/polish` endpoint to use the French prompt. Replace `"fr"` with your language's ISO-639-1 code. This is separate from the `context` field, which is used for app context (app name, window title).

#### Categories to cover

Aim for at least one test case in each of these categories (replace `xx` with your language code):

| Category | What to test | Minimum |
|----------|-------------|---------|
| `fillers-xx` | Common filler words are removed | 2 cases |
| `corrections-xx` | Self-correction signals are handled | 1 case |
| `numbers-xx` | Spelled-out numbers become digits with correct formatting | 2 cases |
| `punctuation-xx` | Dictated punctuation commands become symbols | 1 case |
| `lists-xx` | Ordered/unordered lists are formatted | 1 case |
| `repetitions-xx` | Repeated words/phrases are collapsed | 1 case |
| `no-translate-xx` | Clean text stays in the original language | 1 case |
| `script-xx` | Script-specific rules (if applicable) | 1 case |

#### Tips for good test cases

- **Use realistic messy input.** Dictate something in your language using any speech-to-text tool and use the raw output as test input. Real transcripts are messier than what you'd type by hand.
- **Prefer `not_contains` over `matches_exactly`.** LLMs produce non-deterministic output. Checking that fillers are gone and key content words survived is more robust than checking for an exact string.
- **Test the tricky cases.** The easy cases (removing "um") usually work with the minimal prompt. Test the things that only a language-specific prompt would handle: dictated punctuation in your language, locale-specific number formatting, self-correction phrases.
- **Include a no-translation test.** Small models sometimes translate non-English text into English. A test case that asserts the output contains the original language's words (and does NOT contain the English translations) catches this.

#### If you prefer not to write Python

You can also include test cases as a table in your PR description, and we'll convert them to Python:

| Input | Expected output | What it tests |
|-------|----------------|---------------|
| "euh donc je pense qu'on devrait reporter la réunion" | "Je pense qu'on devrait reporter la réunion." | Filler removal (euh, donc) |
| "envoyez-le à Jean non attendez à Marie" | "Envoyez-le à Marie." | Self-correction (non attendez) |
| "le taux est de vingt-trois virgule cinq pour cent" | "Le taux est de 23,5 %." | Number formatting (decimal comma) |

Either format works. The table is easier to write; we'll convert to Python test cases before merging.

#### Testing manually with curl

You can also test your prompt interactively without the harness:

```bash
# Set up credentials first (pick one):
eval "$(./scripts/dev-token.sh --from-keychain)"   # if you set up via the app
# or: export FREEFLOW_SERVICE_URL=... and FREEFLOW_SESSION_TOKEN=...

curl -X POST "$FREEFLOW_SERVICE_URL/polish" \
  -H "Authorization: Bearer $FREEFLOW_SESSION_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "text": "euh donc je pense qu on devrait reporter la réunion",
    "language": "fr"
  }'
```

Note that `language` is a **top-level field** in the JSON body, not nested inside `context`. The `context` field is for app metadata (app name, window title, etc.) and is optional.

### 4. Submit a PR

Open a pull request with:
- The new prompt file (`polish_prompt_xx.txt`)
- The `polish.py` routing change
- Test cases (in `test_polish.py` or as a table in the PR description)
- A brief note about your native-speaker expertise and any design decisions you made

---

## Language codes reference

Replace `[Language Name]` and `[language_code]` in this template with the appropriate values:

| Language | Code | | Language | Code | | Language | Code |
|----------|------|-|----------|------|-|----------|------|
| Afrikaans | af | | Hungarian | hu | | Portuguese | pt |
| Arabic | ar | | Icelandic | is | | Romanian | ro |
| Azerbaijani | az | | Indonesian | id | | Russian | ru |
| Belarusian | be | | Italian | it | | Serbian | sr |
| Bosnian | bs | | Japanese | ja | | Slovak | sk |
| Bulgarian | bg | | Kannada | kn | | Slovenian | sl |
| Catalan | ca | | Kazakh | kk | | Spanish | es |
| Chinese | zh | | Korean | ko | | Swahili | sw |
| Croatian | hr | | Latvian | lv | | Swedish | sv |
| Czech | cs | | Lithuanian | lt | | Tagalog | tl |
| Danish | da | | Macedonian | mk | | Tamil | ta |
| Dutch | nl | | Malay | ms | | Thai | th |
| Estonian | et | | Marathi | mr | | Turkish | tr |
| Finnish | fi | | Maori | mi | | Ukrainian | uk |
| French | fr | | Nepali | ne | | Urdu | ur |
| Galician | gl | | Norwegian | no | | Vietnamese | vi |
| German | de | | Persian | fa | | Welsh | cy |
| Greek | el | | Polish | pl | | | |
| Hebrew | he | | | | | | |
| Hindi | hi | | | | | | |

---

## Tips for writing a good prompt

- **Be specific.** "Remove fillers" is vague. "Remove えーと, あのー, まあ, なんか, and similar hesitation sounds" is actionable.
- **Include many examples.** The English prompt has ~30 input/output examples. More examples = better LLM performance with a small model like gpt-4.1-nano.
- **Test with real dictation.** If possible, dictate some text in the language using any speech-to-text tool and use the messy output as test input.
- **Don't translate the English prompt.** Write rules that make sense for your language. Some English rules may not apply; your language may need rules English doesn't have.
- **Preserve the universal rules.** Rules 8-10 (keep tags, wording preservation, no fabrication) are universal and must be included.

You don't need to be a Python developer. The prompt is just a plain text file, and test cases can be a simple table in your PR description. We can help with the `polish.py` wiring and converting test tables to Python.

Thank you for helping make FreeFlow better for speakers of **[Language Name]**!
