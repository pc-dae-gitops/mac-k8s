IMAGE     ?= paulcarltondae/debug-pod
TAG       ?= 0.1.0
PLATFORMS ?= linux/amd64,linux/arm64
BUILDER   ?= debug-pod-builder
KIND_CLUSTER ?= kind

.DEFAULT_GOAL := help

.PHONY: help build kind-load push builder login clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

build: ## Build for the local platform into docker (usable by Docker Desktop Kubernetes)
	docker buildx build --load --provenance=false \
		-t $(IMAGE):$(TAG) -t $(IMAGE):latest .

kind-load: build ## Build and load into kind cluster $(KIND_CLUSTER), without pushing
	kind load docker-image --name $(KIND_CLUSTER) $(IMAGE):$(TAG)

builder: ## Create the multi-platform buildx builder if missing
	@docker buildx inspect $(BUILDER) >/dev/null 2>&1 || \
		docker buildx create --name $(BUILDER) --driver docker-container

login: ## Log in to Docker Hub (uses DOCKERHUB_USER/DOCKERHUB_TOKEN if set)
	@if [ -n "$$DOCKERHUB_TOKEN" ]; then \
		echo "$$DOCKERHUB_TOKEN" | docker login -u "$$DOCKERHUB_USER" --password-stdin; \
	else \
		docker login; \
	fi

push: builder ## Build for $(PLATFORMS) and push to Docker Hub (needed for CRC and EKS)
	docker buildx build --builder $(BUILDER) --platform $(PLATFORMS) --push \
		-t $(IMAGE):$(TAG) -t $(IMAGE):latest .

clean: ## Remove the buildx builder and local image
	-docker buildx rm $(BUILDER)
	-docker image rm $(IMAGE):$(TAG) $(IMAGE):latest
