#!/usr/bin/env bash
set -euo pipefail

HIGH_DURATION=120
LOW_DURATION=90
CYCLES=4
RUN_CPU=false
RUN_REQUESTS=false
CPU_LOAD=85
LOW_CPU_LOAD=5
CPU_WORKERS=0
REQUEST_COUNT=500000
HIGH_CONCURRENCY=300
LOW_CONCURRENCY=5
LOW_REQUEST_COUNT=1000
WAIT_FOR_LOW_PHASE=false
PRINT_SUMMARY=false
MODE=
COMMAND_LABELS=()
COMMAND_IDS=()
TEMP_FILES=()

readonly TAG_WEBSERVER_KEY=asg-webserver
readonly TAG_WEBSERVER_VALUE=true
readonly TAG_LOAD_GENERATOR_KEY=asg-load-generator
readonly TAG_LOAD_GENERATOR_VALUE=true
readonly TAG_LOAD_BALANCER_KEY=asg-loadbalancer
readonly TAG_LOAD_BALANCER_VALUE=true

cleanup() {
  if ((${#TEMP_FILES[@]} > 0)); then
    rm -f "${TEMP_FILES[@]}"
  fi
}
trap cleanup EXIT

log_step() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: load-generator.sh [mode] [options] [--cpu] [--requests [COUNT]]

Stimulus:
  --cpu                        Generate CPU load on tagged web-server instances.
  --requests [COUNT]           Generate ALB request load from the tagged load generator.
                               Defaults to 500000 requests per high phase.

Modes:
  --preflight                  Verify tagged resources, SSM readiness, required
                               software, and ALB availability.
  --stop-load                  Stop CPU and request stimulus without changing capacity.
  --reset-asg                  Stop stimulus and reset the tagged ASG to its minimum size.

Options:
  --cycles COUNT               Number of high/low cycles. Default: 4.
  --high-duration SECONDS      Length of each high-load phase. Default: 120.
  --low-duration SECONDS       Length of each low-load phase. Default: 90.
  --cpu-load PERCENT           CPU load during high phases. Default: 85.
  --low-cpu-load PERCENT       CPU load during low phases; 0 is idle. Default: 5.
  --cpu-workers COUNT          stress-ng workers; 0 uses all CPUs. Default: 0.
  --request-count COUNT        Requests in each high phase. Default: 500000.
  --high-concurrency COUNT     Apache Bench high-phase concurrency. Default: 300.
  --low-concurrency COUNT      Apache Bench low-phase concurrency. Default: 5.
  --low-request-count COUNT    Requests in each low request phase. Default: 1000.
  --wait-for-low-phase         Generate bounded low request traffic instead of idling.
  --print-summary              Print command IDs and status lookup commands.
  -h, --help                   Show this help.

Examples:
  ./load-generator.sh --preflight
  ./load-generator.sh --cpu --cycles 4 --high-duration 120 --low-duration 120 --cpu-load 90 --low-cpu-load 0
  ./load-generator.sh --requests 500000 --cycles 1 --high-duration 600
  ./load-generator.sh --cpu --requests --cycles 4 --wait-for-low-phase
  ./load-generator.sh --reset-asg
USAGE
}

require_positive_integer() {
  local key=$1
  local value=$2
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "$key must be a positive integer"
}

require_nonnegative_integer() {
  local key=$1
  local value=$2
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$key must be a non-negative integer"
}

set_mode() {
  local requested_mode=$1
  [[ -z "$MODE" ]] || fail "choose only one of --preflight, --stop-load, or --reset-asg"
  MODE=$requested_mode
}

require_one_result() {
  local resource_type=$1
  local results=$2
  local -a values=()

  if [[ -n "$results" && "$results" != None ]]; then
    read -r -a values <<<"$results"
  fi
  if ((${#values[@]} == 0)); then
    fail "no tagged ${resource_type} was found in the active account and Region"
  fi
  if ((${#values[@]} > 1)); then
    fail "found multiple tagged ${resource_type} resources: ${values[*]}"
  fi
  printf '%s\n' "${values[0]}"
}

get_autoscaling_group_name() {
  local results
  results=$(aws autoscaling describe-auto-scaling-groups \
    --filters \
      "Name=tag:${TAG_WEBSERVER_KEY},Values=${TAG_WEBSERVER_VALUE}" \
      "Name=tag:role,Values=webserver" \
    --query 'AutoScalingGroups[].AutoScalingGroupName' \
    --output text)
  require_one_result "Auto Scaling group" "$results"
}

get_load_balancer_arn() {
  local results
  results=$(aws resourcegroupstaggingapi get-resources \
    --tag-filters \
      "Key=${TAG_LOAD_BALANCER_KEY},Values=${TAG_LOAD_BALANCER_VALUE}" \
      "Key=role,Values=loadbalancer" \
    --resource-type-filters elasticloadbalancing:loadbalancer \
    --query 'ResourceTagMappingList[].ResourceARN' \
    --output text)
  require_one_result "Application Load Balancer" "$results"
}

get_load_balancer_dns_name() {
  local load_balancer_arn
  load_balancer_arn=$(get_load_balancer_arn)
  aws elbv2 describe-load-balancers \
    --load-balancer-arns "$load_balancer_arn" \
    --query 'LoadBalancers[0].DNSName' \
    --output text
}

get_load_generator_instance_id() {
  local results
  results=$(aws ec2 describe-instances \
    --filters \
      "Name=tag:${TAG_LOAD_GENERATOR_KEY},Values=${TAG_LOAD_GENERATOR_VALUE}" \
      "Name=tag:role,Values=load-generator" \
      "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text)
  require_one_result "running load-generator instance" "$results"
}

get_webserver_instance_ids() {
  aws ec2 describe-instances \
    --filters \
      "Name=tag:${TAG_WEBSERVER_KEY},Values=${TAG_WEBSERVER_VALUE}" \
      "Name=tag:role,Values=webserver" \
      "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text
}

get_ssm_ready_instance_ids() {
  local instance_ids=("$@")
  local instance_id
  local ping_status

  for instance_id in "${instance_ids[@]}"; do
    ping_status=$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=${instance_id}" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null || true)
    if [[ "$ping_status" == Online ]]; then
      printf '%s\n' "$instance_id"
    else
      log_step "Skipping ${instance_id}; SSM status is ${ping_status:-unknown}"
    fi
  done
}

get_ready_webserver_instance_ids() {
  local instance_ids_output
  local -a instance_ids=()
  local -a ready_instance_ids=()

  instance_ids_output=$(get_webserver_instance_ids)
  if [[ -n "$instance_ids_output" && "$instance_ids_output" != None ]]; then
    read -r -a instance_ids <<<"$instance_ids_output"
  fi
  ((${#instance_ids[@]} > 0)) ||
    fail "no running instances have the required web-server tags"

  mapfile -t ready_instance_ids < <(get_ssm_ready_instance_ids "${instance_ids[@]}")
  ((${#ready_instance_ids[@]} > 0)) ||
    fail "none of the tagged web-server instances are online in Systems Manager"
  printf '%s\n' "${ready_instance_ids[@]}"
}

record_command_id() {
  local label=$1
  local command_id=$2
  [[ -n "$command_id" && "$command_id" != None ]] ||
    fail "failed to capture an SSM command ID for ${label}"
  COMMAND_LABELS+=("$label")
  COMMAND_IDS+=("$command_id")
}

send_ssm_shell_command() {
  local label=$1
  local comment=$2
  local payload=$3
  shift 3
  local instance_ids=("$@")
  local parameters_file
  local command_id

  ((${#instance_ids[@]} > 0)) || fail "no instances were supplied for ${label}"
  parameters_file=$(mktemp)
  TEMP_FILES+=("$parameters_file")
  printf '%s' "$payload" |
    python3 -c 'import json,sys; print(json.dumps({"commands": sys.stdin.read().splitlines()}))' \
      >"$parameters_file"

  command_id=$(aws ssm send-command \
    --document-name AWS-RunShellScript \
    --instance-ids "${instance_ids[@]}" \
    --parameters "file://${parameters_file}" \
    --max-errors 0 \
    --comment "$comment" \
    --query 'Command.CommandId' \
    --output text)
  record_command_id "$label" "$command_id"
  printf '%s\n' "$command_id"
}

wait_for_command() {
  local command_id=$1
  shift
  local instance_id

  for instance_id in "$@"; do
    aws ssm wait command-executed \
      --command-id "$command_id" \
      --instance-id "$instance_id"
  done
}

print_command_summary() {
  local index

  ((${#COMMAND_IDS[@]} > 0)) || return
  printf '\nCommand summary:\n'
  for index in "${!COMMAND_IDS[@]}"; do
    printf -- '- %s: %s\n' "${COMMAND_LABELS[$index]}" "${COMMAND_IDS[$index]}"
  done
  printf '\nStatus commands:\n'
  for index in "${!COMMAND_IDS[@]}"; do
    printf "aws ssm list-command-invocations --command-id %q --details\n" \
      "${COMMAND_IDS[$index]}"
  done
}

run_cpu_phase() {
  local cycle=$1
  local phase=$2
  local duration=$3
  local load_percent=$4
  local -a target_ids=()
  local command_id
  local command

  mapfile -t target_ids < <(get_ready_webserver_instance_ids)
  if ((load_percent == 0)); then
    command="pkill -f '[s]tress-ng --cpu' || true"
  else
    command=$(printf '%s\n' \
      "pkill -f '[s]tress-ng --cpu' || true" \
      "nohup stress-ng --cpu ${CPU_WORKERS} --cpu-load ${load_percent} --timeout ${duration}s --metrics-brief >/tmp/stress-ng-${cycle}-${phase}.log 2>&1 &" \
      "echo started CPU ${phase} phase for cycle ${cycle}")
  fi

  command_id=$(send_ssm_shell_command \
    "CPU ${phase} cycle ${cycle}" \
    "Run CPU ${phase} phase for cycle ${cycle}" \
    "$command" \
    "${target_ids[@]}")
  wait_for_command "$command_id" "${target_ids[@]}"
  log_step "CPU ${phase} phase ${cycle}/${CYCLES}; load=${load_percent}%; targets=${target_ids[*]}; command=${command_id}"
}

run_request_phase() {
  local cycle=$1
  local phase=$2
  local duration=$3
  local request_count=$4
  local concurrency=$5
  local load_generator_instance_id
  local load_balancer_dns
  local command_id
  local command

  load_generator_instance_id=$(get_load_generator_instance_id)
  load_balancer_dns=$(get_load_balancer_dns_name)
  command=$(cat <<EOF
set -euo pipefail
pkill -f '(^|/)ab ' || true
timeout ${duration}s ab -n ${request_count} -c ${concurrency} http://${load_balancer_dns}/ >/tmp/ab-${cycle}-${phase}.log 2>&1 || true
echo completed request ${phase} phase for cycle ${cycle}
EOF
)
  command_id=$(send_ssm_shell_command \
    "Requests ${phase} cycle ${cycle}" \
    "Run request ${phase} phase for cycle ${cycle}" \
    "$command" \
    "$load_generator_instance_id")
  log_step "Requests ${phase} phase ${cycle}/${CYCLES}; count=${request_count}; concurrency=${concurrency}; command=${command_id}"
}

stop_load() {
  local -a webserver_ids=()
  local load_generator_instance_id
  local command_id

  mapfile -t webserver_ids < <(get_ready_webserver_instance_ids)
  command_id=$(send_ssm_shell_command \
    "Stop CPU stimulus" \
    "Stop CPU stimulus on tagged web servers" \
    "pkill -f '[s]tress-ng --cpu' || true" \
    "${webserver_ids[@]}")
  wait_for_command "$command_id" "${webserver_ids[@]}"

  load_generator_instance_id=$(get_load_generator_instance_id)
  command_id=$(send_ssm_shell_command \
    "Stop request stimulus" \
    "Stop Apache Bench stimulus on the tagged load generator" \
    "pkill -f '(^|/)ab ' || true" \
    "$load_generator_instance_id")
  wait_for_command "$command_id" "$load_generator_instance_id"
  log_step "Stopped CPU and request stimulus"
}

reset_autoscaling_group() {
  local autoscaling_group_name
  local minimum_size

  stop_load
  autoscaling_group_name=$(get_autoscaling_group_name)
  minimum_size=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$autoscaling_group_name" \
    --query 'AutoScalingGroups[0].MinSize' \
    --output text)
  [[ "$minimum_size" =~ ^[0-9]+$ ]] ||
    fail "could not determine the minimum size of ${autoscaling_group_name}"
  aws autoscaling set-desired-capacity \
    --auto-scaling-group-name "$autoscaling_group_name" \
    --desired-capacity "$minimum_size" \
    --no-honor-cooldown
  log_step "Reset ${autoscaling_group_name} to minimum capacity ${minimum_size}"
}

verify_remote_command() {
  local label=$1
  local instance_id=$2
  local command=$3
  local command_id

  command_id=$(send_ssm_shell_command "$label" "$label" "$command" "$instance_id")
  if ! wait_for_command "$command_id" "$instance_id"; then
    fail "${label} failed on ${instance_id}"
  fi
}

preflight() {
  local autoscaling_group_name
  local load_balancer_arn
  local load_balancer_dns
  local load_balancer_state
  local load_generator_instance_id
  local -a webserver_ids=()
  local -a all_webserver_ids=()
  local all_webserver_ids_output
  local load_generator_status

  log_step "Starting preflight checks"
  log_step "Verifying AWS credentials and active account"
  aws sts get-caller-identity --query Arn --output text >/dev/null

  log_step "Discovering tagged lab resources"
  autoscaling_group_name=$(get_autoscaling_group_name)
  load_balancer_arn=$(get_load_balancer_arn)
  load_balancer_dns=$(get_load_balancer_dns_name)
  load_generator_instance_id=$(get_load_generator_instance_id)
  log_step "Found Auto Scaling group ${autoscaling_group_name}"
  log_step "Found Application Load Balancer ${load_balancer_dns}"
  log_step "Found load generator ${load_generator_instance_id}"

  log_step "Verifying the Application Load Balancer is active"
  load_balancer_state=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$load_balancer_arn" \
    --query 'LoadBalancers[0].State.Code' \
    --output text)
  [[ "$load_balancer_state" == active ]] ||
    fail "the tagged load balancer is not active; state=${load_balancer_state}"
  log_step "Verifying the Application Load Balancer returns a successful response"
  curl --fail --silent --show-error --max-time 10 "http://${load_balancer_dns}/" >/dev/null ||
    fail "the tagged load balancer did not return a successful response"
  log_step "Application Load Balancer is active and reachable"

  log_step "Discovering tagged web-server instances"
  all_webserver_ids_output=$(get_webserver_instance_ids)
  if [[ -n "$all_webserver_ids_output" && "$all_webserver_ids_output" != None ]]; then
    read -r -a all_webserver_ids <<<"$all_webserver_ids_output"
  fi
  log_step "Verifying tagged web-server instances are online in Systems Manager"
  mapfile -t webserver_ids < <(get_ready_webserver_instance_ids)
  ((${#webserver_ids[@]} == ${#all_webserver_ids[@]})) ||
    fail "not all tagged web-server instances are online in Systems Manager"
  log_step "Web servers online in Systems Manager: ${webserver_ids[*]}"

  log_step "Verifying load generator is online in Systems Manager"
  load_generator_status=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${load_generator_instance_id}" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text)
  [[ "$load_generator_status" == Online ]] ||
    fail "the tagged load generator is not online in Systems Manager"
  log_step "Load generator is online in Systems Manager"

  log_step "Verifying stress-ng on ${webserver_ids[0]}"
  verify_remote_command \
    "Verify stress-ng" \
    "${webserver_ids[0]}" \
    "command -v stress-ng >/dev/null"
  log_step "stress-ng is available on ${webserver_ids[0]}"

  log_step "Verifying Apache Bench on ${load_generator_instance_id}"
  verify_remote_command \
    "Verify Apache Bench" \
    "$load_generator_instance_id" \
    "command -v ab >/dev/null"
  log_step "Apache Bench is available on ${load_generator_instance_id}"

  log_step "Preflight passed"
  printf 'Auto Scaling group: %s\n' "$autoscaling_group_name"
  printf 'Load balancer: http://%s/\n' "$load_balancer_dns"
  printf 'Load generator: %s\n' "$load_generator_instance_id"
  printf 'Web servers: %s\n' "${webserver_ids[*]}"
}

run_stimulus() {
  local cycle

  log_step "Configuration: cycles=${CYCLES}, high=${HIGH_DURATION}s, low=${LOW_DURATION}s, cpu=${RUN_CPU}, requests=${RUN_REQUESTS}, cpu_load=${CPU_LOAD}, low_cpu_load=${LOW_CPU_LOAD}, cpu_workers=${CPU_WORKERS}, high_concurrency=${HIGH_CONCURRENCY}, low_concurrency=${LOW_CONCURRENCY}"
  for ((cycle = 1; cycle <= CYCLES; cycle++)); do
    log_step "Starting high phase ${cycle}/${CYCLES}"
    if [[ "$RUN_CPU" == true ]]; then
      run_cpu_phase "$cycle" high "$HIGH_DURATION" "$CPU_LOAD"
    fi
    if [[ "$RUN_REQUESTS" == true ]]; then
      run_request_phase "$cycle" high "$HIGH_DURATION" "$REQUEST_COUNT" "$HIGH_CONCURRENCY"
    fi
    sleep "$HIGH_DURATION"

    log_step "Starting low phase ${cycle}/${CYCLES}"
    if [[ "$RUN_CPU" == true ]]; then
      run_cpu_phase "$cycle" low "$LOW_DURATION" "$LOW_CPU_LOAD"
    fi
    if [[ "$RUN_REQUESTS" == true && "$WAIT_FOR_LOW_PHASE" == true ]]; then
      run_request_phase "$cycle" low "$LOW_DURATION" "$LOW_REQUEST_COUNT" "$LOW_CONCURRENCY"
    fi
    sleep "$LOW_DURATION"
  done
  log_step "Stimulus complete"
}

while (($# > 0)); do
  case "$1" in
    --preflight)
      set_mode preflight
      shift
      ;;
    --stop-load)
      set_mode stop
      shift
      ;;
    --reset-asg)
      set_mode reset
      shift
      ;;
    --cpu)
      RUN_CPU=true
      shift
      ;;
    --requests)
      RUN_REQUESTS=true
      if (($# >= 2)) && [[ ! "$2" =~ ^- ]]; then
        REQUEST_COUNT=$2
        shift 2
      else
        shift
      fi
      ;;
    --cycles)
      CYCLES=$2
      shift 2
      ;;
    --high-duration)
      HIGH_DURATION=$2
      shift 2
      ;;
    --low-duration)
      LOW_DURATION=$2
      shift 2
      ;;
    --cpu-load)
      CPU_LOAD=$2
      shift 2
      ;;
    --low-cpu-load)
      LOW_CPU_LOAD=$2
      shift 2
      ;;
    --cpu-workers)
      CPU_WORKERS=$2
      shift 2
      ;;
    --request-count)
      REQUEST_COUNT=$2
      shift 2
      ;;
    --high-concurrency)
      HIGH_CONCURRENCY=$2
      shift 2
      ;;
    --low-concurrency)
      LOW_CONCURRENCY=$2
      shift 2
      ;;
    --low-request-count)
      LOW_REQUEST_COUNT=$2
      shift 2
      ;;
    --wait-for-low-phase)
      WAIT_FOR_LOW_PHASE=true
      shift
      ;;
    --print-summary)
      PRINT_SUMMARY=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

require_positive_integer cycles "$CYCLES"
require_positive_integer high-duration "$HIGH_DURATION"
require_positive_integer low-duration "$LOW_DURATION"
require_positive_integer cpu-load "$CPU_LOAD"
require_nonnegative_integer low-cpu-load "$LOW_CPU_LOAD"
require_nonnegative_integer cpu-workers "$CPU_WORKERS"
require_positive_integer request-count "$REQUEST_COUNT"
require_positive_integer high-concurrency "$HIGH_CONCURRENCY"
require_positive_integer low-concurrency "$LOW_CONCURRENCY"
require_positive_integer low-request-count "$LOW_REQUEST_COUNT"
((CPU_LOAD <= 100)) || fail "cpu-load must not exceed 100"
((LOW_CPU_LOAD <= 100)) || fail "low-cpu-load must not exceed 100"
MODE=${MODE:-run}

case "$MODE" in
  preflight)
    [[ "$RUN_CPU" == false && "$RUN_REQUESTS" == false ]] ||
      fail "--preflight cannot be combined with stimulus"
    preflight
    ;;
  stop)
    [[ "$RUN_CPU" == false && "$RUN_REQUESTS" == false ]] ||
      fail "--stop-load cannot be combined with stimulus"
    stop_load
    ;;
  reset)
    [[ "$RUN_CPU" == false && "$RUN_REQUESTS" == false ]] ||
      fail "--reset-asg cannot be combined with stimulus"
    reset_autoscaling_group
    ;;
  run)
    [[ "$RUN_CPU" == true || "$RUN_REQUESTS" == true ]] ||
      fail "choose at least one stimulus type: --cpu or --requests"
    run_stimulus
    ;;
esac

if [[ "$PRINT_SUMMARY" == true ]]; then
  print_command_summary
fi
