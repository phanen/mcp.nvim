# 02 - Transports

Source: <https://modelcontextprotocol.io/specification/2025-03-26/basic/transports>

MCP uses JSON-RPC to encode messages. JSON-RPC messages **MUST** be UTF-8
encoded.

The protocol currently defines two standard transport mechanisms for
client-server communication:

1. [`stdio`](#stdio) - communication over standard in and standard out
2. [`Streamable HTTP`](#streamable-http) - HTTP POST + optional SSE streaming

Clients **SHOULD** support `stdio` whenever possible.

It is also possible for clients and servers to implement
[custom transports](#custom-transports) in a pluggable fashion.

## stdio

In the **stdio** transport:

- The client launches the MCP server as a subprocess.
- The server reads JSON-RPC messages from its standard input (`stdin`) and
  sends messages to its standard output (`stdout`).
- Messages may be JSON-RPC requests, notifications, responses — or a JSON-RPC
  batch containing one or more requests and/or notifications.
- Messages are **delimited by newlines**, and **MUST NOT** contain embedded
  newlines.
- The server **MAY** write UTF-8 strings to its standard error (`stderr`) for
  logging purposes. Clients **MAY** capture, forward, or ignore this logging.
- The server **MUST NOT** write anything to its `stdout` that is not a valid
  MCP message.
- The client **MUST NOT** write anything to the server's `stdin` that is not a
  valid MCP message.

```
sequenceDiagram
    Client->>Server Process: Launch subprocess
    loop Message Exchange
        Client->>Server Process: Write newline-delimited JSON to stdin
        Server Process->>Client: Write newline-delimited JSON to stdout
        Server Process--)Client: Optional logs on stderr
    end
```

### mcp.nvim notes

- mcp.nvim **cannot be a stdio server in a normal GUI Neovim session**:
  `stdin` is the user's terminal. It can only serve `stdio` when launched as
  a `nvim --headless` child process, e.g. via `vim.system()` from the client.
- We DO support `stdio` for completeness and for headless use cases
  (e.g. driving MCP from a CI runner that has no UI).
- Framing for `stdio` is **newline-delimited** JSON. This differs from LSP
  framing (`Content-Length: N\r\n\r\n<json>`). Our `MessageStream`
  abstraction accepts a per-transport `decode` function precisely so this
  divergence does not leak into the JSON-RPC core.

## Streamable HTTP

This replaces the `HTTP+SSE` transport from protocol version `2024-11-05`.

In the **Streamable HTTP** transport, the server operates as an independent
process that can handle multiple client connections. This transport uses HTTP
POST and GET requests. The server can optionally make use of
[Server-Sent Events](https://en.wikipedia.org/wiki/Server-sent_events) (SSE)
to stream multiple server messages.

The server **MUST** provide a single HTTP endpoint path (the **MCP
endpoint**) that supports both POST and GET methods. For example, this could
be a URL like `https://example.com/mcp`.

### Security Warning

When implementing Streamable HTTP transport:

1. Servers **MUST** validate the `Origin` header on all incoming connections
   to prevent DNS rebinding attacks.
2. When running locally, servers **SHOULD** bind only to localhost
   (`127.0.0.1`) rather than all network interfaces (`0.0.0.0`).
3. Servers **SHOULD** implement proper authentication for all connections.

Without these protections, attackers could use DNS rebinding to interact with
local MCP servers from remote websites.

### Sending Messages to the Server

Every JSON-RPC message sent from the client **MUST** be a new HTTP POST
request to the MCP endpoint.

1. The client **MUST** use HTTP POST to send JSON-RPC messages to the MCP
   endpoint.
2. The client **MUST** include an `Accept` header, listing both
   `application/json` and `text/event-stream` as supported content types.
3. The body of the POST request **MUST** be one of the following:
   - A single JSON-RPC *request*, *notification*, or *response*
   - An array batching one or more *requests and/or notifications*
   - An array batching one or more *responses*
4. If the input consists solely of (any number of) JSON-RPC *responses* or
   *notifications*:
   - If the server accepts the input, the server **MUST** return HTTP status
     code `202 Accepted` with no body.
   - If the server cannot accept the input, it **MUST** return an HTTP error
     status code (e.g. `400 Bad Request`). The HTTP response body **MAY**
     comprise a JSON-RPC *error response* that has no `id`.
5. If the input contains any number of JSON-RPC *requests*, the server
   **MUST** either return `Content-Type: text/event-stream`, to initiate an
   SSE stream, or `Content-Type: application/json`, to return one JSON object.
   The client **MUST** support both these cases.
6. If the server initiates an SSE stream:
   - The SSE stream **SHOULD** eventually include one JSON-RPC *response* per
     each JSON-RPC *request* sent in the POST body. These *responses* **MAY**
     be batched.
   - The server **MAY** send JSON-RPC *requests* and *notifications* before
     sending a JSON-RPC *response*. These messages **SHOULD** relate to the
     originating client *request*. These *requests* and *notifications*
     **MAY** be batched.
   - The server **SHOULD NOT** close the SSE stream before sending a
     JSON-RPC *response* per each received JSON-RPC *request*, unless the
     [session](#session-management) expires.
   - After all JSON-RPC *responses* have been sent, the server **SHOULD**
     close the SSE stream.

### Listening for Messages from the Server

1. The client **MAY** issue an HTTP GET to the MCP endpoint. This can be
   used to open an SSE stream, allowing the server to communicate to the
   client, without the client first sending data via HTTP POST.
2. The client **MUST** include an `Accept` header, listing
   `text/event-stream` as a supported content type.
3. The server **MUST** either return `Content-Type: text/event-stream` in
   response to this HTTP GET, or else return HTTP `405 Method Not Allowed`.

### Multiple Connections

The client **MAY** remain connected to multiple SSE streams simultaneously.
The server **MUST** send each of its JSON-RPC messages on only one of the
connected streams.

### Session Management

1. A server using the Streamable HTTP transport **MAY** assign a session ID
   at initialization time, by including it in an `Mcp-Session-Id` header on
   the HTTP response containing the `InitializeResult`.
2. If an `Mcp-Session-Id` is returned by the server during initialization,
   clients using the Streamable HTTP transport **MUST** include it in the
   `Mcp-Session-Id` header on all of their subsequent HTTP requests.
3. The server **MAY** terminate the session at any time, after which it
   **MUST** respond to requests containing that session ID with HTTP `404
   Not Found`.
4. When a client receives HTTP 404 in response to a request containing an
   `Mcp-Session-Id`, it **MUST** start a new session by sending a new
   `InitializeRequest` without a session ID attached.
5. Clients that no longer need a particular session **SHOULD** send an HTTP
   DELETE to the MCP endpoint with the `Mcp-Session-Id` header, to
   explicitly terminate the session.

### mcp.nvim notes

- mcp.nvim v1 implements the Streamable HTTP transport fully enough
  for tool-server use: `GET /mcp` opens a `text/event-stream` and
  every server-initiated JSON-RPC notification (e.g.
  `notifications/tools/list_changed`) is broadcast to all connected
  streams with a monotonically-increasing `id` field. `POST /mcp`
  returns the simpler `application/json` response; we do not yet
  upgrade POST responses to SSE.
- mcp.nvim binds to `127.0.0.1` by default. Setting `host = "0.0.0.0"` is
  allowed but emits a `:checkhealth` warning.
- Origin header validation is enforced by default; `Origin: null` is
  rejected (DNS rebinding mitigation).
- mcp.nvim v1 does not implement resumability (`Last-Event-ID` replay
  is not honoured by the GET stream). Event ids are emitted on the
  wire so a future patch can plug in replay without breaking
  wire-format compatibility.
- Session management (`Mcp-Session-Id`) is not implemented. The
  server does not assign a session id at `initialize` time, so
  clients are not required to round-trip one.

## Custom Transports

Clients and servers **MAY** implement additional custom transport mechanisms
to suit their specific needs. mcp.nvim's `Transport` interface is open: an
implementation needs only `:listen`, `:write`, `:is_closing`, `:terminate`.
Adding `tcp+custom-framing`, `unix-socket`, or `websocket` is straightforward.