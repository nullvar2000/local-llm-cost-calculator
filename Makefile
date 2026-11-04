HOST ?= paul@192.168.30.225
DEST ?= ~/llama-server
SCRIPT := bin/llm-cost.sh

.PHONY: help test lint install sample

help:
	@printf '%s\n' \
	  'test     - run the offline test suite (no network, no GPU, no deps)' \
	  'lint     - shellcheck, when it is installed' \
	  'install  - rsync bin/llm-cost.sh to the inference host' \
	  '           make install HOST=paul@192.168.30.225 DEST=~/llama-server' \
	  'sample   - run one 60s sample on the inference host'

test:
	@bash tests/run.sh

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -x bin/*.sh tests/*.sh tests/fixtures/*.sh; \
	else \
	  echo 'shellcheck not installed - skipping'; \
	fi

install:
	rsync -a $(SCRIPT) $(HOST):$(DEST)/llm-cost.sh

sample:
	ssh $(HOST) 'cd ~/llama-server && ./llm-cost.sh --seconds 60 --endpoints "strata:8080"'
