#!/usr/bin/env bash
# The gitlink has to name a commit on the bootstrap repo's main.
#
# A bootstrap pull request merges as a merge commit, so the branch tip the
# gitlink was built from becomes an ancestor of main rather than main itself.
# The tree is identical either way, which is why this goes unnoticed: a full
# clone still resolves the old commit and everything builds. A shallow or
# recursive submodule fetch brings down only the branch tip, finds no such
# object, and checks out nothing.
#
# Needs the network and read access to the private bootstrap repository, so it
# is not part of `make test`. It has its own target, `make test-gitlink`, which
# is what CI runs in the stage-0 preflight, where the checkout already has
# both.
set -euo pipefail
cd "$(dirname "$0")/.."

url=$(git config --file .gitmodules submodule.compiler/bootstrap.url)
recorded=$(git ls-tree HEAD compiler/bootstrap | awk '{print $3}')
if [[ -z "$recorded" ]]; then
    echo "no compiler/bootstrap gitlink in HEAD" >&2
    exit 1
fi

remote=$(git ls-remote "$url" refs/heads/main | cut -f1)
if [[ -z "$remote" ]]; then
    echo "cannot read main from $url" >&2
    exit 1
fi

if [[ "$recorded" == "$remote" ]]; then
    echo "ok bootstrap gitlink is bootstrap main ($recorded)"
    exit 0
fi

# Which of the two ways it can be wrong decides how loud to be, so say which.
# Ancestor: the bootstrap side has landed and only the link is behind. Not an
# ancestor: the commit is not on main at all, which is the normal and correct
# state of a branch whose bootstrap pull request is still open.
merged=1
if [[ -d compiler/bootstrap/.git || -f compiler/bootstrap/.git ]]; then
    git -C compiler/bootstrap fetch -q "$url" main 2>/dev/null || true
    git -C compiler/bootstrap merge-base --is-ancestor \
        "$recorded" FETCH_HEAD 2>/dev/null || merged=0
fi

branch=${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}
if [[ "$branch" == "main" ]]; then
    echo "bootstrap gitlink is stale on main" >&2
    echo "  recorded:      $recorded" >&2
    echo "  bootstrap main: $remote" >&2
    if [[ "$merged" == "1" ]]; then
        echo "  the recorded commit is an ancestor of main, so the bootstrap" >&2
        echo "  side has landed and only the link is behind. Bump it:" >&2
    else
        echo "  the recorded commit is not on bootstrap main at all. Merge the" >&2
        echo "  bootstrap side first, then bump the link:" >&2
    fi
    echo "    git -C compiler/bootstrap fetch origin main" >&2
    echo "    git -C compiler/bootstrap checkout --detach $remote" >&2
    echo "    git add compiler/bootstrap && git commit" >&2
    exit 1
fi

# On a branch this is expected while the paired bootstrap pull request is open,
# so it reports rather than fails — main is where the invariant is enforced.
if [[ "$merged" == "1" ]]; then
    echo "note: bootstrap gitlink names $recorded, an ancestor of bootstrap"
    echo "      main ($remote). Bump it before this branch merges, or main"
    echo "      will carry a gitlink no shallow clone can resolve."
else
    echo "note: bootstrap gitlink names $recorded, which is not on bootstrap"
    echo "      main yet. Merge the bootstrap side first, then bump the link"
    echo "      to whatever main becomes."
fi
