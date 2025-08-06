# Hugo Blog Makefile
# Common commands for developing and building the blog

# Default target
.PHONY: help
help: ## Show this help message
	@echo "Available commands:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# Hugo server configuration
HUGO_PORT ?= 1313
HUGO_BIND ?= 0.0.0.0
HUGO_ENV ?= development

# Hugo executable (try to find it in PATH or common locations)
HUGO := $(shell which hugo 2>/dev/null || echo "hugo")

.PHONY: check-hugo
check-hugo: ## Check if Hugo is installed
	@if [ -z "$(HUGO)" ] || [ "$(HUGO)" = "hugo" ]; then \
		echo "Error: Hugo is not installed or not found in PATH"; \
		echo "Please install Hugo: https://gohugo.io/installation/"; \
		exit 1; \
	fi
	@echo "Hugo found at: $(HUGO)"

.PHONY: server
server: check-hugo ## Start Hugo development server
	@echo "Starting Hugo server on http://localhost:$(HUGO_PORT)"
	@echo "Press Ctrl+C to stop the server"
	$(HUGO) server \
		--port $(HUGO_PORT) \
		--bind $(HUGO_BIND) \
		--environment $(HUGO_ENV) \
		--disableFastRender \
		--noHTTPCache \
		--gc

.PHONY: server-draft
server-draft: check-hugo ## Start Hugo server with draft content
	@echo "Starting Hugo server with draft content on http://localhost:$(HUGO_PORT)"
	@echo "Press Ctrl+C to stop the server"
	$(HUGO) server \
		--port $(HUGO_PORT) \
		--bind $(HUGO_BIND) \
		--environment $(HUGO_ENV) \
		--buildDrafts \
		--buildFuture \
		--disableFastRender \
		--noHTTPCache \
		--gc

.PHONY: build
build: check-hugo ## Build the site for production
	@echo "Building site for production..."
	$(HUGO) --gc --minify

.PHONY: build-draft
build-draft: check-hugo ## Build the site including drafts
	@echo "Building site with drafts..."
	$(HUGO) --buildDrafts --buildFuture --gc --minify

.PHONY: clean
clean: ## Clean generated files
	@echo "Cleaning generated files..."
	@rm -rf public/
	@rm -rf resources/
	@rm -rf .hugo_build.lock
	@echo "Clean complete!"

.PHONY: new-post
new-post: check-hugo ## Create a new blog post (usage: make new-post POST_NAME="my-post-title")
	@if [ -z "$(POST_NAME)" ]; then \
		echo "Error: POST_NAME is required"; \
		echo "Usage: make new-post POST_NAME=\"my-post-title\""; \
		exit 1; \
	fi
	@echo "Creating new post: $(POST_NAME)"
	$(HUGO) new posts/$(POST_NAME).md

.PHONY: new-page
new-page: check-hugo ## Create a new page (usage: make new-page PAGE_NAME="my-page")
	@if [ -z "$(PAGE_NAME)" ]; then \
		echo "Error: PAGE_NAME is required"; \
		echo "Usage: make new-page PAGE_NAME=\"my-page\""; \
		exit 1; \
	fi
	@echo "Creating new page: $(PAGE_NAME)"
	$(HUGO) new pages/$(PAGE_NAME).md

.PHONY: check
check: check-hugo ## Check Hugo configuration and content
	@echo "Checking Hugo configuration..."
	$(HUGO) check
	@echo "Configuration check complete!"

.PHONY: install-theme
install-theme: ## Install/update the Hugo theme
	@echo "Installing/updating Hugo theme..."
	git submodule update --init --recursive
	@echo "Theme installation complete!"

.PHONY: update-theme
update-theme: ## Update the Hugo theme to latest version
	@echo "Updating Hugo theme..."
	git submodule update --remote --merge
	@echo "Theme update complete!"

.PHONY: format
format: ## Format content files (requires prettier)
	@if command -v prettier >/dev/null 2>&1; then \
		echo "Formatting content files..."; \
		prettier --write "content/**/*.md"; \
		echo "Formatting complete!"; \
	else \
		echo "Prettier not found. Install with: npm install -g prettier"; \
		exit 1; \
	fi

.PHONY: lint
lint: ## Lint content files (requires markdownlint)
	@if command -v markdownlint >/dev/null 2>&1; then \
		echo "Linting content files..."; \
		markdownlint "content/**/*.md"; \
		echo "Linting complete!"; \
	else \
		echo "markdownlint not found. Install with: npm install -g markdownlint-cli"; \
		exit 1; \
	fi

.PHONY: dev
dev: server ## Alias for server (default development command)

.PHONY: serve
serve: server ## Alias for server

# Default target
.DEFAULT_GOAL := help 