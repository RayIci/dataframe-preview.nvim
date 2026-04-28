.DEFAULT_GOAL := help
.PHONY: help test format format-check lint build-ui ui-dev ui-typecheck \
        install-hooks clean ci

PLENARY     := $(HOME)/.local/share/nvim/lazy/plenary.nvim
LUA_DIRS    := lua/ tests/
NVIM        := nvim --headless -u tests/minimal_init.lua

# ── Help ──────────────────────────────────────────────────────────────────────

help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} \
	      /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# ── Lua ───────────────────────────────────────────────────────────────────────

test: ## Run the full Lua test suite (requires plenary.nvim)
	$(NVIM) \
	  -c "lua require('plenary.test_harness').test_directory('tests/', { minimal_init = 'tests/minimal_init.lua' })" \
	  -c "qa!"

format: ## Format all Lua files with StyLua
	@command -v stylua >/dev/null 2>&1 || \
	  { echo "stylua not found — install: cargo install stylua"; exit 1; }
	stylua $(LUA_DIRS)

format-check: ## Check Lua formatting without modifying files (used in CI/pre-commit)
	@command -v stylua >/dev/null 2>&1 || \
	  { echo "stylua not found — install: cargo install stylua"; exit 1; }
	stylua --check $(LUA_DIRS)

lint: ## Lint Lua files with luacheck
	@command -v luacheck >/dev/null 2>&1 || \
	  { echo "luacheck not found — install: luarocks install luacheck"; exit 1; }
	luacheck $(LUA_DIRS) --globals vim bit --no-unused-args

# ── Frontend ──────────────────────────────────────────────────────────────────

build-ui: ## Install bun deps and build the frontend to ui/dist/index.html
	cd ui && bun install && bun run build

ui-dev: ## Start the Vite dev server for frontend development
	cd ui && bun run dev

ui-typecheck: ## Run TypeScript type checking without emitting files
	cd ui && bunx tsc --noEmit

# ── Git hooks ─────────────────────────────────────────────────────────────────

install-hooks: ## Install git pre-commit hook from scripts/pre-commit
	cp scripts/pre-commit .git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit
	@echo "✓ Pre-commit hook installed"

# ── CI / composite ────────────────────────────────────────────────────────────

ci: format-check lint test ui-typecheck ## Run all checks (format-check + lint + test + ui-typecheck)

# ── Cleanup ───────────────────────────────────────────────────────────────────

clean: ## Remove build artifacts
	rm -rf ui/dist ui/.vite ui/node_modules/.cache
	@echo "✓ Cleaned build artifacts"
