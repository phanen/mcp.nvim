# 04 - Server: Tools

Source: <https://modelcontextprotocol.io/specification/2025-03-26/server/tools>

The Model Context Protocol (MCP) allows servers to expose tools that can be
invoked by language models. Tools enable models to interact with external
systems, such as querying databases, calling APIs, or performing
computations. Each tool is uniquely identified by a name and includes
metadata describing its schema.

## User Interaction Model

Tools in MCP are designed to be **model-controlled**: the language model can
discover and invoke tools automatically based on its contextual understanding
and the user's prompts.

Implementations are free to expose tools through any interface pattern that
suits their needs; the protocol itself does not mandate any specific user
interaction model.

> **Trust & safety:** there **SHOULD** always be a human in the loop with the
> ability to deny tool invocations.

## Capabilities

Servers that support tools **MUST** declare the `tools` capability:

```json
{
  "capabilities": {
    "tools": {
      "listChanged": true
    }
  }
}
```

`listChanged` indicates whether the server will emit notifications when the
list of available tools changes.

## Protocol Messages

### Listing Tools

To discover available tools, clients send a `tools/list` request. This
operation supports [pagination](./utilities/pagination.md).

**Request:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/list",
  "params": { "cursor": "optional-cursor-value" }
}
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "tools": [
      {
        "name": "get_weather",
        "description": "Get current weather information for a location",
        "inputSchema": {
          "type": "object",
          "properties": {
            "location": {
              "type": "string",
              "description": "City name or zip code"
            }
          },
          "required": ["location"]
        }
      }
    ],
    "nextCursor": "next-page-cursor"
  }
}
```

### Calling Tools

**Request:**

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "get_weather",
    "arguments": { "location": "New York" }
  }
}
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Current weather in New York:\nTemperature: 72°F\nConditions: Partly cloudy"
      }
    ],
    "isError": false
  }
}
```

### List Changed Notification

When the list of available tools changes:

```json
{ "jsonrpc": "2.0", "method": "notifications/tools/list_changed" }
```

## Data Types

### Tool

A tool definition includes:

- `name`: Unique identifier for the tool
- `description`: Human-readable description of functionality
- `inputSchema`: JSON Schema defining expected parameters
- `annotations`: optional properties describing tool behavior

### Tool Result

Tool results can contain multiple content items of different types:

- **Text** - `{ "type": "text", "text": "..." }`
- **Image** - `{ "type": "image", "data": "base64", "mimeType": "image/png" }`
- **Audio** - `{ "type": "audio", "data": "base64", "mimeType": "image/wav" }`
- **Embedded resource** - `{ "type": "resource", "resource": { ... } }`

## Error Handling

Two error reporting mechanisms:

1. **Protocol errors** - standard JSON-RPC errors for unknown tools,
   invalid arguments, server errors. Code `-32602` is typical.
2. **Tool execution errors** - reported as a successful result with
   `isError: true`:

   ```json
   {
     "jsonrpc": "2.0",
     "id": 4,
     "result": {
       "content": [
         { "type": "text", "text": "Failed to fetch weather: rate limit" }
       ],
       "isError": true
     }
   }
   ```

## Security Considerations

Servers **MUST**:

- Validate all tool inputs
- Implement proper access controls
- Rate limit tool invocations
- Sanitize tool outputs

Clients **SHOULD**:

- Prompt for user confirmation on sensitive operations
- Show tool inputs to the user before calling the server
- Validate tool results before passing to LLM
- Implement timeouts for tool calls
- Log tool usage for audit purposes

## mcp.nvim implementation

- Tools are registered with `mcp.tool_registry.register({ name, description,
  input_schema, handler })`.
- The handler receives the validated `arguments` table and returns either:
  - A list of content items (text/image/audio/resource), or
  - `nil, err_message` to be reported as `isError: true`.
- `notifications/tools/list_changed` is emitted automatically by the
  registry when a tool is added or removed.
- `inputSchema` is a JSON Schema expressed as a Lua table. mcp.nvim
  validates arguments against the schema **only when the user explicitly
  enables `mcp.server.validate_args`**. The default is off (mcp.nvim trusts
  the local tool author to validate themselves; the JSON-RPC layer already
  decodes JSON safely).
- Unknown tool names return JSON-RPC error code `-32602` ("Unknown tool").
