#!/usr/bin/env bash
# Fails if tracked content looks like it came from a real mailbox or a real Google account.
#
# Everything committed here is synthetic. This checks the properties that would be violated
# first if that ever stopped being true: a real correspondent's address, a credential of
# plausible length, a file that belongs only on one developer's Mac.
#
# It cannot prove the absence of real data. It pins down the shapes that have a mechanical
# answer and leaves the rest to review.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
fail() { echo "FAIL: $1"; status=1; }

# --- Addresses -------------------------------------------------------------------------------
# Fixtures use the domains RFC 2606 and RFC 6761 reserve for documentation, so anything else is
# either a real correspondent or a real service that should not be written to.
if addresses=$(git grep -hoI -E "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}" -- . 2>/dev/null); then
    foreign=$(echo "$addresses" | sed 's/.*@//' | tr '[:upper:]' '[:lower:]' | sort -u |
        grep -v -E "(^|\.)(example\.(com|org|net|invalid)|example|test|localhost|invalid)$" || true)
    if [ -n "$foreign" ]; then
        fail "email addresses outside the reserved documentation domains:"
        echo "$foreign" | sed 's/^/    /'
    fi
fi

# --- Credentials -----------------------------------------------------------------------------
# Lengths matter. A test fixture named ya29.SUPER-SECRET exists on purpose, to prove the
# redactor removes it; a real access token is far longer, so length is what separates the two.
credential_patterns=(
    'ya29\.[A-Za-z0-9._-]{40,}'          # Google access token
    '1//0[A-Za-z0-9._-]{30,}'            # Google refresh token
    '"client_secret"[[:space:]]*:'       # a downloaded web-client secret
    'gho_[A-Za-z0-9]{30,}'               # GitHub token
    '[0-9]{9,}-[a-z0-9]{24,}\.apps\.googleusercontent\.com'  # a real OAuth client ID
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
)
for pattern in "${credential_patterns[@]}"; do
    if hits=$(git grep -nIE "$pattern" -- . 2>/dev/null); then
        fail "credential-shaped content matching /$pattern/:"
        echo "$hits" | sed 's/^/    /'
    fi
done

# --- Files that belong on one Mac and nowhere else --------------------------------------------
forbidden=$(git ls-files |
    grep -E '(^|/)(\.DS_Store|\.env|.*\.token|.*\.tokens)$|(^|/)xcuserdata/|^InboxSweep/Config/|(^|/)(InboxCache|CleanupPlans|MutationHistory|SenderRules|UnsubscribeHistory)[^/]*\.json$' || true)
if [ -n "$forbidden" ]; then
    fail "tracked files that should never be committed:"
    echo "$forbidden" | sed 's/^/    /'
fi

# --- Machine-specific paths --------------------------------------------------------------------
# A home directory naming a person is both a privacy leak and an instruction nobody else can
# follow. The container path the app actually uses is named after the bundle identifier, which
# is why it is allowed to appear.
if paths=$(git grep -nIE "/Users/[A-Za-z0-9._-]+/" -- . ':!Scripts/check_privacy.sh' 2>/dev/null); then
    fail "absolute paths into a developer's home directory:"
    echo "$paths" | sed 's/^/    /'
fi

if [ "$status" -eq 0 ]; then
    echo "Privacy scan clean: synthetic fixtures only."
fi
exit "$status"
