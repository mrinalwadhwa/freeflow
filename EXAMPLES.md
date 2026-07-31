# Dictation examples

Use these examples as speaking patterns and replace their details with your
own. Incognito runs entirely on your Mac. Cloud sends audio to OpenAI and can
make broader edits because it uses a larger language model.

Both modes support the list, filler, punctuation, paragraph, and number
patterns below. Cloud can also apply explicit corrections and infer lists
without spoken numbering. Results can still vary with the microphone,
background noise, and how clearly a phrase is spoken.

## Works in Incognito and Cloud

### Create a numbered list

To create a numbered list in either mode, introduce it and name at least three
items with `first`, `second`, and `third`. You can also say `step one`, `step
two`, and `step three`. Incognito waits for these strong signals so it does not
turn ordinary prose into a list by accident.

```text
YOU SAY
My priorities are first verify the signed build, second review the captured logs, third preserve every original recording.

UNRAMBLE WRITES
My priorities are:
1. Verify the signed build
2. Review the captured logs
3. Preserve every original recording
```

### Remove filler sounds

Keep speaking when you hesitate. Both modes remove vocal pauses such as `um`,
`uh`, and `hmm` while keeping the words around them.

```text
YOU SAY
Um I think we should update the release notes before launch and uh send them to the team.

UNRAMBLE WRITES
I think we should update the release notes before launch and send them to the team.
```

### Speak an ellipsis

Unramble adds ordinary sentence punctuation automatically. To request a
literal ellipsis, say `dot dot dot`.

```text
YOU SAY
The first version works dot dot dot but I want to test it once more.

UNRAMBLE WRITES
The first version works… but I want to test it once more.
```

### Start a new paragraph

Sentence breaks are automatic. When the layout matters, say `new paragraph`
to insert a blank line or `new line` for a single line break.

```text
YOU SAY
The migration is complete and everything looks stable. New paragraph. I will monitor the logs through tomorrow.

UNRAMBLE WRITES
The migration is complete and everything looks stable.

I will monitor the logs through tomorrow.
```

### Format money

Say the amount as you would in conversation. Both modes convert the number and
add `$` when you say `dollars`.

```text
YOU SAY
It costs ninety nine dollars and ninety nine cents.

UNRAMBLE WRITES
It costs $99.99.
```

## Requires Cloud mode

Use Cloud when you want Unramble to apply a correction or infer structure from
the words you spoke. Incognito stays more literal. If a Cloud rewrite fails
Unramble's safety checks, the app keeps the transcript instead of risking lost
or invented words.

Press `Ctrl + Shift + M` before dictating to switch modes.

### Replace a corrected value

Correct yourself naturally with `no wait` or `sorry`. Cloud keeps the
replacement and drops the value you rejected.

```text
YOU SAY
The meeting is at two, sorry, three PM tomorrow.

UNRAMBLE WRITES
The meeting is at 3 PM tomorrow.
```

### Turn a spoken sequence into steps

Cloud can recognize an ordered sequence even when you connect each action with
`and then`. It keeps every action and formats the sequence as steps.

```text
YOU SAY
We need to update the database and then run the migrations and then restart the service and then verify that everything is working and then notify the team.

UNRAMBLE WRITES
We need to:
1. Update the database
2. Run the migrations
3. Restart the service
4. Verify that everything is working
5. Notify the team
```

### Infer an unordered list

Cloud can recognize a list from its lead-in and parallel items. Incognito
needs explicit markers, but in Cloud you do not need to say `first`, `second`,
and `third`.

```text
YOU SAY
We need to pack shirts, pants, socks, and jackets.

UNRAMBLE WRITES
We need to pack:
- Shirts
- Pants
- Socks
- Jackets
```

## Dictate hands-free

Hands-free mode changes how you start and stop recording, not how Unramble
cleans the text. It works with either Incognito or Cloud. Press
`Ctrl + Option + H` once to start recording and again to stop. You do not need
to hold the dictation key, which makes this mode useful for longer notes. You
can change the shortcut in Settings.
