# 03 - Lifecycle

Source: <https://modelcontextprotocol.io/specification/2025-03-26/basic/lifecycle>

The Model Context Protocol defines a rigorous lifecycle for client-server
connections that ensures proper capability negotiation and state management.

1. **Initialization**: Capability negotiation and protocol version agreement
2. **Operation**: Normal protocol communication
3. **Shutdown**: Graceful termination of the connection

```
sequenceDiagram
    Client->>Server: initialize request
    Server->>Client: initialize response
    Client->>Server: initialized notification
    Note over Client,Server: Operation Phase
    Client->>Server: Disconnect
    Note over Client,Server: Connection closed
```

## Initialization

The initialization phase **MUST** be the first interaction between client and
server. The client **MUST** initiate this phase by sending an `initialize`
request.

The initialize request **MUST NOT** be part of a JSON-RPC batch.

### Client request

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-03-26",
    "capabilities": {
      "roots": { "listChanged": true },
      "sampling": {}
    },
    "clientInfo": { "name": "ExampleClient", "version": "1.0.0" }
  }
}
```

### Server response

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-03-26",
    "capabilities": {
      "logging": {},
      "prompts": { "listChanged": true },
      "resources": { "subscribe": true, "listChanged": true },
      "tools": { "listChanged": true }
    },
    "serverInfo": { "name": "ExampleServer", "version": "1.0.0" },
    "instructions": "Optional instructions for the client"
  }
}
```

After successful initialization, the client **MUST** send an `initialized`
notification:

```json
{ "jsonrpc": "2.0", "method": "notifications/initialized" }
```

- The client **SHOULD NOT** send requests other than `ping`s before the server
  has responded to the `initialize` request.
- The server **SHOULD NOT** send requests other than `ping`s and `logging`
  notifications before receiving the `initialized` notification.

### Version Negotiation

- In `initialize`, the client **MUST** send the latest version it supports.
- If the server supports the requested version, it **MUST** respond with the
  same version. Otherwise, the server **MUST** respond with another version
  it supports (typically its latest).
- If the client does not support the server's response version, it **SHOULD**
  disconnect.

### Capability Negotiation

| Category | Capability     | Description                                                                  |
| -------- | -------------- | ---------------------------------------------------------------------------- |
| Client   | `roots`        | Ability to provide filesystem roots                                          |
| Client   | `sampling`     | Support for LLM sampling requests                                            |
| Client   | `experimental` | Non-standard experimental features                                           |
| Server   | `prompts`      | Offers prompt templates                                                      |
| Server   | `resources`    | Provides readable resources                                                  |
| Server   | `tools`        | Exposes callable tools                                                       |
| Server   | `logging`      | Emits structured log messages                                                |
| Server   | `completions`  | Supports argument autocompletion                                             |
| Server   | `experimental` | Non-standard experimental features                                           |

Capability objects can describe sub-capabilities like `listChanged` or
`subscribe`.

## Operation

Both parties **SHOULD**:

- Respect the negotiated protocol version
- Only use capabilities that were successfully negotiated

## Shutdown

No specific shutdown messages are defined. The underlying transport
mechanism signals connection termination.

### stdio

The client **SHOULD** initiate shutdown by:

1. Closing the input stream to the child process (the server).
2. Waiting for the server to exit, or sending `SIGTERM` if it does not exit
   within a reasonable time.
3. Sending `SIGKILL` if it still has not exited.

The server **MAY** initiate shutdown by closing its output stream and
exiting.

### HTTP

Shutdown is indicated by closing the associated HTTP connection(s).

## Timeouts

Implementations **SHOULD** establish timeouts for all sent requests, to
prevent hung connections and resource exhaustion. When the request has not
received a success or error response within the timeout period, the sender
**SHOULD** issue a cancellation notification for that request and stop
waiting for a response.

## Error Handling

Example initialization error:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32602,
    "message": "Unsupported protocol version",
    "data": {
      "supported": ["2024-11-05"],
      "requested": "1.0.0"
    }
  }
}
```

## mcp.nvim state machine

```
                +-----------+
                |  Created  |    (server just constructed, no peer)
                +-----+-----+
                      | first byte received
                      v
                +-----------+
                | Connected |    (peer identified but not initialized)
                +-----+-----+
                      | receive "initialize"
                      v
                +-----------+
                | Negotiating|   (capabilities/versions being exchanged)
                +-----+-----+
                      | respond to "initialize"
                      v
                +-----------+
                |  Ready    |   <-> "initialized" notification received
                +-----+-----+        (request handlers enabled)
                      | transport close
                      v
                +-----------+
                |  Closed   |
                +-----------+
```

The state machine is enforced in `mcp.server.lifecycle`. Handlers registered
via `mcp.tools` are only callable while in the `Ready` state.