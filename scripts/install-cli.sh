#!/usr/bin/env bash
# install-cli.sh — symlink the release binary into ~/.local/bin
# (or $PREFIX/bin if PREFIX is set). For headless / non-bundle use.

set -euo pipefail

cd "$(dirname "$0")/.."

PREFIX="${PREFIX:-$HOME/.local}"
bin="$PREFIX/bin"
mkdir -p "$bin"

if [[ ! -x .build/release/chord ]]; then
  echo "→ swift build -c release"
  swift build -c release
fi

ln -sf "$(pwd)/.build/release/chord" "$bin/chord"
echo "installed: $bin/chord -> $(readlink "$bin/chord")"

case ":$PATH:" in
  *":$bin:"*) ;;
  *) echo "warning: $bin is not in your PATH" ;;
esac
