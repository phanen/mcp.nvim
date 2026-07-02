## mcp.nvim

```lua
{
  'phanen/mcp.nvim',
  cmd = { 'McpStart', 'McpStop', 'McpRestart', 'McpPort', 'McpAttachOpencode' },
  config = function()
    require('mcp').setup({})
    require('mcp.tools.lsp').register_all(require('mcp').registry())
    require('mcp').attach_opencode()
  end,
}
```

## Credits

* https://modelcontextprotocol.io/specification/2025-03-26
* https://github.com/sst/opencode
* https://github.com/sudo-tee/opencode.nvim
* https://github.com/linw1995/nvim-mcp
* https://github.com/neovim/neovim/pull/38525
* https://github.com/lewis6991/nvim-test

## License

MIT.
