#!/usr/bin/env bash
set -e

# --- config ---
REPO_URL="XXXX"
NAME="hol-lambdas"
BRANCH="master"
# --------------

# make results folder if missing
[ -d results ] || mkdir results

echo "Cloning..."
git clone "$REPO_URL"

# figure out the folder name git just created from the URL
SRC_DIR="$(basename "$REPO_URL" .git)"

# rename to the target name
mv "$SRC_DIR" "$NAME"

# switch to the branch (create if it doesn't exist locally)
cd "$NAME"
git fetch
git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH"
cd ..

echo "Done. Cloned into: $NAME"
