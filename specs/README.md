# MCP Specification Reference

This directory contains a snapshot of the Model Context Protocol (MCP)
specification vendored from <https://modelcontextprotocol.io/specification/2025-03-26>.
mcp.nvim targets **protocol version `2025-03-26`** (the `Streamable HTTP`
revision; the older `2024-11-05` `HTTP+SSE` transport is *not* implemented).

These pages are referenced throughout the codebase while implementing
handlers, transports, and capability negotiation. They are kept in-tree so
development does not require network access.

## Index

| File | Topic | Notes |
| --- | --- | --- |
| [`01-protocol.md`](01-protocol.md) | Base JSON-RPC message types, batching, schema URL | Required reading before touching `json_rpc.lua`. |
| [`02-transports.md`](02-transports.md) | `stdio` and `Streamable HTTP` transports | `stdio` framing differs from MCP's `stdio` — see the note below. |
| [`03-lifecycle.md`](03-lifecycle.md) | `initialize`, capability negotiation, shutdown | Drives `mcp.server:handle_initialize` and the lifecycle FSM. |
| [`04-server-tools.md`](04-server-tools.md) | `tools/list`, `tools/call`, `notifications/tools/list_changed` | Drives `mcp.tools` registry and dispatcher. |
| [`05-server-resources.md`](05-server-resources.md) | `resources/list`, `resources/read`, `resources/templates/list`, subscriptions | Future work. |
| [`06-authorization.md`](06-authorization.md) | OAuth 2.1 + RFC 8414 + RFC 7591 | Not implemented in v1. Documented for completeness. |

## Authoritative source

- TypeScript schema (source of truth): <https://github.com/modelcontextprotocol/specification/blob/main/schema/2025-03-26/schema.ts>
- JSON schema (generated): <https://github.com/modelcontextprotocol/specification/blob/main/schema/2025-03-26/schema.json>
- Documentation index (machine-readable): <https://modelcontextprotocol.io/llms.txt>

## Notes on framing

MCP `stdio` transport uses **newline-delimited JSON**, not LSP's
`Content-Length`-framed JSON. The two are mutually exclusive and we **must not**
mix them. mcp.nvim's `MessageStream` accepts a `decode` function from the
transport layer, so this difference is a per-transport configuration rather than
a code change.

## Maintenance

These pages are vendored as-is. Re-vendor only when the protocol version
targeted by mcp.nvim changes; bumping the protocol version is a breaking
change and warrants a major version bump.
