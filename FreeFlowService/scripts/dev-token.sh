#!/usr/bin/env bash
#
# Obtain a valid session token for a FreeFlow zone and print it to
# stdout. Supports two modes: reading credentials from the macOS
# Keychain (for users who provisioned via the app) or minting a fresh
# token via the bootstrap flow (for developers with secrets.yaml).
#
# Usage:
#   # Print a session token (use in test harnesses):
#   export FREEFLOW_SESSION_TOKEN="$(./scripts/dev-token.sh)"
#
#   # If you provisioned your zone via the FreeFlow app, read
#   # credentials directly from the macOS Keychain:
#   eval "$(./scripts/dev-token.sh --from-keychain)"
#   # This prints export commands for both FREEFLOW_SERVICE_URL and
#   # FREEFLOW_SESSION_TOKEN, ready to eval or copy-paste.
#
#   # Write credentials into macOS Keychain so the app can launch
#   # directly on the normal auth path (skips onboarding):
#   ./scripts/dev-token.sh --keychain
#
#   # Also set hasCompletedOnboarding in UserDefaults:
#   ./scripts/dev-token.sh --keychain --onboarded
#
#   # Use a specific zone URL:
#   FREEFLOW_SERVICE_URL="http://localhost:8000" ./scripts/dev-token.sh
#
#   # Force a fresh admin session (ignore cached token):
#   ./scripts/dev-token.sh --fresh
#
# How it works (default mode):
#   1. Read zone URL and bootstrap token from secrets.yaml.
#   2. Try to redeem the bootstrap token via POST /api/auth/redeem-invite.
#      - If it succeeds, we're the first admin. Cache the admin session.
#      - If it fails (admin already exists), use the cached admin session.
#   3. Use the admin session to create a regular invite via the admin API.
#   4. Redeem the invite to get a fresh session token.
#   5. Print the session token to stdout (all other output goes to stderr).
#
# How it works (--from-keychain mode):
#   1. Read the zone URL and session token from the macOS Keychain
#      where the FreeFlow app stored them during provisioning.
#   2. Validate the session against the zone's /api/auth/session endpoint.
#   3. Print export commands for FREEFLOW_SERVICE_URL and
#      FREEFLOW_SESSION_TOKEN to stdout.
#
# The admin session token is cached in .dev-admin-token so we don't
# burn the single-use bootstrap token on every run. If the cached
# token expires, delete .dev-admin-token and run again.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_FILE="$SERVICE_DIR/secrets.yaml"
CACHE_FILE="$SERVICE_DIR/.dev-admin-token"
BUNDLE_ID="computer.autonomy.freeflow"

# Defaults.
write_keychain=false
set_onboarded=false
force_fresh=false
from_keychain=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keychain)       write_keychain=true; shift ;;
        --onboarded)      set_onboarded=true; shift ;;
        --fresh)          force_fresh=true; shift ;;
        --from-keychain)  from_keychain=true; shift ;;
        -h|--help)
            sed -n '2,/^$/{ s/^#//; s/^ //; p }' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# -----------------------------------------------------------------------
# --from-keychain mode: read existing credentials from macOS Keychain
#
# When a user provisions a zone via the FreeFlow app, the app stores
# the zone URL and session token in the macOS Keychain under the
# service name "computer.autonomy.freeflow". This mode reads those
# credentials directly, validates the session, and prints export
# commands ready for eval or copy-paste.
#
# This is the recommended path for users who set up FreeFlow via the
# app and want to run tests or use the API from the command line.
# -----------------------------------------------------------------------

if [[ "$from_keychain" == true ]]; then
    echo "Reading credentials from macOS Keychain..." >&2

    kc_url="$(security find-generic-password -s "$BUNDLE_ID" -a "service-url" -w 2>/dev/null)" || {
        echo "ERROR: No service URL found in Keychain." >&2
        echo "" >&2
        echo "The FreeFlow app stores credentials in the Keychain when you" >&2
        echo "provision a zone. If you haven't set up the app yet, launch" >&2
        echo "FreeFlow and complete the onboarding flow first." >&2
        echo "" >&2
        echo "If you're a developer with secrets.yaml, run without --from-keychain." >&2
        exit 1
    }

    kc_token="$(security find-generic-password -s "$BUNDLE_ID" -a "session-token" -w 2>/dev/null)" || {
        echo "ERROR: No session token found in Keychain." >&2
        echo "" >&2
        echo "The zone URL was found ($kc_url) but no session token." >&2
        echo "Try signing in again via the FreeFlow app." >&2
        exit 1
    }

    if [[ -z "$kc_url" ]] || [[ -z "$kc_token" ]]; then
        echo "ERROR: Keychain returned empty values." >&2
        exit 1
    fi

    echo "Zone: $kc_url" >&2

    # Validate the session token against the zone.
    echo "Validating session..." >&2
    http_status="$(curl -s -o /dev/null -w "%{http_code}" \
        "$kc_url/api/auth/get-session" \
        -H "Authorization: Bearer $kc_token" \
        2>/dev/null)" || true

    if [[ "$http_status" == "200" ]]; then
        echo "Session valid." >&2
    elif [[ "$http_status" == "401" ]]; then
        echo "WARNING: Session token may be expired (HTTP 401)." >&2
        echo "Try signing in again via the FreeFlow app, or use the" >&2
        echo "People page to create a new invite." >&2
        echo "Printing credentials anyway (they may not work)." >&2
    elif [[ "$http_status" == "000" ]]; then
        echo "WARNING: Could not reach zone at $kc_url" >&2
        echo "The zone may be down or unreachable." >&2
        echo "Printing credentials anyway." >&2
    else
        echo "WARNING: Session validation returned HTTP $http_status." >&2
        echo "Printing credentials anyway." >&2
    fi

    # Print export commands to stdout.
    echo "export FREEFLOW_SERVICE_URL=\"$kc_url\""
    echo "export FREEFLOW_SESSION_TOKEN=\"$kc_token\""

    echo "" >&2
    echo "Run this to set up your shell:" >&2
    echo "  eval \"\$(./scripts/dev-token.sh --from-keychain)\"" >&2

    exit 0
fi

# -----------------------------------------------------------------------
# Read configuration
# -----------------------------------------------------------------------

if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "ERROR: $SECRETS_FILE not found." >&2
    echo "Copy secrets.yaml.example and fill in your values." >&2
    exit 1
fi

# Read the bootstrap token from secrets.yaml.
BOOTSTRAP_TOKEN=""
if grep -q 'BOOTSTRAP_TOKEN:' "$SECRETS_FILE" 2>/dev/null; then
    BOOTSTRAP_TOKEN="$(grep 'BOOTSTRAP_TOKEN:' "$SECRETS_FILE" | head -1 | sed 's/.*: *//' | tr -d '[:space:]')"
fi
if [[ -z "$BOOTSTRAP_TOKEN" ]]; then
    echo "ERROR: No BOOTSTRAP_TOKEN found in $SECRETS_FILE" >&2
    exit 1
fi

# Zone URL: env var required, fall back to localhost for local dev.
if [[ -z "${FREEFLOW_SERVICE_URL:-}" ]]; then
    echo "FREEFLOW_SERVICE_URL not set, defaulting to http://localhost:8000" >&2
fi
BASE_URL="${FREEFLOW_SERVICE_URL:-http://localhost:8000}"
BASE_URL="${BASE_URL%/}"

echo "Zone: $BASE_URL" >&2

# -----------------------------------------------------------------------
# Helper: call the API
# -----------------------------------------------------------------------

api_post() {
    local path="$1"
    local body="$2"
    local auth_header="${3:-}"

    local -a curl_args=(
        -s -S
        -X POST
        "$BASE_URL$path"
        -H "Content-Type: application/json"
        -d "$body"
        -w "\n%{http_code}"
        --include
    )
    if [[ -n "$auth_header" ]]; then
        curl_args+=(-H "Authorization: Bearer $auth_header")
    fi

    curl "${curl_args[@]}" 2>&1
}

extract_header() {
    # Extract a header value from curl --include output (case-insensitive).
    local response="$1"
    local header_name="$2"
    echo "$response" | grep -i "^${header_name}:" | head -1 | sed "s/^[^:]*: *//" | tr -d '\r\n'
}

extract_body() {
    # Extract the response body from curl --include output.
    # The body follows the first blank line after headers.
    # Drop the last line which is the HTTP status code from -w.
    echo "$response" | sed '1,/^\r*$/d' | sed '$d'
}

extract_status() {
    # Extract the HTTP status code (last line from -w "\n%{http_code}").
    echo "$response" | tail -1 | tr -d '[:space:]'
}

# -----------------------------------------------------------------------
# Step 1: Get an admin session token
# -----------------------------------------------------------------------

admin_token=""

# Check cache first (unless --fresh).
if [[ "$force_fresh" == false ]] && [[ -f "$CACHE_FILE" ]]; then
    cached="$(cat "$CACHE_FILE" | tr -d '[:space:]')"
    if [[ -n "$cached" ]]; then
        echo "Using cached admin session." >&2
        admin_token="$cached"
    fi
fi

if [[ -z "$admin_token" ]]; then
    echo "Redeeming bootstrap token..." >&2
    response="$(api_post "/api/auth/redeem-invite" "{\"token\": \"$BOOTSTRAP_TOKEN\"}")"
    status="$(extract_status)"

    if [[ "$status" == "200" ]]; then
        # Extract session token from set-auth-token header.
        admin_token="$(extract_header "$response" "set-auth-token")"
        if [[ -z "$admin_token" ]]; then
            echo "ERROR: 200 response but no set-auth-token header." >&2
            echo "$response" >&2
            exit 1
        fi
        echo "Bootstrap token redeemed. Admin session created." >&2
        # Cache the admin token for future runs.
        echo "$admin_token" > "$CACHE_FILE"
        chmod 600 "$CACHE_FILE"
    elif [[ "$status" == "401" ]]; then
        echo "Bootstrap token already used (admin exists)." >&2
        echo "Delete $CACHE_FILE and the admin_users row to reset, or provide a cached token." >&2
        exit 1
    else
        body="$(extract_body)"
        echo "ERROR: Bootstrap redemption failed (HTTP $status)." >&2
        echo "$body" >&2
        exit 1
    fi
fi

# -----------------------------------------------------------------------
# Step 2: Create an invite using the admin session
# -----------------------------------------------------------------------

echo "Creating invite..." >&2
response="$(api_post "/admin/api/invites" '{"label": "dev-token", "max_uses": 1}' "$admin_token")"
status="$(extract_status)"
body="$(extract_body)"

if [[ "$status" == "401" ]] || [[ "$status" == "403" ]]; then
    echo "Admin session expired or invalid. Clearing cache and retrying..." >&2
    rm -f "$CACHE_FILE"

    # Retry: redeem bootstrap token.
    echo "Redeeming bootstrap token..." >&2
    response="$(api_post "/api/auth/redeem-invite" "{\"token\": \"$BOOTSTRAP_TOKEN\"}")"
    status="$(extract_status)"

    if [[ "$status" == "200" ]]; then
        admin_token="$(extract_header "$response" "set-auth-token")"
        if [[ -n "$admin_token" ]]; then
            echo "$admin_token" > "$CACHE_FILE"
            chmod 600 "$CACHE_FILE"
            echo "Re-authenticated as admin." >&2

            # Retry create invite.
            response="$(api_post "/admin/api/invites" '{"label": "dev-token", "max_uses": 1}' "$admin_token")"
            status="$(extract_status)"
            body="$(extract_body)"
        fi
    fi

    if [[ "$status" != "200" ]]; then
        echo "ERROR: Could not create invite (HTTP $status)." >&2
        echo "$body" >&2
        echo "" >&2
        echo "If the admin already exists and the bootstrap token is spent," >&2
        echo "you need to manually provide an admin session token:" >&2
        echo "  echo '<session-token>' > $CACHE_FILE" >&2
        exit 1
    fi
fi

if [[ "$status" != "200" ]]; then
    echo "ERROR: Failed to create invite (HTTP $status)." >&2
    echo "$body" >&2
    exit 1
fi

# Parse the invite token from the JSON response.
invite_token="$(echo "$body" | python3 -c "import sys, json; print(json.load(sys.stdin)['token'])" 2>/dev/null)" || {
    echo "ERROR: Could not parse invite token from response." >&2
    echo "$body" >&2
    exit 1
}

echo "Invite created." >&2

# -----------------------------------------------------------------------
# Step 3: Redeem the invite to get a user session token
# -----------------------------------------------------------------------

echo "Redeeming invite..." >&2
response="$(api_post "/api/auth/redeem-invite" "{\"token\": \"$invite_token\"}")"
status="$(extract_status)"

if [[ "$status" != "200" ]]; then
    body="$(extract_body)"
    echo "ERROR: Invite redemption failed (HTTP $status)." >&2
    echo "$body" >&2
    exit 1
fi

session_token="$(extract_header "$response" "set-auth-token")"
if [[ -z "$session_token" ]]; then
    echo "ERROR: 200 response but no set-auth-token header." >&2
    echo "$response" >&2
    exit 1
fi

echo "Session token obtained." >&2

# -----------------------------------------------------------------------
# Step 4 (optional): Write to Keychain
# -----------------------------------------------------------------------

if [[ "$write_keychain" == true ]]; then
    echo "Writing credentials to Keychain..." >&2

    # Delete existing entries (ignore errors if they don't exist).
    security delete-generic-password -s "$BUNDLE_ID" -a "service-url" 2>/dev/null || true
    security delete-generic-password -s "$BUNDLE_ID" -a "session-token" 2>/dev/null || true
    security delete-generic-password -s "$BUNDLE_ID" -a "autonomy-token" 2>/dev/null || true
    security delete-generic-password -s "$BUNDLE_ID" -a "user-email" 2>/dev/null || true

    # Write new entries.
    security add-generic-password -s "$BUNDLE_ID" -a "service-url" -w "$BASE_URL" -U
    security add-generic-password -s "$BUNDLE_ID" -a "session-token" -w "$session_token" -U

    echo "Keychain updated: service-url + session-token" >&2
fi

if [[ "$set_onboarded" == true ]]; then
    defaults write "$BUNDLE_ID" hasCompletedOnboarding -bool true
    echo "UserDefaults: hasCompletedOnboarding = true" >&2
fi

# -----------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------

echo "$session_token"
