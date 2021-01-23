SHELL := bash
.SHELLFLAGS := -o pipefail -euc

export PATH := bin:$(PATH)

-include .env
export

BUILD := build/$(T)/$(L)
DEB := riju-$(T)-$(L).deb
S3_DEBS := s3://$(S3_BUCKET)-debs
S3_DEB := $(S3_DEBS)/debs/$(DEB)
S3_HASH := $(S3_DEBS)/hashes/riju-$(T)-$(L)

ifneq ($(CMD),)
BASH_CMD := bash -c '$(CMD)'
else
BASH_CMD :=
endif

# Get rid of 'Entering directory' / 'Leaving directory' messages.
MAKE_QUIETLY := MAKELEVEL= make

.PHONY: all $(MAKECMDGOALS)

help:
	@echo "usage:"
	@echo
	@cat Makefile | \
		grep -E '^[^.:[:space:]]+:|[#]##' | \
		sed -E 's/([^.:[:space:]]+):.*/  make \1/' | \
		sed -E 's/[#]## *(.+)/\n    (\1)\n/'

### Build artifacts locally

ifneq ($(NC),)
NO_CACHE := --no-cache
else
NO_CACHE :=
endif

image:
	@: $${I}
ifeq ($(I),composite)
	node tools/build-composite-image.js
else ifneq (,$(filter $(I),admin ci))
	docker build . -f docker/$(I)/Dockerfile -t riju:$(I) $(NO_CACHE)
else
	hash="$$(node tools/hash-dockerfile.js $(I) | grep .)"; docker build . -f docker/$(I)/Dockerfile -t riju:$(I) --label riju.image-hash="$${hash}" $(NO_CACHE)
endif

script:
	@: $${L} $${T}
	mkdir -p $(BUILD)
	node tools/generate-build-script.js --lang $(L) --type $(T) > $(BUILD)/build.bash
	chmod +x $(BUILD)/build.bash

scripts:
	@: $${L}
	node tools/make-foreach.js --types script L=$(L)

all-scripts:
	node tools/write-all-build-scripts.js

pkg-clean:
	@: $${L} $${T}
	rm -rf $(BUILD)/src $(BUILD)/pkg
	mkdir -p $(BUILD)/src $(BUILD)/pkg

pkg-build:
	@: $${L} $${T}
	cd $(BUILD)/src && pkg="$(PWD)/$(BUILD)/pkg" src="$(PWD)/$(BUILD)/src" $(or $(BASH_CMD),../build.bash)

pkg-debug:
	@: $${L} $${T}
	$(MAKE_QUIETLY) pkg-build L=$(L) T=$(T) CMD=bash

Z ?= none

pkg-deb:
	@: $${L} $${T}
	fakeroot dpkg-deb --build -Z$(Z) $(BUILD)/pkg $(BUILD)/$(DEB)

pkg: pkg-clean pkg-build pkg-deb

pkgs:
	@: $${L}
	node tools/make-foreach.js --types pkg L=$(L)

repkg: script
	@: $${L} $${T}
	$(MAKE_QUIETLY) shell I=packaging CMD="make pkg L=$(L) T=$(T)"
	ctr="$$(docker container ls -f label="riju-install-target=yes" -l -q)"; test "$${ctr}" || (echo "no valid container is live"; exit 1); docker exec "$${ctr}" make install L=$(L) T=$(T)

repkgs:
	@: $${L}
	node tools/make-foreach.js --types repkg L=$(L)

### Manipulate artifacts inside Docker

VOLUME_MOUNT ?= $(PWD)

P1 ?= 6119
P2 ?= 6120

ifneq (,$(E))
SHELL_PORTS := -p 127.0.0.1:$(P1):6119 -p 127.0.0.1:$(P2):6120
else
SHELL_PORTS :=
endif

SHELL_ENV := -e Z -e CI -e TEST_PATIENCE -e TEST_CONCURRENCY

shell:
	@: $${I}
ifneq (,$(filter $(I),admin ci))
	docker run -it --rm --hostname $(I) -v $(VOLUME_MOUNT):/src -v /var/run/docker.sock:/var/run/docker.sock -v $(HOME)/.aws:/var/riju/.aws -v $(HOME)/.docker:/var/riju/.docker -v $(HOME)/.ssh:/var/riju/.ssh -v $(HOME)/.terraform.d:/var/riju/.terraform.d -e AWS_REGION -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e DOCKER_USERNAME -e DOCKER_PASSWORD -e DEPLOY_SSH_PRIVATE_KEY -e DOCKER_REPO -e S3_BUCKET -e DOMAIN -e VOLUME_MOUNT=$(VOLUME_MOUNT) $(SHELL_PORTS) $(SHELL_ENV) --network host riju:$(I) $(BASH_CMD)
else ifneq (,$(filter $(I),compile app))
	docker run -it --rm --hostname $(I) $(SHELL_PORTS) $(SHELL_ENV) riju:$(I) $(BASH_CMD)
else ifneq (,$(filter $(I),runtime composite))
	docker run -it --rm --hostname $(I) -v $(VOLUME_MOUNT):/src --label riju-install-target=yes $(SHELL_PORTS) $(SHELL_ENV) riju:$(I) $(BASH_CMD)
else
	docker run -it --rm --hostname $(I) -v $(VOLUME_MOUNT):/src $(SHELL_PORTS) $(SHELL_ENV) riju:$(I) $(BASH_CMD)
endif

install:
	@: $${L} $${T}
	if [[ -z "$$(ls -A /var/lib/apt/lists)" ]]; then sudo apt update; fi
	DEBIAN_FRONTEND=noninteractive sudo -E apt reinstall -y ./$(BUILD)/$(DEB)

installs:
	@: $${L}
	node tools/make-foreach.js --types install L=$(L)

### Build and run application code

frontend:
	npx webpack --mode=production

frontend-dev:
	watchexec -w webpack.config.cjs -w node_modules -r --no-environment -- "echo 'Running webpack...' >&2; npx webpack --mode=development --watch"

system:
	./system/compile.bash

system-dev:
	watchexec -w system/src -n -- ./system/compile.bash

server:
	node backend/server.js

server-dev:
	watchexec -w backend -r -n -- node backend/server.js

build: frontend system

dev:
	$(MAKE_QUIETLY) -j3 frontend-dev system-dev server-dev

test:
	node backend/test-runner.js $(F)

sandbox:
	@: $${L}
	L=$(L) node backend/sandbox.js

lsp:
	@: $${C}
	node backend/lsp-repl.js $(C)

### Fetch artifacts from registries

pull-base:
	docker pull ubuntu:rolling

pull:
	@: $${I} $${DOCKER_REPO}
	docker pull $(DOCKER_REPO):$(I)
	docker tag $(DOCKER_REPO):$(I) riju:$(I)

download:
	@: $${L} $${T} $${S3_BUCKET}
	mkdir -p $(BUILD)
	aws s3 cp $(S3_DEB) $(BUILD)/$(DEB)

plan:
	node tools/plan-publish.js

sync:
	node tools/plan-publish.js --execute

### Publish artifacts to registries

push:
	@: $${I} $${DOCKER_REPO}
	docker tag riju:$(I) $(DOCKER_REPO):$(I)
	docker push $(DOCKER_REPO):$(I)

upload:
	@: $${L} $${T} $${S3_BUCKET}
	aws s3 rm --recursive $(S3_HASH)
	aws s3 cp $(BUILD)/$(DEB) $(S3_DEB)
	hash="$$(dpkg-deb -f $(BUILD)/$(DEB) Riju-Script-Hash | grep .)"; aws s3 cp - "$(S3_HASH)/$${hash}" < /dev/null

publish:
	tools/publish.bash

### Miscellaneous

dockerignore:
	echo "# This file is generated by 'make dockerignore', do not edit." > .dockerignore
	cat .gitignore | sed 's#^#**/#' >> .dockerignore

env:
	exec bash --rcfile <(cat ~/.bashrc - <<< 'PS1="[.env] $$PS1"')

tmux:
	tmux attach || tmux new-session -s tmux
