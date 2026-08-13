DURATION ?= 600
REQUESTS ?= 500000
CONCURRENCY ?= 300
CPU_LOAD ?= 90
LOW_CPU_LOAD ?= 5
CPU_WORKERS ?= 0

CPU_CYCLE_COUNT ?= 6
CPU_CYCLE_HIGH ?= 120
CPU_CYCLE_LOW ?= 90

REQUEST_CYCLE_COUNT ?= 5
REQUEST_CYCLE_HIGH ?= 180
REQUEST_CYCLE_LOW ?= 120
REQUEST_LOW_CONCURRENCY ?= 5
REQUEST_LOW_COUNT ?= 1000

LAB01_CYCLE_COUNT ?= 2
LAB01_CYCLE_HIGH ?= 120
LAB01_CYCLE_LOW ?= 120
LAB01_CPU_LOAD ?= 90

LAB02_CPU_CYCLE_COUNT ?= 1
LAB02_CPU_CYCLE_HIGH ?= 180
LAB02_CPU_CYCLE_LOW ?= 0
LAB02_CPU_LOAD ?= 90
LAB02_REQUEST_RATE ?= 10
LAB02_REQUEST_RATE_MULTIPLIERS ?= 1 2 3
LAB02_REQUEST_CYCLE_COUNT ?= 3
LAB02_REQUEST_HIGH ?= 180
LAB02_REQUEST_LOW ?= 0

.DEFAULT_GOAL := help

help: ## Display available tooling and lab targets
	@awk 'BEGIN {FS = ":.*## "}; /^[a-zA-Z0-9_-]+:.*## / {printf "\033[36m%-28s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

preflight: executable ## Verify tagged lab resources and required software
	./load-generator.sh --preflight

stop-load: executable ## Stop active CPU and request stimulus
	./load-generator.sh --stop-load

reset-asg: executable ## Stop stimulus and reset the tagged ASG to minimum capacity
	./load-generator.sh --reset-asg

cpu-spike: executable ## Create one CPU spike
	./load-generator.sh --cpu \
	  --cycles 1 \
	  --high-duration "$(DURATION)" \
	  --low-duration 60 \
	  --cpu-load "$(CPU_LOAD)" \
	  --low-cpu-load "$(LOW_CPU_LOAD)" \
	  --cpu-workers "$(CPU_WORKERS)"

cpu-cycle: executable ## Create repeated CPU high/low cycles
	./load-generator.sh --cpu \
	  --cycles "$(CPU_CYCLE_COUNT)" \
	  --high-duration "$(CPU_CYCLE_HIGH)" \
	  --low-duration "$(CPU_CYCLE_LOW)" \
	  --cpu-load "$(CPU_LOAD)" \
	  --low-cpu-load "$(LOW_CPU_LOAD)" \
	  --cpu-workers "$(CPU_WORKERS)"

request-spike: executable ## Create one HTTP request spike
	./load-generator.sh --requests "$(REQUESTS)" \
	  --cycles 1 \
	  --high-duration "$(DURATION)" \
	  --low-duration 60 \
	  --high-concurrency "$(CONCURRENCY)"

request-cycle: executable ## Create repeated HTTP request high/low cycles
	./load-generator.sh --requests "$(REQUESTS)" \
	  --cycles "$(REQUEST_CYCLE_COUNT)" \
	  --high-duration "$(REQUEST_CYCLE_HIGH)" \
	  --low-duration "$(REQUEST_CYCLE_LOW)" \
	  --high-concurrency "$(CONCURRENCY)" \
	  --low-concurrency "$(REQUEST_LOW_CONCURRENCY)" \
	  --low-request-count "$(REQUEST_LOW_COUNT)" \
	  --wait-for-low-phase

mixed-spike: executable ## Create one combined CPU and HTTP spike
	./load-generator.sh --cpu --requests "$(REQUESTS)" \
	  --cycles 1 \
	  --high-duration "$(DURATION)" \
	  --low-duration 60 \
	  --cpu-load "$(CPU_LOAD)" \
	  --low-cpu-load "$(LOW_CPU_LOAD)" \
	  --cpu-workers "$(CPU_WORKERS)" \
	  --high-concurrency "$(CONCURRENCY)"

mixed-cycle: executable ## Create repeated combined CPU and HTTP cycles
	./load-generator.sh --cpu --requests "$(REQUESTS)" \
	  --cycles "$(REQUEST_CYCLE_COUNT)" \
	  --high-duration "$(REQUEST_CYCLE_HIGH)" \
	  --low-duration "$(REQUEST_CYCLE_LOW)" \
	  --cpu-load "$(CPU_LOAD)" \
	  --low-cpu-load "$(LOW_CPU_LOAD)" \
	  --cpu-workers "$(CPU_WORKERS)" \
	  --high-concurrency "$(CONCURRENCY)" \
	  --low-concurrency "$(REQUEST_LOW_CONCURRENCY)" \
	  --low-request-count "$(REQUEST_LOW_COUNT)" \
	  --wait-for-low-phase

lab-01: preflight ## Run the Lab 1 stimulus
	./load-generator.sh --cpu \
	  --cycles "$(LAB01_CYCLE_COUNT)" \
	  --high-duration "$(LAB01_CYCLE_HIGH)" \
	  --low-duration "$(LAB01_CYCLE_LOW)" \
	  --cpu-load "$(LAB01_CPU_LOAD)" \
	  --low-cpu-load 0 \
	  --cpu-workers "$(CPU_WORKERS)"

lab-02-cpu: preflight ## Run the Lab 2 CPU-only stimulus
	./load-generator.sh --cpu \
	  --cycles "$(LAB02_CPU_CYCLE_COUNT)" \
	  --high-duration "$(LAB02_CPU_CYCLE_HIGH)" \
	  --low-duration "$(LAB02_CPU_CYCLE_LOW)" \
	  --cpu-load "$(LAB02_CPU_LOAD)" \
	  --low-cpu-load "$(LOW_CPU_LOAD)" \
	  --cpu-workers "$(CPU_WORKERS)"

lab-02-requests: preflight ## Run the Lab 2 customer-request stimulus
	./load-generator.sh --requests \
	  --request-rate "$(LAB02_REQUEST_RATE)" \
	  --request-rate-multipliers "$(LAB02_REQUEST_RATE_MULTIPLIERS)" \
	  --cycles "$(LAB02_REQUEST_CYCLE_COUNT)" \
	  --high-duration "$(LAB02_REQUEST_HIGH)" \
	  --low-duration "$(LAB02_REQUEST_LOW)"

executable: ## Make the shared load generator executable
	@chmod +x load-generator.sh

.PHONY: help preflight stop-load reset-asg cpu-spike cpu-cycle request-spike request-cycle
.PHONY: mixed-spike mixed-cycle lab-01 lab-02-cpu lab-02-requests executable
