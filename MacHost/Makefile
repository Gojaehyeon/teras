# Tandem macOS host.
CONFIG ?= Debug
DERIVED := build

.PHONY: all generate build release test run clean

all: build

generate:
	@DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" xcodegen generate

build: ## xcodegen + debug build into ./build
	@scripts/build.sh Debug build

release:
	@scripts/build.sh Release build

test:
	@scripts/build.sh Debug test

run: build
	@open "$(DERIVED)/Build/Products/Debug/Tandem.app"

clean:
	@scripts/build.sh Debug clean
	@rm -rf $(DERIVED) Tandem.xcodeproj
