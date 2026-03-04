# Instructions for Coding Agents

## Terminology

The word "agent" refers exclusively to Autonomy Agents. Do not use "agent" for coding sessions,
development tracks, or any other purpose.

## App Name

"Voice" is a working name. The app will be renamed at some point. Keep naming centralized and
easy to change.

## File Formatting

- Every file must end with exactly one newline.
- No trailing whitespace on any line.

## Committed Artifacts

In source code, README, CLAUDE.md, and commit messages:
- describe only what the code is and what it does.
- do not mention planning docs, reference docs, or tracking docs.
- do not reference phase numbers, track names, or internal project tracking.

## Testing

The project uses two test frameworks side by side:

- **XCTest** — used by capture-track tests (RecordingCoordinatorTests, WAVEncoderTests,
  DictationPipelineTests).
- **Swift Testing** — used by context-track tests (ContextAssemblyTests, MockTests, etc.).

`swift test` runs both in a single invocation, but its final summary line only counts Swift
Testing tests. Always use `make test`, which parses the full output and prints a combined total
from both frameworks. Verify the "Combined" line at the end to confirm all tests passed.

```bash
make test
# ── Combined: 219 tests (77 XCTest + 142 Swift Testing), 0 failures ──
```

## Interactive Commands

Some git commands open an interactive pager that blocks terminal execution. Always pipe output
to prevent blocking:

```bash
git log --oneline -10 | cat
git diff | cat
git diff --stat | cat
git diff --name-only | cat
git show | cat
git branch -a | cat
```

Or use the `--no-pager` flag:

```bash
git --no-pager log --oneline -10
git --no-pager diff
```

## Git Workflow

- Commit working code as you go. Run `make test` before each commit to confirm all tests pass.
- `.scratch/` is gitignored.
- Use the `.scratch` directory for notes, temporary tests, or experimental code that should not
  be committed.
  - Create a dedicated subfolder within `.scratch` for each task (e.g., `.scratch/feature-name`).
  - Before creating a new subfolder, check if one already exists for the current work.

## Commit Messages

- Use imperative mood and active voice.
- Start the subject line with a verb: "Add", "Fix", "Update", "Remove", "Refactor".
- Keep the subject line under 50 characters.
- Capitalize the first letter of the subject line.
- Do not end the subject line with a period.
- Separate the subject from the body with a blank line.
- Wrap the body at 72 characters.
- Use the body to explain what and why, not how.
- Focus on the change itself, not the process of making it.
- Write as if completing the sentence: "If applied, this commit will..."
- Do not mention test counts or pass rates in commit messages.

## Writing Style

### Use Active Verb Forms

When writing comments, doc comments, commit messages, or documentation, prefer active verb
phrases over nominalized noun phrases.

Active verbs are clearer, more direct, and easier to scan.

| Avoid (Nominalized)               | Prefer (Active)                 |
|------------------------------------|---------------------------------|
| Audio buffer management            | Manage audio buffers            |
| Permission state checking          | Check permission state          |
| Recording state transition         | Transition recording state      |
| Context assembly and caching       | Assemble and cache context      |
| Text injection handling            | Inject text                     |

### Prefer "to + verb" Over "for + gerund"

When describing what a module or function does, use infinitive phrases:

| Avoid                                            | Prefer                                        |
|--------------------------------------------------|-----------------------------------------------|
| "provides methods for capturing audio"           | "provides methods to capture audio"           |
| "for reading accessibility attributes"           | "to read accessibility attributes"            |
| "for managing recording state transitions"       | "to manage recording state transitions"       |

### Where This Applies

- Function and method doc comments
- TODO comments
- Commit messages
- README sections
- Inline comments explaining intent

### Exceptions

Nominalized forms are acceptable for:
- Type names (`AudioProvider`, `PermissionManager`)
- Protocol names (`AudioProviding`, `TextInjecting`)
- Module names
- When the noun form is the actual domain term

### Quick Test

If you can ask "Who does what?" and rewrite to answer that question with a subject + verb,
use the active form.

## Documentation

Don't create too many summary documents and markdown files.