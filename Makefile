.DEFAULT_GOAL := help
APP_BUNDLE ?= .build/Afterword.app

export UV_CACHE_DIR := $(CURDIR)/.cache/uv
export CLANG_MODULE_CACHE_PATH := $(CURDIR)/.cache/clang
export SWIFTPM_MODULECACHE_OVERRIDE := $(CURDIR)/.cache/clang

.PHONY: help setup build run check swift-test worker-check worker-test model-setup model-inspect lint
.NOTPARALLEL: check

help:
	@printf '%s\n' 'make setup        Create the pinned Python inference environment' 'make build        Build and ad-hoc sign the macOS app' 'make run          Build and open the app bundle' 'make check        Build, run Swift/Python tests, verify the bundle, and lint docs' 'make model-setup  Build pinned runtimes and download public models (about 5.56 GB)' 'make model-inspect Check local runtime paths without downloading' 'Community-1 setup after accepting its terms and configuring Hugging Face access:' '  worker/.venv/bin/python scripts/setup-models.py gated --terms-already-accepted'

setup:
	cd worker && uv sync --locked

build:
	bash scripts/build-app.sh "$(APP_BUNDLE)"

run: build
	open "$(APP_BUNDLE)"

worker-check: setup
	cd worker && uv run --locked python -m afterword_worker --version

swift-test:
	swift test --cache-path "$(CURDIR)/.cache/swiftpm"

worker-test: setup
	cd worker && uv run --locked python -m unittest discover -s tests -v

model-setup:
	python3 scripts/setup-models.py public

model-inspect:
	python3 scripts/setup-models.py inspect

lint:
	markdownlint HIGH_LEVEL_DESIGN.md V1_IMPLEMENTATION.md

check: build swift-test worker-check worker-test lint
	plutil -lint "$(APP_BUNDLE)/Contents/Info.plist"
	codesign --verify --strict "$(APP_BUNDLE)"
