## mcp.nvim

```lua
{
  'phanen/mcp.nvim',
  cmd = { 'McpStart', 'McpStop', 'McpRestart', 'McpPort', 'McpAttachOpencode' },
  config = function()
    require('mcp').setup({})

    require('mcp').register({ mod = 'mcp.tools.lsp.definition' })
    require('mcp').register({ mod = 'mcp.tools.lsp.references' })
    require('mcp').register({ mod = 'mcp.tools.lsp.hover' })
    require('mcp').register({ mod = 'mcp.tools.lsp.document_symbols' })
    require('mcp').register({ mod = 'mcp.tools.lsp.workspace_symbols' })
    require('mcp').register({ mod = 'mcp.tools.lsp.implementation' })
    require('mcp').register({ mod = 'mcp.tools.lsp.type_definition' })
    -- Skip lsp_rename: the model can edit text directly via the Edit tool.
    require('mcp').register({ mod = 'mcp.tools.nvim.diagnostics' })
    require('mcp').register({ mod = 'mcp.tools.nvim.quickfix' })

    -- Register a custom tool inline. The handler returns either a list
    -- of content items or `nil, err_message` for an `isError: true` result.
    require('mcp').register({
      name = 'nvim_echo',
      description = 'Echo `message` to Neovim\'s message area. Defaults to "hello world".',
      inputSchema = {
        type = 'object',
        properties = {
          message = { type = 'string', description = 'Text to display.' },
        },
      },
      handler = function(args)
        local msg = (args and args.message) or 'hello world'
        vim.api.nvim_echo({ { msg } }, false, {})
        return { { type = 'text', text = msg } }
      end,
    })
    -- require('mcp').attach_opencode()
  end,
},
{
  "sudo-tee/opencode.nvim",
  opts = {},
  config = function(_, opts)
    require('opencode').setup(opts)
    require('mcp').attach_opencode()
  end,
}
```

## Authoring a tool

A tool is a table with `name`, `description`, `handler`, and an optional
`inputSchema` (JSON Schema; `type = 'object'` is required). The handler
receives the validated arguments and returns either a list of MCP content
items or `nil, err_message` to surface `isError: true`.

Inline form (no module file needed):

```lua
require('mcp').register({
  name = 'nvim_echo',
  description = 'Echo a message to Neovim.',
  inputSchema = {
    type = 'object',
    properties = { message = { type = 'string' } },
  },
  handler = function(args)
    return { { type = 'text', text = args.message or '' } }
  end,
})
```

Module form — put the def in `lua/my_plugin/tools/foo.lua`:

```lua
-- lua/my_plugin/tools/foo.lua
return {
  name = 'foo',
  description = 'Do foo.',
  inputSchema = {
    type = 'object',
    properties = { name = { type = 'string' } },
    required = { 'name' },
  },
  handler = function(args)
    return { { type = 'text', text = 'foo: ' .. args.name } }
  end,
}
```

Register it:

```lua
require('mcp').register({ mod = 'my_plugin.tools.foo' })
```

Calling `register` again with the same `name` overrides the previous tool.

For module form, `register` also accepts a `(opts) -> ToolDef` factory —
handy when you want to thread runtime options through. Plain `ToolDef`
modules ignore `opts`.

## Credits

* https://modelcontextprotocol.io/specification/2025-03-26
* https://github.com/sst/opencode
* https://github.com/sudo-tee/opencode.nvim
* https://github.com/linw1995/nvim-mcp
* https://github.com/neovim/neovim/pull/38525
* https://github.com/lewis6991/nvim-test

## License

MIT.
