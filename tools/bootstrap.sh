#!/usr/bin/env bash
# Bootstrap or verify the local toolchain for the Sunday Keys clean room work.
#
# Installs only what is missing and never overwrites an existing tool. Safe to
# re-run. Two parts are manual by design, because they need interaction that a
# script cannot provide: installing the full Xcode application, and approving
# the command line tools prompt or a Homebrew sudo step.
#
# Usage:
#   tools/bootstrap.sh            verify, then install what is missing
#   tools/bootstrap.sh --check    verify only, exit non-zero if anything is absent
#
# This script has not been executed yet. Treat it as unverified until it runs
# once on the build machine; it is deliberately written to fail closed.

set -euo pipefail

CHECK_ONLY=0
if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=1
fi

missing=0
note() { printf '  %-18s %s\n' "$1" "$2"; }
report_missing() {
  printf 'MISSING  %-16s %s\n' "$1" "$2"
  missing=$((missing + 1))
}

has() { command -v "$1" >/dev/null 2>&1; }

printf 'Sunday Keys clean room toolchain\n\n'

# 1. Command line tools
if xcode-select -p >/dev/null 2>&1; then
  note "command line tools" "$(xcode-select -p)"
else
  report_missing "command line tools" "run: xcode-select --install"
fi

# 2. Full Xcode, needed to build and test the app
if [[ -d /Applications/Xcode.app ]]; then
  note "xcode" "$(/usr/bin/xcodebuild -version 2>/dev/null | head -1)"
else
  report_missing "xcode" "install Xcode from the App Store"
fi

# 3. Swift toolchain
if has swift; then
  note "swift" "$(swift --version 2>/dev/null | head -1)"
else
  report_missing "swift" "install Xcode, which provides swift and swiftc"
fi

# 4. Homebrew
if has brew; then
  note "homebrew" "$(brew --version | head -1)"
else
  report_missing "homebrew" "run the installer from brew.sh"
fi

# 5. Java, needed for headless Ghidra
if has java; then
  note "java" "$(java -version 2>&1 | head -1)"
else
  report_missing "java" "brew install --cask temurin"
fi

# 6. Ghidra
if [[ -n "${GHIDRA_INSTALL_DIR:-}" && -d "${GHIDRA_INSTALL_DIR}/support" ]]; then
  note "ghidra" "$GHIDRA_INSTALL_DIR"
else
  report_missing "ghidra" "brew install --cask ghidra, then export GHIDRA_INSTALL_DIR"
fi

# 7. Python, used by every script in tools/
if has python3; then
  note "python3" "$(python3 --version 2>&1)"
else
  report_missing "python3" "brew install python"
fi

printf '\n'

if [[ $missing -gt 0 && $CHECK_ONLY -eq 1 ]]; then
  printf '%d item(s) missing\n' "$missing"
  exit 1
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
  printf 'all present\n'
  exit 0
fi

# Install what Homebrew can install. Anything else is reported for manual action.
if has brew; then
  if ! has java; then
    printf 'installing temurin...\n'
    brew install --cask temurin
  fi
  if ! [[ -n "${GHIDRA_INSTALL_DIR:-}" && -d "${GHIDRA_INSTALL_DIR}/support" ]]; then
    printf 'installing ghidra...\n'
    brew install --cask ghidra
    printf 'note: export GHIDRA_INSTALL_DIR to the installed Ghidra directory\n'
  fi
  if ! has python3; then
    printf 'installing python...\n'
    brew install python
  fi
else
  printf 'homebrew is absent, so nothing was installed\n'
fi

printf '\nXcode and the command line tools must be installed manually if reported missing.\n'
printf 'Re-run with --check to confirm.\n'
