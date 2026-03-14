# Help wanted: Detailed polishing prompts for 56 languages 🌍

FreeFlow is a voice-to-text app that cleans up messy speech-to-text transcriptions into polished written text. It supports 57 languages, but right now **only English gets the full treatment**. We need native speakers to help close that gap.

## The current state

After the speech-to-text engine transcribes audio, a "polishing" step sends the raw transcript through an LLM (gpt-4.1-nano) with a system prompt that tells it how to clean things up: remove filler words, fix repetitions, handle self-corrections, format numbers, convert dictated punctuation commands into actual symbols, and more.

- **English** has a detailed **136-line prompt** with **10 rules** and **~30 worked examples**. It handles English-specific fillers ("um", "uh", "like", "you know"), dictated punctuation ("period" → `.`, "comma" → `,`), US number/currency formatting, list detection, and more. See [`polish_prompt.txt`](FreeFlowService/images/main/polish_prompt.txt).

- **All 56 other languages** share a single **18-line minimal prompt** with **9 generic rules** and no language-specific examples. See [`polish_prompt_minimal.txt`](FreeFlowService/images/main/polish_prompt_minimal.txt).

The minimal prompt does a reasonable job, but it misses things that only a native speaker would know.

## What's missing: a concrete example

Here's what happens with **French** using the current minimal prompt vs. what a language-specific prompt could do:

### Raw transcript (messy speech-to-text output)
> euh donc je voulais dire que le le budget est de vingt-trois virgule cinq pour cent euh non attendez c'est plutôt vingt-quatre virgule huit pour cent et euh les priorités sont premièrement la sécurité deuxièmement la performance troisièmement l'accessibilité point

### Current result (minimal prompt)
> Je voulais dire que le budget est de vingt-trois virgule cinq pour cent, non attendez, c'est plutôt vingt-quatre virgule huit pour cent et les priorités sont premièrement la sécurité deuxièmement la performance troisièmement l'accessibilité point

Problems:
- ❌ "euh" and "donc" (French fillers) were removed, but "non attendez" (a self-correction signal) was kept as literal text instead of triggering a correction
- ❌ "vingt-quatre virgule huit pour cent" was not converted to "24,8 %" (French number formatting with decimal comma and space before %)
- ❌ "premièrement/deuxièmement/troisièmement" was not formatted as a numbered list
- ❌ "point" at the end was kept as literal text instead of being converted to `.`

### Desired result (with a French-specific prompt)
> Le budget est de 24,8 %.
>
> Les priorités sont :
> 1. La sécurité
> 2. La performance
> 3. L'accessibilité

That's the difference a language-specific prompt makes.

## How you can help

If you're a native speaker (or highly fluent) in any of the languages below, you can write a detailed polishing prompt tailored to that language. **This is a great first contribution**: it's self-contained, doesn't require deep knowledge of the codebase, and directly improves the experience for every speaker of your language.

### What you'll do

1. **Create a prompt file** at `FreeFlowService/images/main/polish_prompt_{code}.txt` (e.g., `polish_prompt_fr.txt` for French)
2. **Wire it up** in `FreeFlowService/images/main/polish.py` so your language uses its own prompt instead of the minimal fallback
3. **Add test cases** in `FreeFlowService/tests/test_polish.py` — see the detailed guide below
4. **Open a PR**

### What the prompt should cover

Use the [English prompt](FreeFlowService/images/main/polish_prompt.txt) as a structural reference. Your prompt should address:

- **Filler words**: list the common fillers and hesitation sounds in your language
- **Self-correction signals**: what phrases do speakers use to restart or correct themselves?
- **Dictated punctuation**: map spoken commands to symbols (the equivalent of saying "period" to get `.`)
- **Number/currency formatting**: decimal separator (comma vs. period), thousands separator, currency symbol placement
- **List formatting**: how speakers signal ordered vs. unordered lists
- **Script-specific rules**: if your language uses multiple scripts or has script-mixing issues
- **Honorifics/formality**: if your language has formality levels (keigo, honorifics, T-V distinction), the prompt should preserve them
- **Concrete examples**: for every rule, include before/after examples in the target language. More examples = better results with a small model.
- **Universal rules**: always include `<keep>` tag preservation, wording preservation, and no-fabrication constraints

### How to test: contributing test cases

Test cases are just as valuable as the prompt itself. They validate that the prompt works, catch regressions, and serve as documentation of what your prompt handles. The English prompt has 48 test cases across 15 categories. Your language contribution should include at least 8-12 test cases.

#### The test harness

The test suite lives at [`FreeFlowService/tests/test_polish.py`](FreeFlowService/tests/test_polish.py). Each test case is a `TestCase` object with an input string (messy transcript), a list of validators (structural checks on the output), and metadata. The harness sends each input to the `/polish` endpoint multiple times (default 5) to surface non-deterministic LLM behavior, then checks every run against the validators.

Each `TestCase` has a `language` field (ISO-639-1 code) that the harness passes as a top-level field to the `/polish` endpoint. This is separate from the `context` field, which carries app metadata (app name, window title). Existing English tests leave `language=None` and behave as before.

#### How to run tests

```bash
cd FreeFlowService

# If you set up FreeFlow via the app, read credentials from Keychain:
eval "$(./scripts/dev-token.sh --from-keychain)"

# Or if you have secrets.yaml (developer workflow):
export FREEFLOW_SERVICE_URL="https://YOUR-CLUSTER-ID-freeflow.cluster.autonomy.computer"
export FREEFLOW_SESSION_TOKEN="$(./scripts/dev-token.sh)"

# Run all tests
python3 tests/test_polish.py

# Run only your language's tests
python3 tests/test_polish.py --category fillers-fr

# Run a single test by name
python3 tests/test_polish.py --name "french filler euh"

# More repetitions for consistency checking
python3 tests/test_polish.py --category fillers-fr --reps 10

# See all outputs, not just failures
python3 tests/test_polish.py --category fillers-fr --verbose
```

#### Available validators

The harness provides these validators you can use in your test cases:

| Validator | What it checks |
|-----------|---------------|
| `contains("text")` | Output contains the substring (case-insensitive) |
| `not_contains("text")` | Output does NOT contain the substring (case-insensitive) |
| `starts_upper` | Output starts with an uppercase letter |
| `ends_with_punctuation` | Output ends with `.` `!` `?` `)` `"` |
| `has_bullet_list(n)` | Output contains at least `n` lines starting with `- ` |
| `has_numbered_list(n)` | Output contains at least `n` lines starting with `1.` `2.` etc. |
| `no_list_formatting` | Output does NOT contain bullet or numbered list markers |
| `is_single_line` | Output is a single line (no newlines) |
| `matches_exactly("text")` | Output matches exactly (case-insensitive, stripped) |
| `contains_digit` | Output contains at least one digit |
| `contains_pattern(r"regex", "description")` | Output matches the regex pattern |
| `max_length(n)` | Output is at most `n` characters |
| `shorter_than_input` | Output is shorter than the input |

#### How to add test cases

Add your test cases to the `TESTS` list in `test_polish.py`. Use a category prefix with your language code (e.g., `fillers-fr`, `numbers-fr`, `corrections-fr`). Each test case also needs a `language` field passed via the `context` parameter so the server routes to your language-specific prompt.

Here's a complete example for French. Copy this pattern and adapt it for your language:

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

#### What categories to cover

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

#### Testing without the test harness

If you don't want to modify the Python test file, you can test your prompt manually with curl:

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

You can also include test cases as a table in your PR description instead of Python code, and we'll help convert them:

| Input | Expected output | What it tests |
|-------|----------------|---------------|
| "euh donc je pense qu'on devrait reporter la réunion" | "Je pense qu'on devrait reporter la réunion." | Filler removal (euh, donc) |
| "envoyez-le à Jean non attendez à Marie" | "Envoyez-le à Marie." | Self-correction (non attendez) |

Either format works. The table is easier to write; we'll convert to Python test cases before merging.

## Tracking: 56 languages

### 🔥 High-impact languages (start here)

These have the largest speaker populations and likely user bases:

- [ ] **Spanish** (`es`) — fillers: "este", "eh", "bueno", "o sea", "pues"; decimal comma; € placement
- [ ] **French** (`fr`) — fillers: "euh", "ben", "donc", "en fait", "tu vois"; decimal comma; guillemets « »
- [ ] **German** (`de`) — fillers: "ähm", "äh", "also", "halt"; decimal comma; Sie/du preservation
- [ ] **Portuguese** (`pt`) — fillers: "tipo", "né", "então"; decimal comma; Brazilian vs. European variants
- [ ] **Japanese** (`ja`) — fillers: "えーと", "あのー", "まあ"; full-width punctuation 。、; keigo preservation
- [ ] **Chinese** (`zh`) — fillers: "那个", "嗯", "就是", "然后"; full-width punctuation; no spaces between words
- [ ] **Korean** (`ko`) — fillers: "음", "어", "그", "뭐"; honorific levels (존댓말/반말); Korean punctuation
- [ ] **Hindi** (`hi`) — fillers: "यानि", "मतलब", "अच्छा"; Devanagari script enforcement; ₹ formatting
- [ ] **Arabic** (`ar`) — fillers: "يعني", "هلأ", "طيب"; RTL punctuation; Arabic-Indic numerals vs. Western
- [ ] **Russian** (`ru`) — fillers: "ну", "вот", "типа", "как бы", "значит"; decimal comma; ₽ formatting

### All other languages

- [ ] Afrikaans (`af`)
- [ ] Azerbaijani (`az`)
- [ ] Belarusian (`be`)
- [ ] Bosnian (`bs`)
- [ ] Bulgarian (`bg`)
- [ ] Catalan (`ca`)
- [ ] Croatian (`hr`)
- [ ] Czech (`cs`)
- [ ] Danish (`da`)
- [ ] Dutch (`nl`)
- [ ] Estonian (`et`)
- [ ] Finnish (`fi`)
- [ ] Galician (`gl`)
- [ ] Greek (`el`)
- [ ] Hebrew (`he`)
- [ ] Hungarian (`hu`)
- [ ] Icelandic (`is`)
- [ ] Indonesian (`id`)
- [ ] Italian (`it`)
- [ ] Kannada (`kn`)
- [ ] Kazakh (`kk`)
- [ ] Latvian (`lv`)
- [ ] Lithuanian (`lt`)
- [ ] Macedonian (`mk`)
- [ ] Malay (`ms`)
- [ ] Maori (`mi`)
- [ ] Marathi (`mr`)
- [ ] Nepali (`ne`)
- [ ] Norwegian (`no`)
- [ ] Persian (`fa`)
- [ ] Polish (`pl`)
- [ ] Romanian (`ro`)
- [ ] Serbian (`sr`)
- [ ] Slovak (`sk`)
- [ ] Slovenian (`sl`)
- [ ] Swahili (`sw`)
- [ ] Swedish (`sv`)
- [ ] Tagalog (`tl`)
- [ ] Tamil (`ta`)
- [ ] Thai (`th`)
- [ ] Turkish (`tr`)
- [ ] Ukrainian (`uk`)
- [ ] Urdu (`ur`)
- [ ] Vietnamese (`vi`)
- [ ] Welsh (`cy`)

## Reference files

| File | Description |
|------|-------------|
| [`FreeFlowService/images/main/polish_prompt.txt`](FreeFlowService/images/main/polish_prompt.txt) | English prompt (136 lines, 10 rules, ~30 examples). **Use as structural reference.** |
| [`FreeFlowService/images/main/polish_prompt_minimal.txt`](FreeFlowService/images/main/polish_prompt_minimal.txt) | Current minimal prompt for all non-English languages (18 lines, 9 generic rules) |
| [`FreeFlowService/images/main/polish.py`](FreeFlowService/images/main/polish.py) | The polishing pipeline. See `_load_prompt_file()`, `_is_english()`, `polish_text()`, and `_polish_minimal()` |
| [`FreeFlowService/tests/test_polish.py`](FreeFlowService/tests/test_polish.py) | Test suite (48 cases, 15 categories, structural validators). Add your language's test cases here. |
| [`FreeFlowService/images/main/main.py`](FreeFlowService/images/main/main.py) | Server entry point. The `POST /polish` endpoint accepts `{"text": ..., "language": "xx"}`. |

## Questions?

If you're unsure about anything, comment on this issue or on your PR. We're happy to help. You don't need to be a Python developer to contribute a prompt file. The prompt itself is just a plain text file and is the most valuable part. Test cases can be submitted as a simple table of inputs and expected outputs in your PR description; we can convert them to Python. We can also help with the `polish.py` wiring.

Thank you for helping make FreeFlow work better in your language! 🙏
