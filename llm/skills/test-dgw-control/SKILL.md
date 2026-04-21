---
name: test-dgw-control
description: Test DGW Control (`dgw-control`) server or HTTP wrapper changes locally. Covers targeted Gradle compile/test/integration loops, Spring Boot `bootRun`, and gRPC local validation with `grpcurl --local`.
---

# Testing DGW Control

Use when testing DGW Control server or HTTP wrapper changes locally.

## Fast Path

- **Proto-only change**
  - `./gradlew :dgw-control-proto-definition:build`
  - `./gradlew :dgw-control-server:compileJava`
- **Server business logic change**
  - `./gradlew :dgw-control-server:test --tests "<pattern>"`
  - `./gradlew :dgw-control-server:integrationTest --tests "<fqcn or pattern>"`
- **HTTP wrapper change**
  - `./gradlew :dgw-control-http-server:test`
  - Run `:dgw-control-http-server:bootRun` only if the task touches the wrapper

Prefer targeted test tasks first. Broaden only after the focused loop passes.

## Core gRPC Loop

Prefer this path for DGW Control core changes.

1. Build proto if the RPC surface changed:
   - `./gradlew :dgw-control-proto-definition:build`
2. Start the server on a fixed local port:
   - `./gradlew :dgw-control-server:bootRun --args='--grpc.server.dgwcontrol.port=8980'`
3. Validate locally with `grpcurl --local`.
4. Re-run a read RPC such as `GetNamespaces` or `ViewNamespaces` to confirm the mutation/result.

Short example flow:

```bash
grpcurl --local localhost:8980 list
grpcurl --local localhost:8980 describe com.netflix.dgw.control.DgwControlService
grpcurl --local -d '{"namespace_name":"..."}' \
  localhost:8980 com.netflix.dgw.control.DgwControlService/ViewNamespaces
```

If reflection is unavailable, build proto first and use generated descriptors/protosets from `dgw-control-proto-definition/build/descriptors`.

## HTTP Wrapper Loop

Use this only when the task actually touches `dgw-control-http-server`.

```bash
./gradlew :dgw-control-http-server:bootRun
```

The wrapper is a separate validation path from the core gRPC service. Do not default to it for server-side DGW Control changes.

## Test Matrix

- **Proto-only change**
  - Build proto
  - Compile affected Java modules
- **Server business logic change**
  - Targeted unit test
  - Targeted integration test
  - gRPC manual validation if the public surface changed
- **Namespace CRUD / validation change**
  - Targeted integration test first
  - `bootRun` + `grpcurl --local` for final manual confirmation
- **Client-facing surface change**
  - Build proto
  - Server compile
  - Integration test
  - Manual gRPC call against local server

## Common Commands

```bash
./gradlew :dgw-control-proto-definition:build
./gradlew :dgw-control-server:compileJava
./gradlew :dgw-control-server:test --tests "<pattern>"
./gradlew :dgw-control-server:integrationTest --tests "<fqcn or pattern>"
./gradlew :dgw-control-server:bootRun --args='--grpc.server.dgwcontrol.port=8980'
./gradlew :dgw-control-http-server:bootRun
```

## Debugging Notes

- Laptop config already includes a clue for local gRPC testing: `application-laptop.yml` mentions compatibility with `grpcurl --local`.
- If a focused test fails, rerun that same test first before broadening.
- Check server logs from `bootRun` before assuming the client call is wrong.
- If `grpcurl --local` cannot discover methods automatically, use generated descriptors/protosets from `build/descriptors`.

## Guardrails

- Do not skip tests or disable checks.
- Do not default to `./gradlew build` when a targeted loop is faster and clearer.
- Prefer gRPC validation first for DGW Control core changes.
- Use the HTTP wrapper loop only when the wrapper itself is part of the change.
