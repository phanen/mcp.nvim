# 05 - Server: Resources

Source: <https://modelcontextprotocol.io/specification/2025-03-26/server/resources>

The Model Context Protocol provides a standardized way for servers to expose
resources to clients. Resources allow servers to share data that provides
context to language models, such as files, database schemas, or
application-specific information. Each resource is uniquely identified by a
[URI](https://datatracker.ietf.org/doc/html/rfc3986).

## User Interaction Model

Resources in MCP are designed to be **application-driven**, with host
applications determining how to incorporate context based on their needs.

For example, applications could:

- Expose resources through UI elements for explicit selection (tree, list)
- Allow the user to search through and filter available resources
- Implement automatic context inclusion, based on heuristics

Implementations are free to expose resources through any interface pattern
that suits their needs.

## Capabilities

Servers that support resources **MUST** declare the `resources` capability:

```json
{
  "capabilities": {
    "resources": {
      "subscribe": true,
      "listChanged": true
    }
  }
}
```

Both `subscribe` and `listChanged` are optional. Servers can support
neither, either, or both.

## Protocol Messages

### Listing Resources

**Request:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "resources/list",
  "params": { "cursor": "optional-cursor-value" }
}
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "resources": [
      {
        "uri": "file:///project/src/main.rs",
        "name": "main.rs",
        "description": "Primary application entry point",
        "mimeType": "text/x-rust"
      }
    ],
    "nextCursor": "next-page-cursor"
  }
}
```

### Reading Resources

**Request:**

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "resources/read",
  "params": { "uri": "file:///project/src/main.rs" }
}
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "contents": [
      {
        "uri": "file:///project/src/main.rs",
        "mimeType": "text/x-rust",
        "text": "fn main() {\n    println!(\"Hello world!\");\n}"
      }
    ]
  }
}
```

### Resource Templates

Resource templates allow servers to expose parameterized resources using
[URI templates](https://datatracker.ietf.org/doc/html/rfc6570).

**Request:**

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "resources/templates/list",
  "params": { "cursor": "optional-cursor-value" }
}
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "resourceTemplates": [
      {
        "uriTemplate": "file:///{path}",
        "name": "Project Files",
        "description": "Access files in the project directory",
        "mimeType": "application/octet-stream"
      }
    ],
    "nextCursor": "next-page-cursor"
  }
}
```

### Subscriptions

**Subscribe Request:**

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "resources/subscribe",
  "params": { "uri": "file:///project/src/main.rs" }
}
```

**Update Notification:**

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/resources/updated",
  "params": { "uri": "file:///project/src/main.rs" }
}
```

### List Changed Notification

```json
{ "jsonrpc": "2.0", "method": "notifications/resources/list_changed" }
```

## Data Types

### Resource

- `uri`: Unique identifier for the resource
- `name`: Human-readable name
- `description`: Optional description
- `mimeType`: Optional MIME type
- `size`: Optional size in bytes

### Resource Contents

Resources can contain either text or binary data:

- **Text** - `{ "uri": "...", "mimeType": "text/plain", "text": "..." }`
- **Binary** - `{ "uri": "...", "mimeType": "image/png", "blob": "base64..." }`

## Common URI Schemes

- **`https://`** - Web resources
- **`file://`** - Filesystem-like resources
- **`git://`** - Git version control integration

## Error Handling

- Resource not found: `-32002`
- Internal errors: `-32603`

## mcp.nvim implementation status

- [x] `resources/list` (deferred to v1.1)
- [x] `resources/read` (deferred to v1.1)
- [x] `resources/templates/list` (deferred to v1.1)
- [x] `resources/subscribe` (deferred to v1.1)
- [x] `notifications/resources/list_changed` (deferred to v1.1)

mcp.nvim v1 does **not** implement resources. Tools are sufficient for the
LLM-as-agent use case (every action is a side-effecting tool call). Resources
are deferred to v1.1.
