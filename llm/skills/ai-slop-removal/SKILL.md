---
name: ai-slop-removal
description: Review and clean AI-generated code issues. Identifies dead code, over-verbose code, unnecessary comments, deviations from project patterns, and test quality issues after AI code generation.
category: productivity
tags: [code-review, cleanup, ai-generated, quality, patterns]
compatibility: Any language
allowed-tools: ["Bash(script-pattern:*)", "Edit", "Read", "Glob", "Grep"]
---

# AI Slop Removal Skill

Review and clean common issues in AI-generated code. Focus on practical problems that slip through when AI generates code.

## When to Use

- After Claude Code generates new files
- After accepting large code suggestions
- Before committing AI-generated code
- When code feels "off" but passes linting

## Common AI Slop Patterns

### 1. Dead Code That Compiles

**Pattern**: Unused variables, parameters, imports
```python
# BEFORE (AI-generated)
def process_data(data, config, logger, cache):  # cache unused
    import os  # unused
    import json
    result = []
    temp = {}  # temp unused
    for item in data:
        result.append(json.loads(item))
    return result

# AFTER (cleaned)
def process_data(data):
    import json
    return [json.loads(item) for item in data]
```

**Detection**: Look for unused imports, variables, and parameters. Use project linting tools if available.

### 2. Over-Verbose Code

**Pattern**: Unnecessary intermediate variables, verbose logic
```python
# BEFORE (AI-generated)
def calculate_total(items):
    total = 0
    for item in items:
        item_price = item.get('price')
        item_quantity = item.get('quantity')
        item_subtotal = item_price * item_quantity
        total = total + item_subtotal
    return total

# AFTER (cleaned)
def calculate_total(items):
    return sum(item['price'] * item['quantity'] for item in items)
```

### 3. Unnecessary Comments

**Pattern**: Comments that restate code
```python
# BEFORE (AI-generated)
# Initialize the counter variable to zero
counter = 0
# Loop through each item in the items list
for item in items:
    # Increment the counter by one
    counter += 1
    # Print the current counter value
    print(counter)

# AFTER (cleaned)
for i, item in enumerate(items, 1):
    print(i)
```

### 4. Pattern Deviation

**Pattern**: AI uses different style than existing codebase
```python
# EXISTING PROJECT PATTERN
class DataProcessor:
    def __init__(self, config):
        self._config = config

    def process(self, data):
        return self._transform(data)

# AI-GENERATED (different style)
class NewProcessor:
    def __init__(self, config):
        self.config = config  # Should be _config

    def processData(self, data):  # Should be process
        return self.transform(data)  # Should be _transform

# CLEANED (matches pattern)
class NewProcessor:
    def __init__(self, config):
        self._config = config

    def process(self, data):
        return self._transform(data)
```

### 5. Test Quality Issues

**Pattern**: Tests that always pass, mock everything, test nothing
```python
# BEFORE (AI-generated test)
def test_process_data():
    # Mock everything
    mock_data = Mock()
    mock_config = Mock()
    mock_logger = Mock()
    mock_result = Mock()

    # Mock the method to return mock
    processor = Mock()
    processor.process.return_value = mock_result

    # Call the mocked method
    result = processor.process(mock_data)

    # Assert mock was called
    processor.process.assert_called_once()
    assert result == mock_result  # Always passes

# AFTER (real test)
def test_process_data():
    data = [{"id": 1, "value": "test"}]
    processor = DataProcessor()

    result = processor.process(data)

    assert len(result) == 1
    assert result[0]["id"] == 1
    assert result[0]["value"] == "test"
```

### 6. Error Handling That Hides Problems

**Pattern**: Catching everything, returning None/empty
```python
# BEFORE (AI-generated)
def load_config(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}  # Silent failure

# AFTER (explicit)
def load_config(path):
    with open(path) as f:
        return json.load(f)
```

### 7. Premature Abstraction

**Pattern**: Classes/functions for one-time use
```python
# BEFORE (AI-generated)
class DataValidator:
    def __init__(self, data):
        self.data = data

    def validate(self):
        return self._check_required() and self._check_types()

    def _check_required(self):
        return all(k in self.data for k in ['id', 'name'])

    def _check_types(self):
        return isinstance(self.data.get('id'), int)

# Used only once:
validator = DataValidator(data)
if validator.validate():
    process(data)

# AFTER (inline, used once)
required_fields = ['id', 'name']
if all(k in data for k in required_fields) and isinstance(data.get('id'), int):
    process(data)
```

### 8. Unrelated Diff Churn (Scope Creep in an Edit)

**Pattern**: When asked for a *specific* change (a refactor, a move, a bug fix),
the AI also rewrites untouched code cosmetically. Each edit looks harmless on its
own, but together they bloat the diff, bury the real change, and risk silent
regressions in code nobody meant to touch. **Rule: a diff should contain only
what the task requires.** Most of these surface when a function is moved or a
call site changes, and the AI "tidies" the body along the way.

**8a. Dropped docstring/comment that still applied** (the task was to change the
call site, not the body):
```python
# BEFORE
def get_replication_factor(env, cluster):
    """Validate the new path against the legacy backend; always return the new
    result, and log any mismatch for monitoring."""
    ...

# AFTER (churn — docstring deleted for no reason; it was still accurate)
def get_replication_factor(env, cluster):
    ...
```
Also includes dropping explanatory comments (`# this satisfies the type checker`,
a TODO, a link to docs) that the change didn't invalidate.

**8b. Conditional reflowed with identical behavior**:
```python
# BEFORE
if len(values) > 0:
    return mean(values)
return DEFAULT

# AFTER (churn — same logic, noisy diff)
return mean(values) if values else DEFAULT
```

**8c. Casing / local-variable rename for style only**:
```python
# BEFORE
ENDPOINT_URL = f"https://backend.{region}.example/v2"
client = Client(endpoint=ENDPOINT_URL)

# AFTER (churn — local renamed UPPER -> lower with no behavior change)
endpoint_url = f"https://backend.{region}.example/v2"
client = Client(endpoint=endpoint_url)
```
Same category: renaming a throwaway local (`foo` -> `parsed_tables`). This one is
a genuine *improvement* — but it still doesn't belong in an unrelated diff. Do it
as its own commit so a reviewer can evaluate it on its merits.

**8d. Helper inlined/extracted unrelated to the task**:
```python
# BEFORE — small helper used by the function being moved
async def get_tier(app, account):
    facts = await _get_app_facts(app, account)
    ...

async def _get_app_facts(app, account):
    return await Metadata.get(appname=app, account=account)

# AFTER (churn — helper inlined and deleted; behavior identical, scope unrelated)
async def get_tier(app, account):
    facts = await Metadata.get(appname=app, account=account)
    ...
```

**Detection**: After editing, diff against the base (`git diff <base>`). Every
hunk should map to the stated task. A hunk that only rewords a comment, reflows a
conditional, changes casing, or renames a local — with **identical behavior** — is
churn. Revert it, or split it into a separate, clearly-labeled cleanup commit.

**Not the same as "never improve"**: the point is not to forbid cleanups, it's to
keep them out of a focused diff. Worthwhile cleanup → its own commit.

## Review Workflow

### 1. Quick Scan
- Find files modified recently (AI-generated) via `git diff --name-only`
- Check file sizes — suspiciously large files warrant closer review
- Check comment density

### 2. Pattern Check
- Compare naming patterns between existing code and new code
- Look for style deviations (naming conventions, private prefixes, method signatures)

### 3. Complexity Check
- Look for deeply nested logic
- Find functions with too many parameters
- Identify overly complex class hierarchies for simple tasks

### 4. Test Quality Check
- Verify tests use real data, not all mocks
- Confirm tests would actually fail if the code broke
- Check assertion count — tests with zero or one trivial assertion are suspicious

## Checklist

After AI generates code, review:

- [ ] No unused variables/parameters/imports
- [ ] Code follows project naming conventions
- [ ] No unnecessary intermediate variables
- [ ] Comments explain "why", not "what"
- [ ] Tests use real data, not all mocks
- [ ] Error handling is explicit, not silent
- [ ] No premature abstractions
- [ ] Complexity is justified
- [ ] Follows existing patterns in codebase
- [ ] No unrelated diff churn — every hunk maps to the task; no cosmetic edits to untouched code

## Before/After Examples

### Example 1: Data Processing

**Before (AI slop):**
```python
def process_user_data(user_data, config, logger, cache, db):
    """Process user data."""
    import json
    import os
    import sys

    # Initialize result list
    result = []

    # Check if user data is valid
    if user_data is not None:
        # Loop through each user
        for user in user_data:
            # Get user ID
            user_id = user.get('id')
            # Get user name
            user_name = user.get('name')
            # Create user dict
            user_dict = {
                'id': user_id,
                'name': user_name
            }
            # Append to result
            result.append(user_dict)

    # Return result
    return result
```

**After (cleaned):**
```python
def process_user_data(users):
    """Extract id and name from user data."""
    return [
        {'id': u['id'], 'name': u['name']}
        for u in users
    ]
```

### Example 2: Configuration Loading

**Before (AI slop):**
```python
class ConfigLoader:
    """Load configuration from file."""

    def __init__(self, config_path):
        """Initialize config loader."""
        self.config_path = config_path
        self.config = None

    def load(self):
        """Load configuration file."""
        try:
            with open(self.config_path, 'r') as file:
                data = file.read()
                self.config = json.loads(data)
                return True
        except Exception as e:
            print(f"Error loading config: {e}")
            return False

    def get_config(self):
        """Get loaded configuration."""
        return self.config

# Usage
loader = ConfigLoader('config.json')
if loader.load():
    config = loader.get_config()
```

**After (cleaned):**
```python
def load_config(path):
    """Load JSON config from path."""
    with open(path) as f:
        return json.load(f)

# Usage
config = load_config('config.json')
```

## Best Practices

1. **Always review AI code** - Never commit AI-generated code without review
2. **Follow project patterns** - Check existing code for conventions
3. **Keep it simple** - Simplest solution that works
4. **Delete liberally** - Remove anything not needed
5. **Test properly** - Tests should fail if code breaks
6. **Document "why"** - Comments explain reasoning, not mechanics
7. **Fail fast** - Explicit errors better than silent failures
