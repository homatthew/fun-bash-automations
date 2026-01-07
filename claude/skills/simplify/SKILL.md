---
name: simplify
description: Simplify code and tests that were just written
---

# Code Simplifier

Review the code that was just written or modified and simplify it.

## For Application Code

1. **Remove unnecessary complexity**
   - Inline single-use variables
   - Remove redundant conditions
   - Simplify nested logic

2. **Reduce verbosity**
   - Remove unnecessary comments that state the obvious
   - Consolidate duplicate code
   - Use language idioms appropriately

3. **Remove dead code**
   - Unused imports
   - Commented-out code
   - Unreachable branches

## For Tests - Start From First Principles

1. **Identify the happy case**
   - What is the primary use case this code serves?
   - Write one clear test that demonstrates correct behavior
   - This is the most important test

2. **Identify realistic unhappy cases**
   - What errors would users *actually* encounter?
   - Don't test hypothetical edge cases that won't happen in practice
   - Focus on: invalid input, missing data, permission errors

3. **Parametrize when it makes sense**
   - If testing the same logic with different inputs, use `@pytest.mark.parametrize`
   - Group related test cases into a single parametrized test
   - Don't parametrize if it obscures what's being tested

4. **Remove redundant tests**
   - Multiple tests asserting the same behavior
   - Tests that duplicate what the happy case already covers
   - Tests for implementation details rather than behavior

## Do NOT

- Add new features or functionality
- Change behavior
- Add type annotations unless they were already present
- Over-engineer or add abstractions
- Keep tests "just in case" - be ruthless

The goal is simpler code with identical behavior and fewer, more meaningful tests.
