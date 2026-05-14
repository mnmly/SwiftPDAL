#!/bin/bash
# Build the DocC site for SwiftPDAL into ./docs (GitHub-Pages-ready).
#
# Usage:
#   Scripts/build_docs.sh                 # static export
#   Scripts/build_docs.sh preview         # local preview server (live reload)
#   EMIT_MARKDOWN=1   Scripts/build_docs.sh
#   EMIT_LLMS_TXT=1   Scripts/build_docs.sh   # also produces docs/llms.txt
#
# Env overrides:
#   DOCC_TARGET=SwiftPDAL                 (target whose .docc catalog to build)
#   HOSTING_BASE_PATH=SwiftPDAL           (set to repo name if served at
#                                          https://user.github.io/<repo>/)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DOCC_TARGET="${DOCC_TARGET:-SwiftPDAL}"
HOSTING_BASE_PATH="${HOSTING_BASE_PATH:-SwiftPDAL}"
OUTPUT_DIR="${OUTPUT_DIR:-docs}"
MODE="${1:-build}"

EXTRA_FLAGS=()
if [ "${EMIT_MARKDOWN:-0}" = "1" ] || [ "${EMIT_LLMS_TXT:-0}" = "1" ]; then
    EXTRA_FLAGS+=(--enable-experimental-markdown-output)
fi

if [ "$MODE" = "preview" ]; then
    exec swift package --disable-sandbox preview-documentation \
        --target "$DOCC_TARGET" \
        ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}
fi

echo "==> Building DocC site for $DOCC_TARGET → $OUTPUT_DIR/"
rm -rf "$OUTPUT_DIR"

swift package --allow-writing-to-directory "$OUTPUT_DIR" \
    generate-documentation \
    --target "$DOCC_TARGET" \
    --disable-indexing \
    --transform-for-static-hosting \
    --hosting-base-path "$HOSTING_BASE_PATH" \
    --output-path "$OUTPUT_DIR" \
    ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}

if [ "${EMIT_LLMS_TXT:-0}" = "1" ]; then
    echo "==> Concatenating Markdown into $OUTPUT_DIR/llms.txt"
    LLMS_TXT="$OUTPUT_DIR/llms.txt"
    : > "$LLMS_TXT"
    find "$OUTPUT_DIR/data" -name "*.md" | sort | while read -r md; do
        rel="${md#$OUTPUT_DIR/}"
        {
            echo "---"
            echo "path: $rel"
            echo "---"
            cat "$md"
            echo
        } >> "$LLMS_TXT"
    done
    wc -l "$LLMS_TXT"
fi

echo "==> Done. Open $OUTPUT_DIR/index.html or run 'Scripts/build_docs.sh preview'."
