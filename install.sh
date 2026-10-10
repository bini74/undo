#!/bin/bash
# Compile et installe undo dans ~/.local/bin.
set -euo pipefail
cd "$(dirname "$0")"

echo "→ compilation (swiftc -O)…"
TMP="$(mktemp -d)"
swiftc -O -parse-as-library -o "$TMP/undo" undo.swift

mkdir -p "$HOME/.local/bin"
mv -f "$TMP/undo" "$HOME/.local/bin/undo"
rmdir "$TMP"

echo "✓ installé : $HOME/.local/bin/undo"
"$HOME/.local/bin/undo" version

RESOLVED="$(zsh -ic 'whence -p undo' 2>/dev/null || true)"
if [ "$RESOLVED" != "$HOME/.local/bin/undo" ]; then
  echo "⚠ attention : « undo » résout vers ${RESOLVED:-introuvable} — vérifie l'ordre du PATH dans ~/.zshrc"
fi
