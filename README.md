# mcp.nvim

A Neovim plugin that exposes your editor's intelligence (LSP, buffer
state, custom Lua functions) to AI coding agents over the
[Model Context Protocol](https://modelcontextprotocol.io/).

mcp.nvim implements a **streamable-HTTP MCP server in-process**
(using `vim.uv`), so no separate Node / Rust / Python process is
needed: the same `nvim` that you edit in also serves the MCP
endpoint to clients like `opencode`, Claude Code, or the
`@modelcontextprotocol/sdk` family.

## Features

- **Built-in LSP tools** - one call to `setup()` registers
  `lsp_definition`, `lsp_references`, `lsp_hover`,
  `lsp_document_symbols`, `lsp_workspace_symbols`,
  `lsp_implementation`, and `lsp_type_definition`. Each tool
  forwards to whichever LSP client is attached to the file.
- **Streamable-HTTP transport** - compliant with MCP protocol
  version `2025-03-26`, with origin allow-listing for DNS-rebinding
  protection, request-response POSTs, and proper 202 / 405 / 403
  responses.
- **Symmetric JSON-RPC core** - a single `Connection` is both client
  and server; the same code path is used to dispatch incoming
  requests, send responses, and initiate outgoing calls.
- **Tool registry** - register any Lua function as an MCP tool
  with a JSON Schema description; the registry emits
  `notifications/tools/list_changed` automatically.
- **Lifecycle FSM** - the MCP server refuses tool calls until
  `initialize` and `notifications/initialized` have been received,
  matching the spec.
- **:checkhealth mcp** - reports the bind address, registered
  tools, origin allow-list, and protocol version.

## Installation

`mcp.nvim` targets Neovim **0.11+** (it uses
`vim.uv.new_tcp` + `vim.uri_from_bufnr` and the modern
`vim.lsp.buf_request_sync` API). LuaJIT 2.1 is required.

With `lazy.nvim`:

```lua
{
  'yourname/mcp.nvim',
  cmd = { 'McpStart', 'McpStop', 'McpRestart', 'McpPort' },
  config = function()
    require('mcp').setup({
      http = {
        host = '127.0.0.1',
        port = 0,                 -- OS-assigned; see :McpPort
        allowed_origins = { 'null' },
      },
      tools = {
        -- Register your own tools here. The LSP set is included
        -- automatically; pass `with_lsp_tools = false` to opt out.
        {
          name = 'buffer_stats',
          description = 'Line / word / char counts for a buffer',
          inputSchema = {
            type = 'object',
            properties = {
              path = { type = 'string' },
            },
            required = { 'path' },
          },
          handler = function(args)
            local bufnr = vim.fn.bufadd(args.path)
            vim.fn.bufload(bufnr)
            local lines = vim.api.nvim_buf_line_count(bufnr)
            return {
              { type = 'text', text = string.format('%d lines in %s', lines, args.path) },
            }
          end,
        },
      },
    })
    require('mcp.tools.lsp').register_all(require('mcp').registry())
  end,
}
```

## Usage

After `setup()`, the plugin binds a streamable-HTTP server on
`host:port`. Run `:McpPort` to see the URL (default
`http://127.0.0.1:<port>/mcp`).

Configure your client. For `opencode`:

```json
{
  "mcp": {
    "nvim": {
      "type": "remote",
      "url": "http://127.0.0.1:<port>/mcp"
    }
  }
}
```

For Claude Code:

```sh
claude mcp add --transport http nvim http://127.0.0.1:<port>/mcp
```

### Automatic registration with a running opencode

Hard-coding the port in `opencode.json` is annoying because the
port is OS-assigned at every Neovim start. mcp.nvim ships a
helper that posts to opencode's runtime `mcp.add` API at runtime.
To wire mcp.nvim up to a long-running opencode.nvim session, add
to your `init.lua`:

```lua
require('mcp').setup({ ... })        -- start the in-process server
require('mcp').attach_opencode()     -- subscribe to opencode.nvim
```

`attach_opencode` reaches into the opencode.nvim state store
through the public `require('opencode.state').event_manager`
handle and registers a `custom.server_ready` subscriber. When
opencode spawns its server, the subscriber fires and
`mcp.opencode_register(url)` runs. The same call is also exposed
as `:McpAttachOpencode [name]` and the older `:McpRegister [url]
[name]` for users who want to drive the registration manually.

Implementation notes:

- `opencode.nvim` exposes `vim.api.nvim_exec_autocmds('User',
  { pattern = 'OpencodeEvent:' .. event_name, ... })` when its
  EventManager emits a `custom.server_ready`. We catch the same
  events through `EventManager:subscribe` so we do not depend on
  the autocmd pattern being stable.
- `attach_opencode` is idempotent. Repeated calls do not stack
  subscribers.
- If opencode.nvim is not installed `attach_opencode` is a no-op.
- See [the opencode HTTP API](https://github.com/sst/opencode/blob/dev/packages/opencode/src/server/routes/instance/httpapi/groups/mcp.ts)
  for the underlying wire contract (identifier `mcp.add`, payload
  `{ name, config }`, response `StatusMap`).

## Commands

| Command         | Description                                  |
| --------------- | -------------------------------------------- |
| `:McpStart`     | Start the HTTP server                        |
| `:McpStop`      | Stop the HTTP server                         |
| `:McpRestart`   | Restart the HTTP server (rebind)             |
| `:McpPort`      | Print the current `http://host:port/mcp` URL |
| `:McpAttachOpencode` | Subscribe mcp.nvim to a running opencode.nvim instance (manual equivalent of `mcp.attach_opencode()`) |
| `:McpRegister`  | Register mcp.nvim with a running opencode server (URL optional if `opencode.nvim` is loaded) |
| `:checkhealth mcp` | Check plugin health                       |

## Custom tools

Custom tools are registered into the plugin's `mcp.ToolRegistry`:

```lua
local registry = require('mcp').registry()
registry:register({
  name = 'project_root',
  description = 'Print the current project root',
  handler = function(_) return { { type = 'text', text = vim.fn.getcwd() } } end,
})
```

Tool handlers can return:

- A list of `content` items (text, image, audio, embedded
  resource). Each item has `{ type = ..., ... }`.
- A single content item (the server wraps it into a list).
- A pre-shaped `tools/call` result table with `content` /
  `isError` fields.
- `nil, err_string` to surface a tool execution error (the
  server wraps it as `isError: true`).

The registry automatically emits
`notifications/tools/list_changed` whenever the tool set changes,
so clients re-discover tools on edit.

## Architecture

```
lua/mcp
  init.lua                 -- public entry point: setup(), start, stop
  health.lua               -- :checkhealth mcp
  server.lua               -- MCP protocol layer + lifecycle FSM
  tool_registry.lua        -- OOP tool registry, emits list_changed
  tools/lsp.lua            -- 7 built-in LSP tools
  json_rpc.lua             -- generic JSON-RPC 2.0 peer (port from PR #38525)
    message_stream.lua     -- framing layer (newline / Content-Length)
    transport/framing.lua  -- pure framing decoders
    transport/tcp.lua      -- vim.uv TCP client / server (skeleton)
    transport/http.lua     -- streamable-HTTP server (MCP transport)
```

The JSON-RPC layer is a self-contained port of Neovim's upstream
`vim.json.rpc` (PR #38525) so the plugin does not depend on
`vim._core.stringbuffer` or any other internal module. The
`Connection` is a symmetric peer: it both initiates requests and
responds to incoming ones, which is exactly what an MCP server
needs.

## License

MIT.
