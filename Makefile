.PHONY: build release test test-unit test-e2e test-parallel test-visible clean

# Build
build:
	cd yacd && zig build

release:
	cd yacd && zig build -Doptimize=ReleaseSafe

# Unit tests (Zig)
test-unit:
	cd yacd && zig build test

# E2E tests (sequential, default)
test-e2e: release
	uv run pytest tests/

# E2E tests (parallel)
test-parallel: release
	uv run pytest tests/ -n auto --maxprocesses=38

# E2E tests (visible — watch in terminal)
test-visible: release
	uv run pytest tests/ --visible

# All tests
test: test-unit test-e2e

clean:
	cd yacd && rm -rf zig-out .zig-cache
