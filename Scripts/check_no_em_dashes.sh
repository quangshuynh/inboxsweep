#!/usr/bin/env bash
# Fails if any tracked text file contains a Unicode em dash (U+2014).
#
# The repository has never had one and the intent is that it never does. This is a house
# punctuation rule rather than a correctness one, which is exactly why it needs a machine to
# enforce it: an em dash is invisible in review and arrives one paste at a time.
#
# The fix is to rewrite the sentence, not to swap in a hyphen.
set -euo pipefail
cd "$(dirname "$0")/.."

# -I skips binary files, so the logo and any other asset are not scanned as text.
if matches=$(git grep -nI $'—' -- . 2>/dev/null); then
    echo "Em dashes (U+2014) found in tracked text:"
    echo "$matches"
    echo
    echo "Rewrite the punctuation naturally rather than substituting a hyphen."
    exit 1
fi

echo "No em dashes in tracked text."
