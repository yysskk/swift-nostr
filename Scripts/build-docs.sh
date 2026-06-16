#!/usr/bin/env bash
#
# Build a single, combined DocC site for every library target in this package.
#
# The pipeline runs in three stages:
#   1. Generate one DocC archive per target.
#   2. Merge the archives into one, synthesizing a landing page that lists every
#      library — this is the combined table of contents.
#   3. Transform the merged archive into a static website ready for hosting.
#
# Usage:
#   Scripts/build-docs.sh [OUTPUT_DIR] [HOSTING_BASE_PATH]
#
#   OUTPUT_DIR         Directory to write the static site to. Default: ./docs
#   HOSTING_BASE_PATH  Base path the site is hosted under, e.g. "swift-nostr"
#                      for https://<owner>.github.io/swift-nostr/. Omit (or
#                      pass "") to build a root-relative site for local preview.
#
# Examples:
#   Scripts/build-docs.sh                            # ./docs, root-relative (local)
#   Scripts/build-docs.sh ./docs swift-nostr         # GitHub Pages layout (CI)

set -euo pipefail

OUTPUT_DIR="${1:-./docs}"
HOSTING_BASE_PATH="${2:-}"

# Library targets whose documentation is combined, in display order.
TARGETS=(NostrCore NostrClient NostrWalletConnect)

# Display name of the synthesized landing page that links to every library.
LANDING_PAGE_NAME="swift-nostr"

# Resolve the DocC executable: `xcrun docc` on macOS, `docc` on Linux toolchains.
if command -v xcrun >/dev/null 2>&1; then
    DOCC=(xcrun docc)
else
    DOCC=(docc)
fi

# Build intermediate archives in a scratch directory, always cleaned up on exit.
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Stage 1: one DocC archive per target.
archives=()
for target in "${TARGETS[@]}"; do
    archive="$BUILD_DIR/$target.doccarchive"
    echo "==> Building documentation archive for $target"
    swift package --allow-writing-to-directory "$BUILD_DIR" \
        generate-documentation \
        --target "$target" \
        --output-path "$archive" \
        --disable-indexing
    archives+=("$archive")
done

# Stage 2: merge the archives into one, synthesizing the landing page.
merged="$BUILD_DIR/combined.doccarchive"
echo "==> Merging ${#archives[@]} archives into a combined archive"
"${DOCC[@]}" merge "${archives[@]}" \
    --synthesized-landing-page-name "$LANDING_PAGE_NAME" \
    --synthesized-landing-page-topics-style detailedGrid \
    --output-path "$merged"

# Stage 3: transform the merged archive into a static website. Start from a clean
# output directory so repeated runs are deterministic (the `:?` guard refuses to
# expand an empty OUTPUT_DIR into a destructive `rm`).
echo "==> Transforming combined archive for static hosting -> $OUTPUT_DIR"
rm -rf "${OUTPUT_DIR:?}"
transform_args=("$merged" --output-path "$OUTPUT_DIR")
if [ -n "$HOSTING_BASE_PATH" ]; then
    transform_args+=(--hosting-base-path "$HOSTING_BASE_PATH")
fi
"${DOCC[@]}" process-archive transform-for-static-hosting "${transform_args[@]}"

echo "==> Combined documentation written to $OUTPUT_DIR"
