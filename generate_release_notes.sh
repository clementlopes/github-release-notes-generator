#!/bin/sh

# ------------------------------------------------------------
# GitHub Release Notes Generator
# ------------------------------------------------------------
# Purpose:
#   This script generates human-readable release notes for a Git tag.
#   It lists commits since the previous tag, tries to map authors to GitHub usernames,
#   links to pull requests (if referenced), and highlights new contributors.
#
# Usage:
#   ./generate_release_notes.sh <owner/repo>
#   Example: ./generate_release_notes.sh myorg/myapp
#
# Requirements:
#   - Git
#   - jq (for JSON parsing from GitHub API)
#   - curl (to call GitHub API)
#   - GITHUB_TOKEN (as environment variable, optional but recommended for reliable username lookup)
# ------------------------------------------------------------

# Check if exactly one argument is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <owner/repo>" >&2
    exit 1
fi

# Store the repository path (e.g., "myorg/myapp")
REPOSITORY_PATH=$1
GITHUB_URL="https://github.com/${REPOSITORY_PATH}"  # Base URL for the repo (note: removed extra space)

# ------------------------------------------------------------
# Step 1: Determine the current tag (the one that triggered the release)
# ------------------------------------------------------------
# Try to get the latest tag that points to or is before HEAD
CURRENT_TAG=$(git describe --tags --abbrev=0 HEAD 2>/dev/null || git tag --sort=-v:refname | head -n1)
if [ -z "$CURRENT_TAG" ]; then
    echo "Error: No tags found in repository" >&2
    exit 1
fi

# Get the short commit SHA of HEAD (the commit being released)
COMMIT_SHA=$(git rev-parse --short HEAD)

# ------------------------------------------------------------
# Step 2: Find the previous tag (to define the commit range)
# ------------------------------------------------------------
# List all tags, sorted by semantic version (newest first)
ALL_TAGS=$(git tag --sort=-v:refname)
TEMP_TAGS=$(mktemp)  # Create a temporary file to store tags
echo "$ALL_TAGS" > "$TEMP_TAGS"

# Get the full commit hash of the current tag (or HEAD if tag doesn't exist)
CURRENT_COMMIT=$(git rev-parse "$CURRENT_TAG" 2>/dev/null || git rev-parse HEAD)

PREVIOUS_TAG=""
FOUND_CURRENT=0

# Loop through tags to find the one immediately before the current tag
while IFS= read -r tag; do
    if [ "$tag" = "$CURRENT_TAG" ]; then
        # Mark that we've seen the current tag; the next valid tag is the previous one
        FOUND_CURRENT=1
        continue
    elif [ "$FOUND_CURRENT" -eq 1 ]; then
        # Found a candidate for previous tag
        TAG_COMMIT=$(git rev-parse "$tag" 2>/dev/null)
        # Only accept it if it's a different commit (avoid duplicate tags)
        if [ "$TAG_COMMIT" != "$CURRENT_COMMIT" ]; then
            PREVIOUS_TAG="$tag"
            break
        fi
    fi
done < "$TEMP_TAGS"

# Clean up temporary file
rm -f "$TEMP_TAGS"

# Fallback: if no previous tag, use the initial commit
if [ -z "$PREVIOUS_TAG" ]; then
    PREVIOUS_TAG=$(git rev-list --max-parents=0 HEAD)
fi

# ------------------------------------------------------------
# Step 3: Define the commit range for the changelog
# ------------------------------------------------------------
# If HEAD is exactly a tag, compare previous_tag..current_tag
# Otherwise, include everything from tag to current HEAD
if git describe --tags --exact-match HEAD >/dev/null 2>&1; then
    COMMIT_RANGE="$PREVIOUS_TAG..$CURRENT_TAG"
else
    COMMIT_RANGE="$CURRENT_TAG..HEAD"
fi

# Safety: avoid empty ranges
if [ "$PREVIOUS_TAG" = "$CURRENT_TAG" ] || [ "$COMMIT_RANGE" = "$CURRENT_TAG..$CURRENT_TAG" ]; then
    COMMIT_RANGE="$CURRENT_TAG^..$CURRENT_TAG"
fi

# ------------------------------------------------------------
# Step 4: Extract commits and authors in the range
# ------------------------------------------------------------
TEMP_COMMITS=$(mktemp)   # File to store commit SHAs
TEMP_AUTHORS=$(mktemp)   # File to store unique authors (name|email)

# Write list of commit SHAs in range
git log --pretty=format:"%H" "$COMMIT_RANGE" > "$TEMP_COMMITS"

# Write unique authors (name and email) in range
git log --format='%an|%ae' "$COMMIT_RANGE" | sort -u > "$TEMP_AUTHORS"

# Count total commits and unique contributors
COMMITS_COUNT=$(wc -l < "$TEMP_COMMITS")
CONTRIBUTORS_COUNT=$(wc -l < "$TEMP_AUTHORS")

# ------------------------------------------------------------
# Step 5: Generate Markdown header with release metadata
# ------------------------------------------------------------
echo "# Release ${CURRENT_TAG}"
echo ""
echo "Repository: [${REPOSITORY_PATH}](${GITHUB_URL}) · Tag: [${CURRENT_TAG}](${GITHUB_URL}/releases/tag/${CURRENT_TAG}) · Commit: [${COMMIT_SHA}](${GITHUB_URL}/commit/${COMMIT_SHA})"
echo ""
echo "In this release: **${COMMITS_COUNT}** commits by **${CONTRIBUTORS_COUNT}** contributors"
echo ""
echo "## What's Changed"
echo ""

# ------------------------------------------------------------
# Step 6: List each commit with smart attribution
# ------------------------------------------------------------
if [ -s "$TEMP_COMMITS" ]; then
    while IFS= read -r COMMIT_HASH || [ -n "$COMMIT_HASH" ]; do
        [ -z "$COMMIT_HASH" ] && continue

        # Extract commit metadata
        SUBJECT=$(git show -s --format=%s "$COMMIT_HASH")
        BODY=$(git show -s --format=%b "$COMMIT_HASH")
        AUTHOR_NAME=$(git show -s --format=%an "$COMMIT_HASH")
        AUTHOR_EMAIL=$(git show -s --format=%ae "$COMMIT_HASH")
        SHORT_COMMIT_HASH=$(echo "$COMMIT_HASH" | cut -c1-7)

        # --------------------------------------------------------
        # Try to resolve GitHub username from email or name (using GitHub API)
        # --------------------------------------------------------
        AUTHOR_USERNAME=""

        # Attempt 1: Search by email (requires GITHUB_TOKEN for higher rate limits & accuracy)
        if [ -n "$GITHUB_TOKEN" ]; then
            AUTHOR_USERNAME=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
                "https://api.github.com/search/users?q=${AUTHOR_EMAIL}+in:email" \
                | jq -r '.items[0].login // empty' 2>/dev/null)
        fi

        # Attempt 2: If email fails, try searching by name (cleaned for URL safety)
        if [ -z "$AUTHOR_USERNAME" ] || [ "$AUTHOR_USERNAME" = "null" ]; then
            if [ -n "$GITHUB_TOKEN" ]; then
                # Clean name: replace spaces with +, remove non-alphanumeric chars
                SEARCH_NAME=$(echo "$AUTHOR_NAME" | tr ' ' '+' | sed 's/[^a-zA-Z0-9+]//g')
                AUTHOR_USERNAME=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
                    "https://api.github.com/search/users?q=${SEARCH_NAME}+in:name" \
                    | jq -r '.items[0].login // empty' 2>/dev/null)
            fi
        fi

        # Attempt 3: Fallback to a sanitized version of the author name (not a real GitHub handle)
        if [ -z "$AUTHOR_USERNAME" ] || [ "$AUTHOR_USERNAME" = "null" ]; then
            AUTHOR_USERNAME=$(echo "$AUTHOR_NAME" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
        fi

        # --------------------------------------------------------
        # Detect if commit references a Pull Request (e.g., #123)
        # --------------------------------------------------------
        PR_NUMBER=$(echo "$SUBJECT $BODY" | grep -o '#[0-9]*' | head -n 1 | sed 's/#//')
        if [ -z "$PR_NUMBER" ]; then
            PR_TEXT=""
        else
            PR_TEXT=" in [#${PR_NUMBER}](${GITHUB_URL}/pull/${PR_NUMBER})"
        fi

        # Output formatted commit line with:
        # - commit link
        # - commit message
        # - author (linked to GitHub profile)
        # - optional PR link
        echo "- [${SHORT_COMMIT_HASH}](${GITHUB_URL}/commit/${COMMIT_HASH}) ${SUBJECT} by [@${AUTHOR_USERNAME}](https://github.com/${AUTHOR_USERNAME})${PR_TEXT}"
    done < "$TEMP_COMMITS"
else
    echo "- No changes found between ${PREVIOUS_TAG} and ${CURRENT_TAG}"
fi

# ------------------------------------------------------------
# Step 7: List new contributors (everyone in this release range)
# ------------------------------------------------------------
echo ""
echo "## New Contributors"
echo ""

if [ -s "$TEMP_AUTHORS" ]; then
    while IFS='|' read -r AUTHOR EMAIL || [ -n "$AUTHOR" ]; do
        [ -z "$AUTHOR" ] && continue

        # Same logic as above: try to resolve GitHub username
        USERNAME=""

        if [ -n "$GITHUB_TOKEN" ]; then
            USERNAME=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
                "https://api.github.com/search/users?q=${EMAIL}+in:email" \
                | jq -r '.items[0].login // empty' 2>/dev/null)
        fi

        if [ -z "$USERNAME" ] || [ "$USERNAME" = "null" ]; then
            if [ -n "$GITHUB_TOKEN" ]; then
                SEARCH_NAME=$(echo "$AUTHOR" | tr ' ' '+' | sed 's/[^a-zA-Z0-9+]//g')
                USERNAME=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
                    "https://api.github.com/search/users?q=${SEARCH_NAME}+in:name" \
                    | jq -r '.items[0].login // empty' 2>/dev/null)
            fi
        fi

        if [ -z "$USERNAME" ] || [ "$USERNAME" = "null" ]; then
            USERNAME=$(echo "$AUTHOR" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
        fi

        echo "- [@${USERNAME}](https://github.com/${USERNAME}) made their first contribution 🎉"
    done < "$TEMP_AUTHORS"
fi

# ------------------------------------------------------------
# Step 8: Add full changelog comparison link and cleanup
# ------------------------------------------------------------
echo ""
echo "Full Changelog: [${PREVIOUS_TAG} → ${CURRENT_TAG}](${GITHUB_URL}/compare/${PREVIOUS_TAG}...${CURRENT_TAG})"

# Remove temporary files
rm -f "$TEMP_COMMITS" "$TEMP_AUTHORS"