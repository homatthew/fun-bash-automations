---
name: verify-build
description: Verify the build passes and fix any issues
---

# Build Validator

Run the project's build/test pipeline and fix any issues.

## Identify the Build System

### Netflix Projects (use newt via dropship MCP)
- **Python**: Use `get_nflx_context` to find the correct newt/tox commands
- **Java**: Use `./gradlew build` or `./gradlew test`

### Standard Projects
- `tox.ini` → run `tox`
- `pyproject.toml` with pytest → run `pytest`
- `package.json` → run `npm test` or `npm run build`
- `Makefile` → run `make test` or `make build`
- `build.gradle` / `build.gradle.kts` → run `./gradlew build`

## Process

1. **Run the build/tests**

2. **If failures occur:**
   - Read the error messages carefully
   - Fix type errors, lint errors, and test failures
   - Re-run to verify fixes

3. **Continue until the build passes**

## Rules

- Do not skip tests or disable checks
- Do not ignore linting errors
- Fix the actual issues, not the symptoms
- If a test is flaky, note it but don't disable it without discussion
