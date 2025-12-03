REPO_ROOT := $(shell git rev-parse --show-toplevel)
RELEASE := $(shell cat $(HOME)/.my-docker-images.release)
DOCKER_REPO := ronkitay
DOCKER_HUB_USERNAME := $(shell cat $(REPO_ROOT)/flink-env/.dockerhub_username)

# define docker_login
# 	docker login --username $(DOCKER_HUB_USERNAME) --password-stdin < $(REPO_ROOT)/flink-env/.dockerhub_password
# endef

define make_image
	echo   "##########################################################"
	printf "###########  Making image %-15s  ###############\n" "${1}"
	echo ""

	echo "Running command [docker build $(EXTRA_BUILD_ARGS) --build-arg RELEASE=$(RELEASE) $(BUILD_ARGS) -t $(DOCKER_REPO)/${1}:$(RELEASE) .]"
	echo ""

	docker build --platform linux/arm64 $(EXTRA_BUILD_ARGS) --build-arg RELEASE=$(RELEASE) --build-arg DOCKER_REPO=$(DOCKER_REPO) $(BUILD_ARGS) -t $(DOCKER_REPO)/${1}:$(RELEASE) .

# 	echo ""
# 	printf "###########  Pushing image %-15s  ###############\n" "${1}"
# 	docker push $(DOCKER_REPO)/${1}:$(RELEASE)

	echo ""
	printf "##########  Done with image %-15s  #############\n" "${1}"
	echo "##########################################################"
	echo ""
endef

docker-login:
	$(call docker_login)

flink-env: #docker-login
	$(call make_image,flink-env)
