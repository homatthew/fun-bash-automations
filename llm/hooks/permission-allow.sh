#!/bin/bash
set -euo pipefail

INPUT=$(cat)

emit_pass() {
  printf '{}\n'
  exit 0
}

emit_allow() {
  printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\n'
  exit 0
}

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
[ "$TOOL_NAME" != "Bash" ] && emit_pass

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
[ -z "$CMD" ] && emit_pass

case "$CMD" in
  *'&&'*|*'||'*|*';'*|*'|'*|*'>'*|*'<'*|*'`'*|*'$('*|*$'\n'*) emit_pass ;;
esac

if python3 - "$CMD" <<'PY'
import os
import re
import shlex
import sys

try:
    tokens = shlex.split(sys.argv[1], posix=True)
except ValueError:
    sys.exit(1)

assignment = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$")
environment = []
while tokens and assignment.match(tokens[0]):
    environment.append(tokens.pop(0).split("=", 1)[0])
if not tokens:
    sys.exit(1)

if "/" in tokens[0] or environment:
    sys.exit(1)

command = tokens[0]
args = tokens[1:]

singletons = {
    "ls", "pwd", "echo", "cat", "head", "tail", "wc", "tree", "du",
    "df", "which", "type", "file", "stat", "basename", "dirname",
    "realpath", "uname", "whoami", "id", "sw_vers", "pgrep", "ps", "lsof",
}
if command in singletons:
    sys.exit(0)
if command == "printf":
    sys.exit(1 if "-v" in args else 0)

if command in {"grep", "ag", "ack"}:
    sys.exit(0)
if command == "rg":
    blocked = {"--pre", "--hostname-bin"}
    if any(arg in blocked or any(arg.startswith(flag + "=") for flag in blocked) for arg in args):
        sys.exit(1)
    sys.exit(0)
if command == "fd":
    blocked = {"-x", "-X", "--exec", "--exec-batch", "--batch-exec"}
    if any(arg.startswith(("-x", "-X")) or arg in blocked or any(arg.startswith(flag + "=") for flag in blocked if flag.startswith("--")) for arg in args):
        sys.exit(1)
    sys.exit(0)
if command == "find":
    blocked = {
        "-delete", "-exec", "-execdir", "-ok", "-okdir", "-fls",
        "-fprintf", "-fprint", "-fprint0",
    }
    sys.exit(1 if any(arg in blocked for arg in args) else 0)

if command == "jq":
    sys.exit(0)
if command == "yq":
    for arg in args:
        if arg == "--":
            break
        if arg == "--in-place" or arg.startswith("--in-place="):
            sys.exit(1)
        if arg.startswith("-") and not arg.startswith("--") and "i" in arg[1:]:
            sys.exit(1)
    sys.exit(0)

def sed_script_is_safe(script):
    if re.search(r"(?:^|[;\n])\s*(?:(?:[0-9,$]+|/(?:[^/\\]|\\.)*/)\s*)?[eEwW](?:\s|$)", script):
        return False
    index = 0
    while index + 1 < len(script):
        if script[index] != "s" or script[index + 1].isalnum() or script[index + 1].isspace():
            index += 1
            continue
        sep = script[index + 1]
        pos = index + 2
        delimiters = 0
        escaped = False
        while pos < len(script) and delimiters < 2:
            char = script[pos]
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == sep:
                delimiters += 1
            pos += 1
        if delimiters == 2:
            flags = []
            while pos < len(script) and script[pos] not in ";\n":
                flags.append(script[pos])
                pos += 1
            if "e" in flags or "w" in flags or "W" in flags:
                return False
        index += 1
    return True

if command == "sed":
    scripts = []
    index = 0
    explicit = False
    while index < len(args):
        arg = args[index]
        if arg == "--":
            index += 1
            break
        if arg in {"-i", "--in-place"} or arg.startswith(("-i", "--in-place=")):
            sys.exit(1)
        if arg in {"-f", "--file"} or arg.startswith("--file="):
            sys.exit(1)
        if arg in {"-e", "--expression"}:
            if index + 1 >= len(args):
                sys.exit(1)
            scripts.append(args[index + 1])
            explicit = True
            index += 2
            continue
        if arg.startswith("--expression="):
            scripts.append(arg.split("=", 1)[1])
            explicit = True
            index += 1
            continue
        if arg.startswith("-e") and len(arg) > 2:
            scripts.append(arg[2:])
            explicit = True
            index += 1
            continue
        if arg.startswith("-"):
            short = arg[1:]
            if "i" in short or "f" in short:
                sys.exit(1)
            if "e" in short:
                if index + 1 >= len(args):
                    sys.exit(1)
                scripts.append(args[index + 1])
                explicit = True
                index += 2
                continue
            index += 1
            continue
        if not explicit and not scripts:
            scripts.append(arg)
        index += 1
    sys.exit(0 if scripts and all(sed_script_is_safe(script) for script in scripts) else 1)

if command == "date":
    index = 0
    while index < len(args):
        arg = args[index]
        if arg.startswith("+") or arg in {"-u", "--utc", "--universal", "-j", "--help", "--version"}:
            index += 1
            continue
        if arg in {"-d", "--date", "-r", "--reference", "-f", "--file", "-v"}:
            if index + 1 >= len(args):
                sys.exit(1)
            index += 2
            continue
        if arg.startswith(("--date=", "--reference=", "--file=", "-v")):
            index += 1
            continue
        sys.exit(1)
    sys.exit(0)

if command == "hostname":
    read_flags = {"-f", "--fqdn", "--long", "-s", "--short", "-d", "--domain", "-i", "--ip-address", "-I", "--all-ip-addresses", "-A", "--all-fqdns", "-y", "--yp", "--nis", "--help", "--version"}
    sys.exit(0 if not args or all(arg in read_flags for arg in args) else 1)

if command == "defaults":
    sys.exit(0 if args and args[0] in {"read", "read-type", "domains", "find"} else 1)

if command != "git" or not args:
    sys.exit(1)

subcommand = args[0]
subargs = args[1:]
if subcommand == "status":
    safe_status = {
        "-s", "--short", "-b", "--branch", "--show-stash", "--ahead-behind",
        "--no-ahead-behind", "--porcelain", "--long", "--untracked-files",
        "--ignored", "--ignore-submodules", "--column", "--no-column",
        "--no-renames", "--find-renames", "-z", "--null", "--",
    }
    safe_prefixes = (
        "--porcelain=", "--untracked-files=", "--ignored=", "--ignore-submodules=",
        "--column=", "--find-renames=",
    )
    sys.exit(0 if all(not arg.startswith("-") or arg in safe_status or arg.startswith(safe_prefixes) for arg in subargs) else 1)
if subcommand == "rev-parse":
    unsafe_rev_parse = {"--parseopt", "--sq-quote"}
    sys.exit(1 if any(arg in unsafe_rev_parse for arg in subargs) else 0)
if subcommand in {"merge-base", "show-ref", "name-rev", "check-ref-format"}:
    sys.exit(0 if all(arg != "--output" and not arg.startswith("--output=") for arg in subargs) else 1)
if subcommand == "branch":
    mutating = {"-d", "-D", "-m", "-M", "-c", "-C", "-f", "--force", "-t", "--track", "--no-track", "--recurse-submodules", "--create-reflog", "--delete", "--move", "--copy", "--edit-description", "--set-upstream-to", "--unset-upstream", "-u"}
    if any(arg in mutating or arg.startswith("--set-upstream-to=") for arg in subargs):
        sys.exit(1)
    listing = {"-a", "--all", "-r", "--remotes", "-v", "-vv", "--show-current", "--list", "-l", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at"}
    has_listing_mode = any(arg in listing or arg.startswith(("--list=", "--contains=", "--no-contains=", "--merged=", "--no-merged=", "--points-at=")) for arg in subargs)
    has_positional = any(not arg.startswith("-") for arg in subargs)
    sys.exit(0 if not subargs or has_listing_mode or not has_positional else 1)
if subcommand == "tag":
    if not subargs:
        sys.exit(0)
    listing = any(arg in {"-l", "--list", "-n"} or arg.startswith("-n") for arg in subargs)
    mutating = {"-d", "--delete", "-a", "--annotate", "-s", "--sign", "-f", "--force"}
    sys.exit(0 if listing and not any(arg in mutating for arg in subargs) else 1)
if subcommand == "remote":
    if not subargs or subargs == ["-v"]:
        sys.exit(0)
    sys.exit(0 if subargs[0] in {"show", "get-url"} else 1)
if subcommand == "stash":
    sys.exit(0 if subargs and subargs[0] in {"list", "show"} else 1)
if subcommand == "config":
    while subargs and subargs[0] in {"--local", "--global", "--system", "--worktree"}:
        subargs.pop(0)
    reads = {"--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l"}
    sys.exit(0 if subargs and subargs[0] in reads else 1)
if subcommand == "symbolic-ref":
    allowed = {"-q", "--quiet", "--short", "--no-recurse"}
    positional = [arg for arg in subargs if arg not in allowed]
    sys.exit(0 if len(positional) == 1 and not positional[0].startswith("-") else 1)
if subcommand == "reflog":
    if not subargs or subargs[0] == "show":
        sys.exit(0)
    sys.exit(0 if subargs[0] == "exists" and len(subargs) == 2 else 1)
sys.exit(1)
PY
then
  emit_allow
fi

emit_pass
