#!/usr/bin/env bash
set -euo pipefail

case "$(uname -s)" in
  Darwin)
    if ! command -v brew >/dev/null 2>&1; then
      echo "⚠ Homebrew not found. Skipping desktop notification installation."
      exit 0
    fi
    if ! command -v alerter >/dev/null 2>&1; then
      echo "Installing alerter..."
      brew install vjeantet/tap/alerter
      echo "✓ alerter installed"
    else
      echo "✓ alerter already installed"
    fi
    if ! command -v terminal-notifier >/dev/null 2>&1; then
      echo "Installing terminal-notifier..."
      brew install terminal-notifier
      echo "✓ terminal-notifier installed"
    else
      echo "✓ terminal-notifier already installed"
    fi
    ;;
  Linux)
    if command -v notify-send >/dev/null 2>&1; then
      echo "✓ notify-send already installed"
    elif command -v apt-get >/dev/null 2>&1; then
      echo "Installing libnotify-bin (provides notify-send)..."
      sudo apt-get install -y libnotify-bin
    elif command -v dnf >/dev/null 2>&1; then
      echo "Installing libnotify (provides notify-send)..."
      sudo dnf install -y libnotify
    else
      echo "⚠ notify-send not found — install libnotify / libnotify-bin via your package manager."
    fi
    ;;
esac
