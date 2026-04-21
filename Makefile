GOCLAW_DIR ?= ./goclaw-core
IMAGE      ?= itsddvn/goclaw
VERSION    ?= $(shell cd $(GOCLAW_DIR) && git describe --tags --match "v[0-9]*" --always 2>/dev/null || echo dev)
PLATFORMS  ?= linux/amd64,linux/arm64
LOCAL_ARCH ?= linux/$(shell uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
CORE_TAG    = $(IMAGE):$(VERSION)-core

# Optional feature flags (passed to core image build)
ENABLE_OTEL        ?= false
ENABLE_TSNET       ?= false
ENABLE_REDIS       ?= false
ENABLE_SANDBOX     ?= false
ENABLE_PYTHON      ?= false
ENABLE_NODE        ?= false
ENABLE_FULL_SKILLS ?= true
ENABLE_CLAUDE_CLI  ?= false

CORE_BUILD_ARGS = \
	--build-arg VERSION=$(VERSION) \
	--build-arg ENABLE_OTEL=$(ENABLE_OTEL) \
	--build-arg ENABLE_TSNET=$(ENABLE_TSNET) \
	--build-arg ENABLE_REDIS=$(ENABLE_REDIS) \
	--build-arg ENABLE_SANDBOX=$(ENABLE_SANDBOX) \
	--build-arg ENABLE_PYTHON=$(ENABLE_PYTHON) \
	--build-arg ENABLE_NODE=$(ENABLE_NODE) \
	--build-arg ENABLE_FULL_SKILLS=$(ENABLE_FULL_SKILLS) \
	--build-arg ENABLE_CLAUDE_CLI=$(ENABLE_CLAUDE_CLI)

COMPOSE_PROD    ?= docker-compose.yml
COMPOSE_DOKPLOY ?= docker-compose-dokploy.yml
BUILDER_NAME    ?= goclaw-multiarch

.PHONY: build build-local push all version clean update ensure-builder

# Create a docker-container builder for multi-arch builds + register QEMU
ensure-builder:
	@docker run --rm --privileged multiarch/qemu-user-static --reset -p yes >/dev/null 2>&1 || true
	@docker buildx inspect $(BUILDER_NAME) >/dev/null 2>&1 \
		|| docker buildx create --name $(BUILDER_NAME) --driver docker-container --use --bootstrap

# Build multi-arch images (pushes core to registry so step 2 can FROM it)
build: ensure-builder
	docker buildx build \
		--builder $(BUILDER_NAME) \
		$(CORE_BUILD_ARGS) \
		--platform $(PLATFORMS) \
		-f $(GOCLAW_DIR)/Dockerfile \
		-t $(CORE_TAG) \
		--push \
		$(GOCLAW_DIR)
	docker buildx build \
		--builder $(BUILDER_NAME) \
		--build-arg CORE_IMAGE=$(CORE_TAG) \
		--platform $(PLATFORMS) \
		-f Dockerfile \
		-t $(IMAGE):$(VERSION) \
		-t $(IMAGE):latest \
		.

# Build for local platform and load into Docker
build-local:
	docker buildx build \
		--builder default \
		$(CORE_BUILD_ARGS) \
		--platform $(LOCAL_ARCH) \
		-f $(GOCLAW_DIR)/Dockerfile \
		-t $(CORE_TAG) \
		--load \
		$(GOCLAW_DIR)
	docker buildx build \
		--builder default \
		--build-arg CORE_IMAGE=$(CORE_TAG) \
		--platform $(LOCAL_ARCH) \
		-f Dockerfile \
		-t $(IMAGE):$(VERSION) \
		-t $(IMAGE):latest \
		--load \
		.

# Build multi-arch and push to DockerHub
push: ensure-builder
	docker buildx build \
		--builder $(BUILDER_NAME) \
		$(CORE_BUILD_ARGS) \
		--platform $(PLATFORMS) \
		-f $(GOCLAW_DIR)/Dockerfile \
		-t $(CORE_TAG) \
		--push \
		$(GOCLAW_DIR)
	docker buildx build \
		--builder $(BUILDER_NAME) \
		--build-arg CORE_IMAGE=$(CORE_TAG) \
		--platform $(PLATFORMS) \
		-f Dockerfile \
		-t $(IMAGE):$(VERSION) \
		-t $(IMAGE):latest \
		--push \
		.

# Build + push
all: push

# Show version
version:
	@echo $(VERSION)

# Update goclaw-core submodule
# Usage: make update          — pull latest tag
#        make update TAG=v2.50.0 — checkout specific tag
update:
	@cd $(GOCLAW_DIR) && git fetch --tags
	$(eval RESOLVED_TAG := $(if $(TAG),$(TAG),$(shell cd $(GOCLAW_DIR) && git tag --sort=-v:refname --list 'v[0-9]*' | head -n1)))
	@if [ -z "$(RESOLVED_TAG)" ]; then echo "Error: no tags found in $(GOCLAW_DIR)"; exit 1; fi
	@echo "Checking out goclaw-core at $(RESOLVED_TAG)..."
	cd $(GOCLAW_DIR) && git checkout $(RESOLVED_TAG)
	@echo "Updating compose files to $(IMAGE):$(RESOLVED_TAG)..."
	@for f in $(COMPOSE_PROD) $(COMPOSE_DOKPLOY); do \
		if [ -f "$$f" ]; then \
			sed -i 's|image: $(IMAGE):[^ ]*|image: $(IMAGE):$(RESOLVED_TAG)|' "$$f"; \
			echo "  Updated $$f"; \
		fi; \
	done
	@echo "Done. goclaw-core=$(RESOLVED_TAG), compose files updated."
	@echo "Next: make build-local  (or: make push)"

# Remove local images
clean:
	docker rmi $(CORE_TAG) $(IMAGE):$(VERSION) $(IMAGE):latest 2>/dev/null || true
