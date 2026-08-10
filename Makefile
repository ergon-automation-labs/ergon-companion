SCRIPTS_DIRECTORY ?= $(abspath $(CURDIR)/../scripts)
MIX ?= /Users/abby/.local/share/mise/shims/mix

.PHONY: setup help deps compile test test-handlers test-stores test-nats test-integration test-full credo dialyzer coverage check format clean release test-release-smoke publish-release setup-hooks setup-db reset-db logs git-push push pre-push-cleanup push-and-publish bump-version sync-release-version

help:
	@echo "Companion Bot"
	@echo ""
	@echo "Setup commands:"
	@echo "  make setup           - Set up project (deps.get + install git hooks + setup database)"
	@echo "  make setup-hooks     - Install git hooks for pre-push validation"
	@echo "  make setup-db        - Create and migrate test database (required for testing)"
	@echo "  make reset-db        - Drop and recreate test database (useful for troubleshooting)"
	@echo ""
	@echo "Development commands:"
	@echo "  make test            - Run all tests"
	@echo "  make credo           - Run linter"
	@echo "  make dialyzer        - Run static analysis"
	@echo "  make coverage        - Run tests with coverage"
	@echo "  make check           - Run all checks (test, credo, dialyzer)"
	@echo "  make format          - Format Elixir code"
	@echo "  make clean           - Clean build artifacts"
	@echo ""
	@echo "Operations (deployed server logs):"
	@echo "  make logs            - Tail server log with grc (auto-detected by repo name; make -C .. install-grc)"
	@echo ""
	@echo "Release commands:"
	@echo "  make release         - Build OTP release locally"
	@echo "  make publish-release - Build, package, and publish to GitHub"
	@echo ""
	@echo "Normal workflow:"
	@echo "  git push             - Fast compile+test validation"
	@echo "  make push-and-publish - Push then publish release asset"
	@echo ""

setup: init deps setup-hooks setup-db
	@echo "✓ Setup complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Configure .env with your database settings (if needed)"
	@echo "  2. Run: make test"
	@echo "  3. Start developing!"
	@echo ""

setup-hooks:
	@git config core.hooksPath git-hooks
	@echo "✓ Git hooks installed (core.hooksPath = git-hooks)"

setup-db:
	@echo "Setting up test database..."
	@MIX_ENV=test $(MIX) ecto.create || true
	@MIX_ENV=test $(MIX) ecto.migrate
	@echo "✓ Test database created and migrations applied"

reset-db:
	@echo "⚠️  Resetting test database (dropping and recreating)..."
	@MIX_ENV=test $(MIX) ecto.drop || true
	@MIX_ENV=test $(MIX) ecto.create
	@MIX_ENV=test $(MIX) ecto.migrate
	@echo "✓ Test database reset complete"

init:
	@if [ ! -d .git ]; then git init; echo "Git initialized."; else echo "Git already initialized."; fi

deps:
	$(MIX) deps.get

compile:
	@LOG_FILE="/tmp/compile-companion-$$(date +%s).log"; \
	echo "Compiling Companion and logging to $$LOG_FILE..."; \
	$(MIX) compile 2>&1 | tee "$$LOG_FILE"; \
	echo "✓ Compilation log: $$LOG_FILE"

test:
	@BOT_NAME=companion; \
	LOG_FILE="/tmp/test-$${BOT_NAME}-$$(date +%s).log"; \
	echo "Running tests and logging to $$LOG_FILE..."; \
	$(MIX) test 2>&1 | tee "$$LOG_FILE"; \
	echo "✓ Test log: $$LOG_FILE"

test-handlers:
	MIX_ENV=test $(MIX) test --only handlers --trace

test-stores:
	MIX_ENV=test $(MIX) test --only stores --trace

test-nats:
	MIX_ENV=test $(MIX) test --only nats --trace

test-integration:
	$(MIX) test --include integration --trace

test-full:
	$(MIX) test --include integration --include nats_live --trace

credo:
	@BOT_NAME=companion; \
	LOG_FILE="/tmp/credo-$${BOT_NAME}-$$(date +%s).log"; \
	echo "Running credo and logging to $$LOG_FILE..."; \
	$(MIX) credo 2>&1 | tee "$$LOG_FILE"; \
	echo "✓ Credo log: $$LOG_FILE"

dialyzer: deps
	$(MIX) dialyzer

coverage:
	$(MIX) coveralls

check: test credo
	@echo "All checks passed!"

format:
	$(MIX) format

clean:
	$(MIX) clean
	rm -rf _build cover

release: check
	@echo "==============================================="
	@echo "Building OTP release"
	@echo "==============================================="
	rm -rf _build/prod/rel/companion_bot
	MIX_ENV=prod $(MIX) release
	@echo ""
	@echo "✓ Release built successfully"
	@echo "Location: _build/prod/rel/companion_bot/"
	@echo ""

test-release-smoke:
	@echo "==============================================="
	@echo "Running release smoke test"
	@echo "==============================================="
	@RELEASE_NAME=companion_bot NATS_SERVERS=nats://localhost:4224 \
		bash $(SCRIPTS_DIRECTORY)/test_release_smoke.sh

sync-release-version:
	@VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then \
		echo "❌ Failed to resolve version from mix.exs"; exit 1; \
	fi; \
	TIMESTAMP=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); \
	echo "$$VERSION" > .release-published; \
	echo "✅ Synced release version: v$$VERSION ($$TIMESTAMP)"

publish-release: release
	@if ! git rev-parse --git-dir > /dev/null 2>&1; then \
		echo "❌ Not a git repository"; \
		exit 1; \
	fi; \
	if ! git config --get remote.origin.url | grep -q "ergon-automation-labs"; then \
		echo "⚠️  Warning: Remote is not from ergon-automation-labs"; \
		echo "   Remote: $$(git config --get remote.origin.url)"; \
	fi
	@echo "==============================================="
	@echo "Publishing release to GitHub"
	@echo "==============================================="
	@echo ""
	@echo "Repo: $$(basename $$(pwd))"
	@echo "Branch: $$(git rev-parse --abbrev-ref HEAD)"
	@echo ""

	@set -e; \
	VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then \
		echo "Failed to resolve version from mix.exs"; \
		exit 1; \
	fi; \
	TARBALL="companion_bot-$$VERSION.tar.gz"; \
	echo "Version: $$VERSION"; \
	echo "Creating release tarball..."; \
	tar -czf "$$TARBALL" -C _build/prod/rel companion_bot/; \
	echo "✓ Tarball created: $$TARBALL"; \
	echo ""; \
	echo "Creating GitHub release v$$VERSION..."; \
	if gh release view "v$$VERSION" >/dev/null 2>&1; then \
		gh release upload "v$$VERSION" "$$TARBALL" --clobber; \
	else \
		gh release create "v$$VERSION" "$$TARBALL" \
			--title "Release v$$VERSION" \
			--notes "Companion Bot Elixir release v$$VERSION. Download and deploy with Jenkins." \
			--draft=false; \
	fi; \
	echo "✓ Release published to GitHub"; \
	echo ""; \
	echo "Writing release marker..."; \
	echo "$$VERSION $$(date -u +%s)" > .release-published; \
	echo "✓ Release marker written"; \
	echo ""; \
	echo "Publishing deploy.release.requested to NATS..."; \
	BOT_SHORT=$$(echo "companion_bot" | sed 's/_bot$$//'); \
	REPO_SLUG=$$(git config --get remote.origin.url | sed -E 's#.*[:/]([^/]+/[^/]+)\.git#\1#'); \
	MONOREPO_ROOT=$$($(call _FIND_MONOREPO_ROOT)); \
	NATS_PUBLISH_SCRIPT="$$MONOREPO_ROOT/bot_army_infra/salt/common/files/nats_publish.sh"; \
	if [ -n "$$MONOREPO_ROOT" ] && [ -f "$$NATS_PUBLISH_SCRIPT" ]; then \
		PAYLOAD=$$(printf '{"bot":"%s","repo":"%s","tag":"v%s","version":"%s"}' "$$BOT_SHORT" "$$REPO_SLUG" "$$VERSION" "$$VERSION"); \
		bash "$$NATS_PUBLISH_SCRIPT" deploy.release.requested "$$PAYLOAD" || echo "⚠️  NATS publish failed (non-fatal — deploy via make deploy-bot or Jenkins instead)"; \
	else \
		echo "⚠️  nats_publish.sh not found (monorepo root: $${MONOREPO_ROOT:-not found}) — skipping deploy.release.requested"; \
	fi; \
	echo ""; \
	echo "Next steps:"; \
	echo "1. If this bot's ci_engine is 'nats' (pillar/common.sls in bot_army_infra), deploy_pipeline_bot deploys it automatically."; \
	echo "2. Otherwise: make deploy-bot, or wait for Jenkins polling"; \
	echo "3. Check status: make jenkins-logs (Jenkins) or watch ops.deploy.* on NATS (deploy_pipeline_bot path)"

pre-push-cleanup:
	@echo "🧹 Cleaning up pre-push artifacts..."
	@if git diff --quiet git-hooks/pre-push 2>/dev/null; then \
		echo "✓ No hook changes"; \
	else \
		echo "📋 Staging hook changes..."; \
		git add git-hooks/pre-push 2>/dev/null; \
		git commit -m "chore: sync pre-push hook" || true; \
	fi
	@if git diff --quiet mix.lock 2>/dev/null; then \
		echo "✓ No lock file changes"; \
	else \
		echo "📋 Staging lock file changes..."; \
		git add mix.lock 2>/dev/null; \
		git commit -m "chore: lock file updates from pre-push validation" || true; \
	fi
	@echo "✓ Ready to push"

push: test compile credo pre-push-cleanup
	@echo "✅ All validations passed"
	@echo "$$(date +%s)" > .push-validated
	@echo "✓ Proof-of-validation created"
	@$(MAKE) git-push

git-push: pre-push-cleanup
	@BOT_NAME=companion; \
	LOG_FILE="/tmp/git-push-$${BOT_NAME}-$$(date +%s).log"; \
	echo "Pushing to origin/main and logging to $$LOG_FILE..."; \
	git push 2>&1 | tee "$$LOG_FILE"; \
	echo "✓ Log saved: $$LOG_FILE"

bump-version:
	@if [ -z "$(BUMP)" ]; then \
		echo "Usage: make bump-version BUMP=major|minor|patch"; \
		exit 1; \
	fi
	@CURRENT_VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$CURRENT_VERSION" ]; then \
		echo "Failed to read current version from mix.exs"; \
		exit 1; \
	fi; \
	IFS='.' read -r MAJOR MINOR PATCH <<< "$$CURRENT_VERSION"; \
	case "$(BUMP)" in \
		major) NEW_VERSION="$$((MAJOR + 1)).0.0" ;; \
		minor) NEW_VERSION="$$MAJOR.$$((MINOR + 1)).0" ;; \
		patch) NEW_VERSION="$$MAJOR.$$MINOR.$$((PATCH + 1))" ;; \
		*) echo "Invalid BUMP: $(BUMP). Use major|minor|patch"; exit 1 ;; \
	esac; \
	sed -i '' "s/version: \"$$CURRENT_VERSION\"/version: \"$$NEW_VERSION\"/" mix.exs; \
	git add mix.exs; \
	git commit -m "chore: bump companion to $$NEW_VERSION"; \
	echo "✓ Bumped $$CURRENT_VERSION → $$NEW_VERSION"

push-and-publish: git-push publish-release

logs:
	@$(SCRIPTS_DIRECTORY)/tail_bot_log.sh

# Deployment targets that delegate to monorepo
.PHONY: deploy-bot verify-bot verify-bot-nats

_FIND_MONOREPO_ROOT = \
	if [ -n "$(MONOREPO_ROOT)" ]; then \
		echo "$(MONOREPO_ROOT)"; \
		exit 0; \
	fi; \
	if [ -d "../../../elixir_bots" ] && [ -f "../../../elixir_bots/Makefile" ]; then \
		if grep -q "verify-bot-nats:" "../../../elixir_bots/Makefile"; then \
			echo "$$(cd ../../../elixir_bots && pwd)"; \
			exit 0; \
		fi; \
	fi; \
	CURRENT_DIR=$$(pwd); \
	while [ "$$CURRENT_DIR" != "/" ]; do \
		if [ -f "$$CURRENT_DIR/Makefile" ] && grep -q "verify-bot-nats:" "$$CURRENT_DIR/Makefile"; then \
			if [ -d "$$CURRENT_DIR/bots" ] || [ -d "$$CURRENT_DIR/bot_army_infra" ]; then \
				echo "$$CURRENT_DIR"; \
				exit 0; \
			fi; \
		fi; \
		CURRENT_DIR=$$(dirname "$$CURRENT_DIR"); \
	done; \
	echo ""; \
	exit 1

deploy-bot:
	@MONOREPO_ROOT=$$($(call _FIND_MONOREPO_ROOT)) || { \
		echo "❌ Could not find monorepo root"; \
		echo "   Expected to find Makefile with 'deploy-bot' target"; \
		echo "   Current directory: $$(pwd)"; \
		exit 1; \
	}; \
	BOT_NAME=$$(basename $$(pwd) | sed 's/bot_army_//'); \
	echo "Deploying from: $$(pwd)"; \
	echo "Bot name: $${BOT_NAME}"; \
	echo "Monorepo root: $$MONOREPO_ROOT"; \
	echo ""; \
	$(MAKE) -C "$$MONOREPO_ROOT" deploy-bot BOT=$${BOT_NAME}

verify-bot:
	@MONOREPO_ROOT=$$($(call _FIND_MONOREPO_ROOT)) || { \
		echo "❌ Could not find monorepo root"; \
		exit 1; \
	}; \
	BOT_NAME=$$(basename $$(pwd) | sed 's/bot_army_//'); \
	$(MAKE) -C "$$MONOREPO_ROOT" verify-bot BOT=$${BOT_NAME}

verify-bot-nats:
	@MONOREPO_ROOT=$$($(call _FIND_MONOREPO_ROOT)) || { \
		echo "❌ Could not find monorepo root"; \
		exit 1; \
	}; \
	BOT_NAME=$$(basename $$(pwd) | sed 's/bot_army_//'); \
	$(MAKE) -C "$$MONOREPO_ROOT" verify-bot-nats BOT=$${BOT_NAME}

# Deployment targets that delegate to monorepo
.PHONY: deploy-bot verify-bot verify-bot-nats

_FIND_MONOREPO_ROOT = \
	if [ -n "$(MONOREPO_ROOT)" ]; then \
		echo "$(MONOREPO_ROOT)"; \
		exit 0; \
	fi; \
	if [ -d "../../../elixir_bots" ] && [ -f "../../../elixir_bots/Makefile" ]; then \
		if grep -q "verify-bot-nats:" "../../../elixir_bots/Makefile"; then \
			echo "$$(cd ../../../elixir_bots && pwd)"; \
			exit 0; \
		fi; \
	fi; \
	CURRENT_DIR=$$(pwd); \
	while [ "$$CURRENT_DIR" != "/" ]; do \
		if [ -f "$$CURRENT_DIR/Makefile" ] && grep -q "verify-bot-nats:" "$$CURRENT_DIR/Makefile"; then \
			if [ -d "$$CURRENT_DIR/bots" ] || [ -d "$$CURRENT_DIR/bot_army_infra" ]; then \
				echo "$$CURRENT_DIR"; \
				exit 0; \
			fi; \
		fi; \
		CURRENT_DIR=$$(dirname "$$CURRENT_DIR"); \
	done; \
	echo ""; \
	exit 1

deploy-bot:
	@MONOREPO_ROOT=$$($(call _FIND_MONOREPO_ROOT)) || { \
		echo "❌ Could not find monorepo root"; \
		echo "   Expected to find Makefile with 'deploy-bot' target"; \
		echo "   Current directory: $$(pwd)"; \
		exit 1; \
	}; \
	DIR_NAME=$$(basename $$(pwd)); \
	echo "Deploying from: $$(pwd)"; \
	echo "Directory: $$DIR_NAME"; \
	echo "Monorepo root: $$MONOREPO_ROOT"; \
	echo ""; \
	$(MAKE) -C "$$MONOREPO_ROOT" deploy-bot BOT=$$DIR_NAME TARGET=mini

verify-bot:
	@MONOREPO_ROOT=$$($(call _FIND_MONOREPO_ROOT)) || { \
		echo "❌ Could not find monorepo root"; \
		exit 1; \
	}; \
	BOT_NAME=$$(basename $$(pwd) | sed 's/bot_army_//'); \
	$(MAKE) -C "$$MONOREPO_ROOT" verify-bot BOT=$$BOT_NAME

verify-bot-nats:
	@MONOREPO_ROOT=$$($(call _FIND_MONOREPO_ROOT)) || { \
		echo "❌ Could not find monorepo root"; \
		exit 1; \
	}; \
	BOT_NAME=$$(basename $$(pwd) | sed 's/bot_army_//'); \
	$(MAKE) -C "$$MONOREPO_ROOT" verify-bot-nats BOT=$$BOT_NAME
