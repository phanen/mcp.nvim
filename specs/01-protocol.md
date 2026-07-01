# 01 - Base Protocol

Source: <https://modelcontextprotocol.io/specification/2025-03-26/basic>

The Model Context Protocol consists of:

- **Base Protocol**: Core JSON-RPC message types
- **Lifecycle Management**: Connection initialization, capability negotiation,
  and session control
- **Server Features**: Resources, prompts, and tools exposed by servers
- **Client Features**: Sampling and root directory lists provided by clients
- **Utilities**: Cross-cutting concerns like logging and argument completion

All implementations **MUST** support the base protocol and lifecycle management
components. Other components **MAY** be implemented based on the specific needs
of the application.

## Messages

All messages between MCP clients and servers **MUST** follow the
[JSON-RPC 2.0](https://www.jsonrpc.org/specification) specification. The
protocol defines these types of messages:

### Requests

Requests are sent from the client to the server or vice versa, to initiate an
operation.

```typescript
{
  jsonrpc: "2.0";
  id: string | number;
  method: string;
  params?: {
    [key: string]: unknown;
  };
}
```

- Requests **MUST** include a string or integer ID.
- Unlike base JSON-RPC, the ID **MUST NOT** be `null`.
- The request ID **MUST NOT** have been previously used by the requestor within
  the same session.

### Responses

Responses are sent in reply to requests, containing the result or error of the
operation.

```typescript
{
  jsonrpc: "2.0";
  id: string | number;
  result?: {
    [key: string]: unknown;
  }
  error?: {
    code: number;
    message: string;
    data?: unknown;
  }
}
```

- Responses **MUST** include the same ID as the request they correspond to.
- **Responses** are further sub-categorized as either **successful results** or
  **errors**. Either a `result` or an `error` **MUST** be set. A response
  **MUST NOT** set both.
- Results **MAY** follow any JSON object structure, while errors **MUST**
  include an error code and message at minimum.
- Error codes **MUST** be integers.

### Notifications

Notifications are sent from the client to the server or vice versa, as a
one-way message. The receiver **MUST NOT** send a response.

```typescript
{
  jsonrpc: "2.0";
  method: string;
  params?: {
    [key: string]: unknown;
  };
}
```

- Notifications **MUST NOT** include an ID.

### Batching

JSON-RPC also defines a means to
[batch multiple requests and notifications](https://www.jsonrpc.org/specification#batch),
by sending them in an array. MCP implementations **MAY** support sending
JSON-RPC batches, but **MUST** support receiving JSON-RPC batches.

## Auth

MCP provides an [Authorization](../06-authorization.md) framework for use with
HTTP. Implementations using an HTTP-based transport **SHOULD** conform to this
specification, whereas implementations using STDIO transport **SHOULD NOT**
follow this specification, and instead retrieve credentials from the
environment.

Additionally, clients and servers **MAY** negotiate their own custom
authentication and authorization strategies.

## Schema

The full specification of the protocol is defined as a TypeScript schema:

- <https://github.com/modelcontextprotocol/specification/blob/main/schema/2025-03-26/schema.ts> (source of truth)
- <https://github.com/modelcontextprotocol/specification/blob/main/schema/2025-03-26/schema.json> (JSON Schema, generated)

## What this means for mcp.nvim

1. mcp.nvim implements a **JSON-RPC 2.0 server**. Conformance to that spec is
   non-negotiable; deviations are bugs.
2. We support JSON-RPC batches on the receiving side (parse the `[]` envelope)
   even though we are unlikely to send batches ourselves.
3. Error responses use standard JSON-RPC error codes plus the
   `*-32600..-32000` MCP-defined codes (`-32601 Method not found`,
   `-32602 Invalid params`, `-32603 Internal error`).
4. Server features (tools, resources, prompts) are gated by capabilities
   declared in the `initialize` handshake.
