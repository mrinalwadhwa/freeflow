# Dictation examples

Unramble has two modes. Incognito runs entirely on your Mac. Cloud sends audio
to OpenAI and can make broader edits because it uses a larger language model.

The first examples work in both modes. The later examples require Cloud mode.
Speech recognition can still vary with the microphone, background noise, and
how clearly a phrase is spoken.

## Works in Incognito and Cloud

### Create a numbered list

For the most reliable list formatting, introduce the list and say at least
three explicit markers such as `first`, `second`, and `third`. You can also say
`step one`, `step two`, and `step three`.

```text
YOU SAY
My priorities are first fix the login bug, second add caching, third write documentation.

UNRAMBLE WRITES
My priorities are:
1. Fix the login bug
2. Add caching
3. Write documentation
```

Incognito only turns a phrase into a vertical list when the wording strongly
signals one. This prevents an ordinary sentence from becoming a list by
accident.

### Remove filler sounds

Unramble removes filler sounds such as `um`, `uh`, and `hmm` when they do not
add meaning.

```text
YOU SAY
Hmm, I think the best approach would be to refactor first.

UNRAMBLE WRITES
I think the best approach would be to refactor first.
```

### Speak an ellipsis

Say `dot dot dot` when you want an ellipsis.

```text
YOU SAY
I was thinking, dot dot dot, maybe we should wait.

UNRAMBLE WRITES
I was thinking… maybe we should wait.
```

### Start a new paragraph

Say `new paragraph` to insert a blank line. Say `new line` for a single line
break.

```text
YOU SAY
The draft is ready. New paragraph. Send it to the team.

UNRAMBLE WRITES
The draft is ready.

Send it to the team.
```

### Format money

Speak an amount naturally. Unramble converts the number and adds `$` when you
say `dollars`.

```text
YOU SAY
It costs ninety-nine dollars and ninety-nine cents.

UNRAMBLE WRITES
It costs $99.99.
```

## Requires Cloud mode

Cloud mode can interpret revisions and infer structure that Incognito
deliberately preserves as spoken text. If a rewrite fails Unramble's safety
checks, the app keeps the more literal transcript instead of risking lost or
invented words.

Press `Ctrl + Shift + M` to switch modes.

### Replace a corrected value

State the correction explicitly with a phrase such as `no wait`, `sorry`, or
`I mean`.

```text
YOU SAY
Let's set the timeout to thirty. No wait, make it sixty seconds since some of these requests are slow.

UNRAMBLE WRITES
Make it 60 seconds, since some of these requests are slow.
```

### Drop an abandoned start

Cloud mode can remove an earlier plan when the speaker rejects it and starts
again.

```text
YOU SAY
I was thinking we could ship on Friday, but actually no, let's keep it on Monday so we have a buffer.

UNRAMBLE WRITES
Let's keep it on Monday, so we have a buffer.
```

### Infer an unordered list

Cloud mode can recognize a list from meaning alone. You do not need to say
`first`, `second`, and `third`.

```text
YOU SAY
The concerns are performance, reliability, and cost.

UNRAMBLE WRITES
The concerns are:
- Performance
- Reliability
- Cost
```

## Dictate hands-free

Hands-free mode works with either Incognito or Cloud. Press
`Ctrl + Option + H` once to start recording and again to stop. You do not need
to hold the dictation key, which makes this mode useful for longer notes. You
can change the shortcut in Settings.
