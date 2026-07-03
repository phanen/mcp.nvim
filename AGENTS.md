# Repository Guidelines

## Layout
- `lua/mcp/` — modules. Public entry in `init.lua`; lower-level pieces in `json_rpc/`, `server.lua`, `tool_registry.lua`, `transport/`, `tools/`, `util/`.
- `lua/mcp/tools/{lsp,nvim}/_shared.lua` — helpers shared by per-tool modules; not tools, never register them.
- `plugin/mcp.lua` — user-facing `:Mcp*` commands only.
- `test/` — busted specs via nvim-test; shared setup in `test/helpers.lua`.
- `specs/` — MCP protocol reference docs (not test code).
- `deps/` — vendored tooling (stylua, nvim-test, emmylua).

## Build and Test
- `make build` — stylua `lua/` and `test/`, then `gen_help` to refresh `:help`.
- `make test [FILTER=pat]` — functional suite on the default Neovim runner.
- `make test-010 | test-011 | test-012 | test-nightly` — version matrix.
- `make doc` / `make doc-check` — regenerate `:help` from annotations; fail on drift.
- `make format` / `make format-check` — apply or lint stylua.
- `make emmylua-check` — static analysis pass.

## Style
- EmmyLua / LuaCATS annotations on every public symbol.
- 2-space indent, 100-col lines, single quotes.
- Comments are the exception, not the default. Only add one when the code
  itself cannot carry the intent (footgun, non-obvious invariant, external
  contract). Strip restate-the-code prose when reviewing.

## Testing
- Sandbox cannot use `/tmp`; create scratch files in cwd.
- Add or update tests for risky, non-obvious, or broad changes.
- Handlers return either a content list, or `nil, err_message`. The
  `tools/call` envelope wraps that — keep handler tests focused on the
  inner return shape.

## Commits and PRs
- Subject format: `<type>(<scope>): <verb phrase>`.
- Body lines wrap at 72; describe problem and solution.
- `make build`, the relevant `make test-*`, and `make doc-check` must pass.
- A failed required check is blocking unless explicitly overridden.
