---
name: dgw-cli-kv
description: Use when exploring, reading, or debugging Data Gateway (DGW) KV shards and namespaces using the dgw-cli tool. Covers describe, scan, get, and decoding binary/protobuf values.
---

# dgw-cli KV Reference

## Command Structure

```
dgw-cli kv -e <env> -s <shard> [--output-format FORMAT] COMMAND [OPTIONS]
```

- `-e` / `--env` — **required** (`test` or `prod`)
- `-s` / `--shard` — **always specify** — omitting it tries to list all shards and crashes with gRPC `message too large`
- `--output-format` — top-level flag, goes **before** the subcommand (`table` | `json` | `py` | `fs`)

## Data Model

```
Shard → Namespace → Record (by Record ID) → Items (key → value)
```

- **Shard**: the DGW shard name (e.g., `entityloggingcontextservice`, `pageservice`)
- **Namespace**: logical grouping within the shard (e.g., `entity-logging-context-service`)
- **Record**: identified by a Record ID (UUID, page session ID like `PS_..._R1W1`, etc.)
- **Item**: a key/value pair within a record, with TTL and metadata

## Commands

### describe — inspect namespace stats

```bash
dgw-cli kv -e prod -s <shard> describe
```

Shows: record count, storage/compute utilization, compression, chunking, access SLO.

### scan — browse records across a namespace

```bash
# Sample records (metadata only, no values — safe for large namespaces)
dgw-cli kv -e prod -s <shard> scan <namespace> \
  --page-size-items 0 \
  --deadline-seconds 5

# With JSON output — redirect to file to avoid mixing with stderr progress
dgw-cli kv -e prod -s <shard> --output-format json scan <namespace> \
  --page-size-items 0 --deadline-seconds 5 > /tmp/scan.json 2>/dev/null
```

Key options:
- `--page-size-items 0` — disable pagination, collect everything
- `--deadline-seconds N` — stop after N seconds (default 10; pass 0 to disable)
- `--item-format str:str:hex` — decode IDs and keys as strings, values as hex (default)
- `--exclude VALUE` — skip value bytes (faster, good for key discovery)

**Gotcha**: Scan crashes with `RESOURCE_EXHAUSTED` on records with very large chunked values. Save to file rather than piping to avoid partial JSON.

### get — fetch values for specific keys

```bash
# Fetch all keys in a record (lists keys, no values by default with --exclude VALUE)
dgw-cli kv -e prod -s <shard> get <namespace> <record_id> --exclude VALUE

# Fetch a specific key as string
dgw-cli kv -e prod -s <shard> get <namespace> <record_id> <key> --item-format str:str:str

# Save raw binary value to file (only works with a single key)
dgw-cli kv -e prod -s <shard> get <namespace> <record_id> <key> --output-file /tmp/value.bin

# Save multiple keys to a directory
dgw-cli kv -e prod -s <shard> get <namespace> <record_id> key1 key2 --output-path /tmp/keys/
```

## Quick Reference

| Task | Command pattern |
|------|----------------|
| List namespace stats | `describe` |
| Sample records (no values) | `scan <ns> --exclude VALUE --deadline-seconds 5` |
| Count distinct keys | scan + `python3 -c "from collections import Counter; ..."` |
| List items in a record | `get <ns> <id> --exclude VALUE` |
| Read a key as string | `get <ns> <id> <key> --item-format str:str:str` |
| Save binary value | `get <ns> <id> <key> --output-file /tmp/val.bin` |

## Decoding Binary (Protobuf) Values

Values are often protobuf-encoded. `--item-format str:str:str` will warn `failed decode: 'utf-8'...` and fall back to hex. To decode:

```bash
# Save raw bytes, then parse with Python
dgw-cli kv -e prod -s <shard> get <ns> <record_id> <key> --output-file /tmp/val.bin
```

```python
# Minimal protobuf wire-format parser (no dependencies)
def parse_varint(data, pos):
    result, shift = 0, 0
    while True:
        b = data[pos]; pos += 1
        result |= (b & 0x7f) << shift
        if not (b & 0x80): break
        shift += 7
    return result, pos

def parse_proto(data, indent=0):
    pos = 0
    while pos < len(data):
        try: tag, pos = parse_varint(data, pos)
        except: break
        fn, wt = tag >> 3, tag & 7
        p = '  ' * indent
        if wt == 0:
            v, pos = parse_varint(data, pos)
            print(f'{p}[{fn}] int: {v}')
        elif wt == 2:
            l, pos = parse_varint(data, pos)
            raw = data[pos:pos+l]; pos += l
            try:
                s = raw.decode('utf-8')
                print(f'{p}[{fn}] str: {repr(s[:200])}')
            except:
                print(f'{p}[{fn}] bytes({l}):')
                parse_proto(raw, indent+1)
        elif wt == 5:
            v = int.from_bytes(data[pos:pos+4],'little'); pos += 4
            print(f'{p}[{fn}] fix32: {v}')
        elif wt == 1:
            v = int.from_bytes(data[pos:pos+8],'little'); pos += 8
            print(f'{p}[{fn}] fix64: {v}')
        else:
            print(f'{p}[{fn}] unknown wt={wt}'); break

with open('/tmp/val.bin', 'rb') as f:
    parse_proto(f.read())
```

## Common Patterns

**`_health` key** — every namespace has 1-2 records with key `_health` and empty value. These are DGW health probes. Filter them out when analyzing data.

**JSON output piping** — progress messages go to stderr, JSON to stdout, but errors also go to stderr. Always redirect:
```bash
# Safe pattern
dgw-cli kv -e prod -s <shard> --output-format json scan <ns> > out.json 2>/dev/null
python3 -c "import json,sys; data=json.load(open('out.json')); print(len(data))"
```

**Short TTL vs long TTL** — TTL length signals purpose:
- ~10 hours: live serving cache (e.g., page construction state)
- 7 days: audit/tracing index (e.g., request-to-session lookup)

## Write Safety

**The CLI has no built-in write protection.** `put` and `delete` execute immediately — no confirmation prompt, no `--dry-run`, no `--read-only` mode. Safety at the infrastructure layer is via Metatron (authn) and Gandalf (authz).

### Hook enforcement

A `PreToolUse` hook blocks `dgw-cli kv put` and `dgw-cli kv delete` by default
for every environment, including `-e test`.

**All writes are blocked by default**, regardless of environment. Use the
environment-specific flag on the same command segment as the write:

| Environment | Required prefix |
|-------------|----------------|
| `-e prod` | `DGW_PROD_WRITE_AUTHORIZED=1` |
| `-e test` | `DGW_TEST_WRITE_AUTHORIZED=1` |

```bash
# Both blocked without flag
dgw-cli kv -e prod -s shard put ns id key --data /tmp/val.bin
dgw-cli kv -e test -s shard put ns id key --data /tmp/val.bin

# Allowed with matching flag
DGW_PROD_WRITE_AUTHORIZED=1 dgw-cli kv -e prod -s shard put ns id key --data /tmp/val.bin
DGW_TEST_WRITE_AUTHORIZED=1 dgw-cli kv -e test -s shard delete ns id key

# Using the wrong env's flag is still blocked
DGW_TEST_WRITE_AUTHORIZED=1 dgw-cli kv -e prod -s shard put ...   # denied
```

**As Claude**: never add an authorization flag unless the user has explicitly confirmed write intent in their message. If the hook blocks a command, stop and explain — do not retry with the flag automatically.

## Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Failed to connect` | Not on VPN / no access | Check VPN, verify app permissions |
| `Received message larger than max` | Omitted `-s`, tries to list all shards | Always specify `-s <shard>` |
| `RESOURCE_EXHAUSTED` during scan | Record values too large for gRPC | Scan with `--exclude VALUE`; fetch large records individually |
| `--output-file is only valid with a single key` | Multiple keys + `--output-file` | Use `--output-path /dir/` for multiple keys |
| JSON parse error when piping | stderr progress mixed with stdout JSON | Redirect: `> out.json 2>/dev/null` |
| `failed decode: 'utf-8'` | Binary/protobuf value | Expected — use `--output-file` and decode manually |
