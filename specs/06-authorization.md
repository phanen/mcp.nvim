# 06 - Authorization

Source: <https://modelcontextprotocol.io/specification/2025-03-26/basic/authorization>

## Status

**Not implemented in mcp.nvim v1.** This document is vendored for
completeness so the next person adding auth can read the spec inline.

## Purpose and Scope

The Model Context Protocol provides authorization capabilities at the
transport level, enabling MCP clients to make requests to restricted MCP
servers on behalf of resource owners. This specification defines the
authorization flow for HTTP-based transports.

## Protocol Requirements

Authorization is **OPTIONAL** for MCP implementations. When supported:

- Implementations using an HTTP-based transport **SHOULD** conform to this
  specification.
- Implementations using an STDIO transport **SHOULD NOT** follow this
  specification, and instead retrieve credentials from the environment.
- Implementations using alternative transports **MUST** follow established
  security best practices for their protocol.

## Standards Compliance

This authorization mechanism is based on:

- OAuth 2.1 IETF DRAFT
- OAuth 2.0 Authorization Server Metadata (RFC 8414)
- OAuth 2.0 Dynamic Client Registration Protocol (RFC 7591)

## OAuth Grant Types

MCP servers **SHOULD** support the OAuth grant types that best align with
the intended audience:

1. **Authorization Code** - useful when the client is acting on behalf of a
   (human) end user.
2. **Client Credentials** - the client is another application (not a human).

## mcp.nvim threat model (without auth)

The v1 server is intended to run on `127.0.0.1` only. The threat model
relies on OS-level access control (the user account can already do anything
the server can do). Auth is not yet a hard requirement because:

- We are not exposing the server over the public internet.
- Any process running as the same user can read/write everything the
  server can read/write.
- DNS rebinding attacks are mitigated by validating the `Origin` header on
  all incoming HTTP requests (see [`02-transports.md`](02-transports.md)).

The moment the user wants to expose the server on a non-loopback address
or to a less-trusted user account, OAuth 2.1 with PKCE is required, and
this document is the starting point for that work.
