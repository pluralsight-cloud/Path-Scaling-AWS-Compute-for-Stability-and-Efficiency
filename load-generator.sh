#!/usr/bin/env bash
set -euo pipefail

HIGH_DURATION=120
LOW_DURATION=90
CYCLES=4
RUN_CPU=false
RUN_REQUESTS=false
CPU_LOAD=85
CPU_WORKERS=0
REQUEST_COUNT=500000
HIGH_CONCURRENCY=300
LOW_CONCURRENCY=5
LOW_REQUEST_COUNT=1000
WAIT_FOR_LOW_PHASE=false
PRINT_SUMMARY=false
COMMAND_LABELS=()
COMMAND_IDS=()

log_step() {
  printf -- '- %s
' "$*" >&2
}

usage() {
  cat <<USAGE
Usage: $0 [options] [--cpu] [--requests]

Options:
  --cpu                        Generate CPU load on running instances tagged role=webserver.
  --requests [COUNT]           Generate ALB request load from the load generator instance.
                               Defaults to 500000 requests for each high phase.
  --cycles COUNT               Number of high/low cycles to run. Defaults to 4.
  --high-duration SECONDS      Length of each high-load phase. Defaults to 120.
  --low-duration SECONDS       Length of each low-load phase. Defaults to 90.
  --cpu-load PERCENT           stress-ng CPU load percentage during high phase. Defaults to 85.
  --cpu-workers COUNT          stress-ng worker count. 0 means one worker per vCPU. Defaults to 0.
  --high-concurrency COUNT     Apache Bench concurrency during high phase. Defaults to 300.
  --low-concurrency COUNT      Apache Bench concurrency during low phase. Defaults to 5.
  --low-request-count COUNT    Apache Bench request count during low phase. Defaults to 1000.
  --wait-for-low-phase         Run a bounded low request phase instead of sleeping idle.
  --print-summary              Print SSM command IDs and status lookup commands after completion.
  --reset-asg                  Set the first Auto Scaling group in the active region to desired capacity 1.
  -h, --help                   Show this help.

Examples:
  $0 --cpu --cycles 6 --high-duration 120 --low-duration 90 --cpu-load 90
  $0 --requests --cycles 5 --high-duration 180 --low-duration 120 --requests 2000000 --high-concurrency 400 --wait-for-low-phase
  $0 --cpu --requests --cycles 4 --high-duration 120 --low-duration 120 --cpu-load 85 --high-concurrency 300
USAGE
}

require_positive_integer() {
  local key=$1
  local value=$2

  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$key must be a positive integer." >&2
    exit 1
  fi
}

record_command_id() {
  local label=$1
  local command_id=$2

  if [[ -z "$command_id" || "$command_id" == 'None' ]]; then
    echo "Failed to capture SSM command ID for $label." >&2
    exit 1
  fi

  COMMAND_LABELS+=("$label")
  COMMAND_IDS+=("$command_id")
}

print_command_summary() {
  local index

  if [[ ${#COMMAND_IDS[@]} -eq 0 ]]; then
    return
  fi

  printf '
Command summary:
'
  for index in "${!COMMAND_IDS[@]}"; do
    log_step "${COMMAND_LABELS[$index]} ID: ${COMMAND_IDS[$index]}"
  done

  printf '
Use the following commands to check status:
'
  for index in "${!COMMAND_IDS[@]}"; do
    log_step "${COMMAND_LABELS[$index]}"
    printf "
aws ssm list-command-invocations --command-id %q --details --query 'CommandInvocations[].{InstanceId:InstanceId,Status:Status,StatusDetails:StatusDetails}'

" "${COMMAND_IDS[$index]}"
  done
}

get_webserver_instance_ids() {
  aws ec2 describe-instances     --filters Name=tag:role,Values=webserver Name=instance-state-name,Values=running     --query 'Reservations[].Instances[].InstanceId'     --output text
}

get_ssm_ready_instance_ids() {
  local instance_ids=("$@")
  local ready=()
  local instance_id
  local ping_status

  for instance_id in "${instance_ids[@]}"; do
    ping_status=$(aws ssm describe-instance-information       --filters "Key=InstanceIds,Values=${instance_id}"       --query 'InstanceInformationList[0].PingStatus'       --output text 2>/dev/null || true)
    if [[ "$ping_status" == 'Online' ]]; then
      ready+=("$instance_id")
    else
      log_step "Skipping instance ${instance_id}; SSM PingStatus=${ping_status:-Unknown}"
    fi
  done

  printf '%s
' "${ready[@]}"
}

get_load_generator_instance_id() {
  aws ec2 describe-instances     --filters Name=tag:asg-load-generator,Values=true Name=tag:role,Values=load-generator Name=instance-state-name,Values=running     --query 'Reservations[].Instances[0].InstanceId'     --output text
}

get_load_balancer_dns_name() {
  local load_balancer_arn
  load_balancer_arn=$(aws resourcegroupstaggingapi get-resources     --tag-filters Key=asg-loadbalancer,Values=true Key=role,Values=loadbalancer     --resource-type-filters elasticloadbalancing:loadbalancer     --query 'ResourceTagMappingList[0].ResourceARN'     --output text)

  if [[ -z "$load_balancer_arn" || "$load_balancer_arn" == 'None' ]]; then
    echo 'No load balancer found with tags asg-loadbalancer=true and role=loadbalancer.' >&2
    exit 1
  fi

  aws elbv2 describe-load-balancers     --load-balancer-arns "$load_balancer_arn"     --query 'LoadBalancers[0].DNSName'     --output text
}

reset_first_autoscaling_group() {
  local asg_name

  asg_name=$(aws autoscaling describe-auto-scaling-groups \
    --query 'AutoScalingGroups[0].AutoScalingGroupName' \
    --output text)

  if [[ -z "$asg_name" || "$asg_name" == 'None' ]]; then
    echo 'No Auto Scaling groups found in the active region.' >&2
    exit 1
  fi

  log_step "Setting desired capacity to 1 for Auto Scaling group ${asg_name}."
  aws autoscaling set-desired-capacity \
    --auto-scaling-group-name "$asg_name" \
    --desired-capacity 1 \
    --no-honor-cooldown
}

send_ssm_shell_command() {
  local label=$1
  shift
  local comment=$1
  shift
  local instance_ids_string=$1
  shift
  local payload=$1

  local params_file
  local command_id
  params_file=$(mktemp)
  printf '%s' "$payload" | python3 -c 'import json, sys; print(json.dumps({"commands": sys.stdin.read().splitlines()}))' > "$params_file"

  read -r -a instance_ids <<<"$instance_ids_string"
  command_id=$(aws ssm send-command     --document-name AWS-RunShellScript     --instance-ids "${instance_ids[@]}"     --parameters file://"$params_file"     --max-errors 1     --comment "$comment"     --query 'Command.CommandId'     --output text)
  rm -f "$params_file"

  record_command_id "$label" "$command_id"
}

run_cpu_phase() {
  local cycle=$1
  local phase=$2
  local duration=$3
  local load_percent=$4
  local instance_ids_output
  local -a instance_ids
  local -a ready_instance_ids
  local cmd

  instance_ids_output=$(get_webserver_instance_ids)
  read -r -a instance_ids <<<"$instance_ids_output"
  if [[ ${#instance_ids[@]} -eq 0 ]]; then
    echo 'No running EC2 instances found with tag role=webserver.' >&2
    exit 1
  fi

  mapfile -t ready_instance_ids < <(get_ssm_ready_instance_ids "${instance_ids[@]}")
  if [[ ${#ready_instance_ids[@]} -eq 0 ]]; then
    echo 'No CPU target instances are SSM ready.' >&2
    exit 1
  fi

  cmd=$(cat <<EOF
set -euo pipefail
pkill -f 'stress-ng --cpu' || true
nohup stress-ng --cpu ${CPU_WORKERS} --cpu-load ${load_percent} --timeout ${duration}s --metrics-brief >/tmp/stress-ng-${cycle}-${phase}.log 2>&1 &
echo started cpu ${phase} phase for cycle ${cycle}
EOF
)

  log_step "Sending CPU ${phase} phase for cycle ${cycle} to ${#ready_instance_ids[@]} webserver instance(s)."
  send_ssm_shell_command "CPU ${phase} cycle ${cycle}" "Run CPU ${phase} phase for cycle ${cycle}" "${ready_instance_ids[*]}" "$cmd"
}

run_request_phase() {
  local cycle=$1
  local phase=$2
  local duration=$3
  local request_count=$4
  local concurrency=$5
  local load_generator_instance_id
  local alb_dns
  local cmd

  load_generator_instance_id=$(get_load_generator_instance_id)
  if [[ -z "$load_generator_instance_id" || "$load_generator_instance_id" == 'None' ]]; then
    echo 'No running load generator instance found.' >&2
    exit 1
  fi

  alb_dns=$(get_load_balancer_dns_name)

  cmd=$(cat <<EOF
set -euo pipefail
pkill -f '(^|/)ab ' || true
timeout ${duration}s ab -n ${request_count} -c ${concurrency} http://${alb_dns}/ >/tmp/ab-${cycle}-${phase}.log 2>&1 || true
echo completed request ${phase} phase for cycle ${cycle}
EOF
)

  log_step "Sending request ${phase} phase for cycle ${cycle} via load generator ${load_generator_instance_id}."
  send_ssm_shell_command "Requests ${phase} cycle ${cycle}" "Run request ${phase} phase for cycle ${cycle}" "$load_generator_instance_id" "$cmd"
}

for arg in "$@"; do
  if [[ "$arg" == '--reset-asg' ]]; then
    reset_first_autoscaling_group
    exit 0
  fi
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpu)
      RUN_CPU=true
      shift
      ;;
    --requests)
      RUN_REQUESTS=true
      if [[ $# -ge 2 && ! "$2" =~ ^- ]]; then
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
    --cpu-workers)
      CPU_WORKERS=$2
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_positive_integer --cycles "$CYCLES"
require_positive_integer --high-duration "$HIGH_DURATION"
require_positive_integer --low-duration "$LOW_DURATION"
require_positive_integer --cpu-load "$CPU_LOAD"
if [[ ! "$CPU_WORKERS" =~ ^[0-9]+$ ]]; then
  echo '--cpu-workers must be a non-negative integer.' >&2
  exit 1
fi
require_positive_integer --requests "$REQUEST_COUNT"
require_positive_integer --high-concurrency "$HIGH_CONCURRENCY"
require_positive_integer --low-concurrency "$LOW_CONCURRENCY"
require_positive_integer --low-request-count "$LOW_REQUEST_COUNT"

if [[ "$RUN_CPU" == false && "$RUN_REQUESTS" == false ]]; then
  echo 'No load type selected; choose at least one or both of --cpu and --requests.' >&2
  usage >&2
  exit 1
fi

log_step "Configuration: cycles=${CYCLES}, high=${HIGH_DURATION}s, low=${LOW_DURATION}s, cpu=${RUN_CPU}, requests=${RUN_REQUESTS}, cpu_load=${CPU_LOAD}, cpu_workers=${CPU_WORKERS}, high_concurrency=${HIGH_CONCURRENCY}, low_concurrency=${LOW_CONCURRENCY}, wait_for_low_phase=${WAIT_FOR_LOW_PHASE}"

for ((cycle=1; cycle<=CYCLES; cycle++)); do
  log_step "Starting high phase ${cycle}/${CYCLES}."
  if [[ "$RUN_CPU" == true ]]; then
    run_cpu_phase "$cycle" high "$HIGH_DURATION" "$CPU_LOAD"
  fi
  if [[ "$RUN_REQUESTS" == true ]]; then
    run_request_phase "$cycle" high "$HIGH_DURATION" "$REQUEST_COUNT" "$HIGH_CONCURRENCY"
  fi
  sleep "$HIGH_DURATION"

  log_step "Starting low phase ${cycle}/${CYCLES}."
  if [[ "$RUN_CPU" == true ]]; then
    run_cpu_phase "$cycle" low "$LOW_DURATION" 5
  fi
  if [[ "$RUN_REQUESTS" == true && "$WAIT_FOR_LOW_PHASE" == true ]]; then
    run_request_phase "$cycle" low "$LOW_DURATION" "$LOW_REQUEST_COUNT" "$LOW_CONCURRENCY"
    sleep "$LOW_DURATION"
  else
    sleep "$LOW_DURATION"
  fi
done

if [[ "$PRINT_SUMMARY" == true ]]; then
  print_command_summary
fi
