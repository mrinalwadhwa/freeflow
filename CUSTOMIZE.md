# Customize FreeFlow

FreeFlow is designed to be taken apart and reassembled. This guide walks
through the most common customization: changing how your dictation is
polished, deploying your own server with those changes, and connecting
the app to it.

## Overview

The steps are:

1. Fork the repo and edit what you want (a prompt, a model, anything).
2. Generate secrets and deploy your modified server with `autonomy zone deploy`.
3. Connect your app to the new zone.
4. Invite your team.

Your team members install the standard FreeFlow app. They choose
"I have an invite link" on first launch and click the invite you send
them. No custom builds needed on their end.

## 1. Fork and edit

Fork the repo and clone it:

    git clone https://github.com/<you>/freeflow.git
    cd freeflow

### Change a prompt

The polish prompts are plain text files in `FreeFlowService/images/main/`:

| File | What it controls |
|------|-----------------|
| `polish_prompt.txt` | English: filler removal, list formatting, dictated punctuation, corrections, number formatting, wording preservation |
| `polish_prompt_minimal.txt` | All other languages: light cleanup that preserves original phrasing |

Open `polish_prompt.txt` and add a rule. For example, to make the
polish step produce British English:

    11. British English: use British spelling conventions. "organize" becomes
        "organise", "color" becomes "colour", "center" becomes "centre", etc.

Or to format code identifiers in backticks:

    11. Code identifiers: when the speaker mentions a function, variable,
        class name, or file path, wrap it in backticks. "the render function"
        becomes "the `render` function".

Add your rule at the end of the numbered list, before the final
instructions about language preservation and output format.

### Change a model

Three constants control the entire AI pipeline. They are at the top of
two Python files in `FreeFlowService/images/main/`:

| Constant | File | Default | What it does |
|----------|------|---------|-------------|
| `REALTIME_MODEL` | `realtime.py` | `gpt-4o-realtime-preview` | Streaming speech-to-text via the Realtime API |
| `STT_MODEL` | `realtime.py` | `gpt-4o-mini-transcribe` | Transcription model within the Realtime session |
| `POLISH_MODEL` | `polish.py` | `gpt-4.1-nano` | Text cleanup after transcription |

Change the string, deploy, done. Autonomy's model gateway routes to
the new model. No API key management, no provider SDK changes.

For example, switching to `gpt-realtime-mini` cuts the per-dictation
cost from roughly $0.007 to $0.002:

    REALTIME_MODEL = "gpt-realtime-mini"

## 2. Deploy

FreeFlow runs on [Autonomy](https://autonomy.computer). The `autonomy`
command builds your Docker image, pushes it to a registry provisioned
for you, and deploys the zone. You do not need to set up your own
container registry or cloud credentials.

### Pick a zone name

Open `FreeFlowService/autonomy.yaml` and change the zone name to
something unique to you:

    name: ffacme

This gives you a completely fresh zone, independent of the default
FreeFlow provisioning flow.

### Generate secrets

Create `FreeFlowService/secrets.yaml` from the example:

    cd FreeFlowService
    cp secrets.yaml.example secrets.yaml

Generate random values for both secrets:

    cat > secrets.yaml <<EOF
    BETTER_AUTH_SECRET: $(openssl rand -hex 32)
    BOOTSTRAP_TOKEN: $(openssl rand -hex 32)
    EOF

`BETTER_AUTH_SECRET` is used by the auth service to sign session
tokens. `BOOTSTRAP_TOKEN` is the one-time token that makes the first
person to redeem it the zone's admin. Keep `secrets.yaml` safe and
do not commit it.

### Deploy the zone

    cd FreeFlowService
    autonomy zone deploy

The CLI will:

1. Read `autonomy.yaml` and `secrets.yaml` from the current directory.
2. Build the Docker image from `images/main/Dockerfile`.
3. Provision a container registry and push the image.
4. Create the zone, push the secrets, and start the pod.

When it finishes, it prints the zone name and cluster ID. Your zone
URL is:

    https://<cluster_id>-<zone_name>.cluster.autonomy.computer

For example, if the cluster is `a1b2c3` and the zone name is
`ffacme`:

    https://a1b2c3-ffacme.cluster.autonomy.computer

Wait a minute or two for the pod to start, then verify:

    curl -s https://<cluster_id>-<zone_name>.cluster.autonomy.computer/health

You should see `{"status":"ok","auth":"ok"}`.

## 3. Connect your app

Open the FreeFlow app's connect URL with your zone URL and bootstrap
token. The bootstrap token is in the `secrets.yaml` you just created:

    open "freeflow://connect?url=https://<cluster_id>-<zone_name>.cluster.autonomy.computer&token=<BOOTSTRAP_TOKEN>"

This tells the app to connect to your zone and redeem the bootstrap
token. You become the zone's admin. The app walks you through
onboarding: microphone permissions, accessibility, and a test
dictation.

## 4. Invite your team

Once you are connected as admin, open the FreeFlow menu and click
"Invite People..." to create invite links. Each invite generates a
URL that you can share.

Your team members install the standard FreeFlow app (via Homebrew or
DMG). On first launch they choose "I have an invite link", then click
the link you sent them. The app connects to your zone and walks them
through onboarding.

No custom builds are needed on their end. They use the same app,
pointed at your zone running your customized server.

## Redeploying changes

After you make more changes to the server code, redeploy:

    cd FreeFlowService
    autonomy zone deploy

The `autonomy zone deploy` command rebuilds the image, pushes it, and restarts the zone. Your
zone URL, database, secrets, and all user sessions are preserved.
Everyone on your team picks up the changes on their next dictation
without doing anything.
