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

.PHONY: build build-local push all version clean update

# Build multi-arch images (pushes core to registry so step 2 can FROM it)
build:
	docker buildx build \
		$(CORE_BUILD_ARGS) \
		--platform $(PLATFORMS) \
		-f $(GOCLAW_DIR)/Dockerfile \
		-t $(CORE_TAG) \
		--push \
		$(GOCLAW_DIR)
	docker buildx build \
		--build-arg CORE_IMAGE=$(CORE_TAG) \
		--platform $(PLATFORMS) \
		-f Dockerfile \
		-t $(IMAGE):$(VERSION) \
		-t $(IMAGE):latest \
		.

# Build for local platform and load into Docker
build-local:
	docker buildx build \
		$(CORE_BUILD_ARGS) \
		--platform $(LOCAL_ARCH) \
		-f $(GOCLAW_DIR)/Dockerfile \
		-t $(CORE_TAG) \
		--load \
		$(GOCLAW_DIR)
	docker buildx build \
		--build-arg CORE_IMAGE=$(CORE_TAG) \
		--platform $(LOCAL_ARCH) \
		-f Dockerfile \
		-t $(IMAGE):$(VERSION) \
		-t $(IMAGE):latest \
		--load \
		.

# Build multi-arch and push to DockerHub
push:
	docker buildx build \
		$(CORE_BUILD_ARGS) \
		--platform $(PLATFORMS) \
		-f $(GOCLAW_DIR)/Dockerfile \
		-t $(CORE_TAG) \
		--push \
		$(GOCLAW_DIR)
	docker buildx build \
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

# Checkout goclaw-core at a specific tag and update compose files
# Usage: make update TAG=v2.50.0
update:
ifndef TAG
	$(error TAG is required. Usage: make update TAG=v2.50.0)
endif
	@echo "Checking out goclaw-core at $(TAG)..."
	cd $(GOCLAW_DIR) && git fetch --tags && git checkout $(TAG)
	@echo "Updating compose files to $(IMAGE):$(TAG)..."
	@for f in $(COMPOSE_PROD) $(COMPOSE_DOKPLOY); do \
		if [ -f "$$f" ]; then \
			sed -i 's|image: $(IMAGE):[^ ]*|image: $(IMAGE):$(TAG)|' "$$f"; \
			echo "  Updated $$f"; \
		fi; \
	done
	@echo "Done. goclaw-core=$(TAG), compose files updated."
	@echo "Next: make build-local  (or: make push)"

# Remove local images
clean:
	docker rmi $(CORE_TAG) $(IMAGE):$(VERSION) $(IMAGE):latest 2>/dev/null || true
