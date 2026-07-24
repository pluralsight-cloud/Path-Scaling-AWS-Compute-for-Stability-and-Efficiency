TEMPLATES ?= $(shell find . -name '*.yml' 2>/dev/null)

DURATION ?= 600
REQUESTS ?= 500000
CONCURRENCY ?= 300
CPU_LOAD ?= 90
CPU_WORKERS ?= 0

CPU_CYCLE_COUNT ?= 6
CPU_CYCLE_HIGH ?= 120
CPU_CYCLE_LOW ?= 90

REQUEST_CYCLE_COUNT ?= 5
REQUEST_CYCLE_HIGH ?= 180
REQUEST_CYCLE_LOW ?= 120
REQUEST_LOW_CONCURRENCY ?= 5
REQUEST_LOW_COUNT ?= 1000

help: ## Display this help message
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

reset-asg: make-executable ## Reset ASG desired-capacity to '1' to clear any scaling effects
	./load-generator.sh --reset-asg

executable: ## Make load-generator.sh executable
	@chmod +x load-generator.sh

cpu-spike: make-executable ## Create a single CPU spike
	./load-generator.sh --cpu \
	  --cycles 1 \
	  --high-duration $(DURATION) \
	  --low-duration 60 \
	  --cpu-load $(CPU_LOAD) \
	  --cpu-workers $(CPU_WORKERS)

cpu-cycle: make-executable ## Create repeated CPU high/low cycles
	./load-generator.sh --cpu \
	  --cycles $(CPU_CYCLE_COUNT) \
	  --high-duration $(CPU_CYCLE_HIGH) \
	  --low-duration $(CPU_CYCLE_LOW) \
	  --cpu-load $(CPU_LOAD) \
	  --cpu-workers $(CPU_WORKERS)

cpu-noise: make-executable ## Create mixed cylcles of low and high CPU load to generate noise
	$(MAKE) cpu-cycle CPU_CYCLE_COUNT=5 CPU_CYCLE_HIGH=30 CPU_CYCLE_LOW=30 && \
	$(MAKE) cpu-cycle CPU_CYCLE_COUNT=5 CPU_CYCLE_HIGH=30 CPU_CYCLE_LOW=60 && \
	$(MAKE) cpu-spike CPU_CYCLE_HIGH=60 && \
	$(MAKE) cpu-cycle CPU_CYCLE_COUNT=5 CPU_CYCLE_HIGH=30 CPU_CYCLE_LOW=30 && \
	$(MAKE) cpu-cycle CPU_CYCLE_COUNT=5 CPU_CYCLE_HIGH=30 CPU_CYCLE_LOW=60 && \
	$(MAKE) cpu-spike CPU_CYCLE_HIGH=60

request-spike: make-executable ## Create a single HTTP request spike
	./load-generator.sh --requests $(REQUESTS) \
	  --cycles 1 \
	  --high-duration $(DURATION) \
	  --low-duration 60 \
	  --high-concurrency $(CONCURRENCY)

request-cycle: make-executable ## Create repeated HTTP request high/low cycles
	./load-generator.sh --requests $(REQUESTS) \
	  --cycles $(REQUEST_CYCLE_COUNT) \
	  --high-duration $(REQUEST_CYCLE_HIGH) \
	  --low-duration $(REQUEST_CYCLE_LOW) \
	  --high-concurrency $(CONCURRENCY) \
	  --low-concurrency $(REQUEST_LOW_CONCURRENCY) \
	  --low-request-count $(REQUEST_LOW_COUNT) \
	  --wait-for-low-phase


mixed-spike: make-executable ## Create one combined CPU + HTTP spike
	./load-generator.sh --cpu --requests $(REQUESTS) \
	  --cycles 1 \
	  --high-duration $(DURATION) \
	  --low-duration 60 \
	  --cpu-load $(CPU_LOAD) \
	  --cpu-workers $(CPU_WORKERS) \
	  --high-concurrency $(CONCURRENCY)

mixed-cycle: make-executable ## Create combined CPU + HTTP cycles
	./load-generator.sh --cpu --requests $(REQUESTS) \
	  --cycles $(REQUEST_CYCLE_COUNT) \
	  --high-duration $(REQUEST_CYCLE_HIGH) \
	  --low-duration $(REQUEST_CYCLE_LOW) \
	  --cpu-load $(CPU_LOAD) \
	  --cpu-workers $(CPU_WORKERS) \
	  --high-concurrency $(CONCURRENCY) \
	  --low-concurrency $(REQUEST_LOW_CONCURRENCY) \
	  --low-request-count $(REQUEST_LOW_COUNT) \
	  --wait-for-low-phase

tools: ## Package load-generator.sh and Makefile into tools.zip
	@echo "Creating tools.zip with load-generator.sh and Makefile..."
	zip --junk-paths tools.zip load-generator.sh Makefile

clean: ## Remove the tools.zip file
	rm -vf tools.zip

.PHONY: help make-executable cpu-spike cpu-cycle request-spike request-cycle mixed-spike mixed-cycle reset-asg oscillation-spike oscillation-cycle clean
