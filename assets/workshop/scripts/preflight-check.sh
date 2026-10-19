#!/usr/bin/env bash
# =============================================================================
# PREFLIGHT CHECK - Getting Started (both flavors)
#
# Verifies every layer the workshop depends on. Design rules:
#   - NEVER aborts (no set -e): a live event must see the full picture
#   - Three states: [ OK ] works, [FAIL] broken, [ -- ] not provisioned yet
#     (infra still being rolled out is reported as pending, not failure)
#   - Exit code: 0 if nothing FAILed (pending is acceptable), 1 otherwise
# =============================================================================

CLUSTER_NAME="${CLUSTER_NAME:-eks-hybrid-workshop}"
HYBRID_NODE_1_IP="${HYBRID_NODE_1_IP:-10.80.1.11}"
HYBRID_NODE_2_IP="${HYBRID_NODE_2_IP:-10.80.1.12}"
FAILED=0

ok()   { printf '[ OK ] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; FAILED=1; }
pend() { printf '[ -- ] %s (pending - not provisioned yet)\n' "$1"; }
# informational, NOT pending: for things that are correct as-is but worth flagging.
# pend() appends "(pending - not provisioned yet)", which read as a defect on the
# GPU quota line where zero is the expected, unfixable state at an AWS event.
note() { printf '[ -- ] %s\n' "$1"; }

# 1. EKS cluster reachable
if kubectl version --request-timeout=10s >/dev/null 2>&1; then
  ok "EKS cluster reachable (${CLUSTER_NAME})"
else
  fail "EKS cluster NOT reachable - run: aws eks update-kubeconfig --name ${CLUSTER_NAME}"
fi

# 2. Cloud nodes Ready
CLOUD_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -v '^mi-' | grep -c ' Ready')
if [ "${CLOUD_READY:-0}" -ge 1 ]; then
  ok "Cloud nodes Ready (${CLOUD_READY})"
else
  fail "No cloud node Ready"
fi

# 3. Site-to-Site VPN tunnels UP
VPN_STATE=$(aws ec2 describe-vpn-connections \
  --filters Name=state,Values=available \
  --query 'VpnConnections[].VgwTelemetry[].Status' --output text 2>/dev/null)
if [ -z "$VPN_STATE" ]; then
  pend "Site-to-Site VPN"
elif echo "$VPN_STATE" | grep -q UP; then
  ok "Site-to-Site VPN tunnels UP"
else
  fail "Site-to-Site VPN exists but no tunnel is UP"
fi

# 4. Hyper-V host online (SSM)
HV_ONLINE=$(aws ssm describe-instance-information \
  --filters Key=tag:workshop-role,Values=hyperv-host \
  --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)
case "$HV_ONLINE" in
  Online) ok "Hyper-V host online (SSM)" ;;
  None|"") pend "Hyper-V host" ;;
  *) fail "Hyper-V host SSM status: ${HV_ONLINE}" ;;
esac

# 5. Hybrid node VMs reachable
#
# The Hyper-V host registers with SSM LONG before the VMs exist - it still has to
# install the Hyper-V role, reboot, wait for SSM to come back, build the data
# center network, prepare the image and create both VMs. Measured on real events:
# roughly 40 to 45 minutes AFTER CloudFormation reports success. So "host online
# and VMs silent" is the EXPECTED state for most of an hour, and this check used
# to call it `fail`, which told a participant the environment was broken while it
# was merely warming up.
#
# The authoritative answer is the automation itself, not the host's ping status:
# while `*-hyperv-setup` is InProgress this is pending, and the current step is
# worth printing because it says how far along the build actually is.
VMS_OK=1
for ip in "$HYBRID_NODE_1_IP" "$HYBRID_NODE_2_IP"; do
  timeout 5 bash -c "echo > /dev/tcp/${ip}/22" 2>/dev/null || VMS_OK=0
done

# Cheap and best-effort: a missing permission or a throttle must not turn into a
# false failure, so an unreadable automation degrades to the old pending path.
HV_AUTO_STATUS=$(aws ssm describe-automation-executions \
  --filters Key=DocumentNamePrefix,Values="${WORKSHOP_NAME:-eks-hybrid}-hyperv-setup" \
  --query 'AutomationExecutionMetadataList | sort_by(@, &ExecutionStartTime) | [-1].AutomationExecutionStatus' \
  --output text 2>/dev/null)
HV_AUTO_STEP=$(aws ssm describe-automation-executions \
  --filters Key=DocumentNamePrefix,Values="${WORKSHOP_NAME:-eks-hybrid}-hyperv-setup" \
  --query 'AutomationExecutionMetadataList | sort_by(@, &ExecutionStartTime) | [-1].CurrentStepName' \
  --output text 2>/dev/null)

if [ "$VMS_OK" = 1 ]; then
  ok "Hybrid node VMs reachable (${HYBRID_NODE_1_IP}, ${HYBRID_NODE_2_IP})"
elif [ "$HV_AUTO_STATUS" = "InProgress" ]; then
  pend "Hybrid node VMs - Hyper-V build still running (step: ${HV_AUTO_STEP:-unknown}). This takes 40-45 min after provisioning and is NORMAL"
elif [ "$HV_AUTO_STATUS" = "Failed" ] || [ "$HV_AUTO_STATUS" = "TimedOut" ] || [ "$HV_AUTO_STATUS" = "Cancelled" ]; then
  fail "Hyper-V build ${HV_AUTO_STATUS} at step ${HV_AUTO_STEP:-unknown} - the VMs will not appear on their own. Escalate to your facilitator"
elif [ "$HV_AUTO_STATUS" = "Success" ]; then
  fail "Hyper-V build finished but the VMs are not answering on SSH - check the host in Hyper-V Manager"
elif [ "$HV_ONLINE" = "Online" ]; then
  pend "Hybrid node VMs - host is up, build not visible yet"
else
  pend "Hybrid node VMs"
fi

# 6. hybrid-node-1 pre-joined and Ready (the reference node)
# Same warm-up caveat as check 5: the pre-join is the LAST step of the Hyper-V
# automation (VerifyPreJoinedNode), so the VMs can be answering on SSH for a few
# minutes before the node shows up in the cluster. Only call that a failure once
# the automation says it is done.
N1=$(kubectl get nodes -l eks.amazonaws.com/compute-type=hybrid --no-headers 2>/dev/null | grep -c ' Ready')
if [ "${N1:-0}" -ge 1 ]; then
  ok "hybrid-node-1 pre-joined and Ready (your reference node)"
elif [ "$HV_AUTO_STATUS" = "InProgress" ]; then
  pend "hybrid-node-1 pre-join - Hyper-V build still running (step: ${HV_AUTO_STEP:-unknown})"
elif [ "$VMS_OK" = 1 ]; then
  fail "No hybrid node Ready - the pre-joined node should be registered (check /var/log/join-cluster.log on ${HYBRID_NODE_1_IP})"
else
  pend "hybrid-node-1 pre-join"
fi

# 7. FIS experiment templates present
# the tag value is the WorkshopName parameter (eks-hybrid), not the old
# eks-hybrid-nodes - a stale value here reported the pre-provisioned experiment
# as missing on a perfectly healthy event (caught 2026-08-08)
FIS=$(aws fis list-experiment-templates \
  --query 'experimentTemplates[?tags.workshop==`eks-hybrid`].id' --output text 2>/dev/null)
if [ -n "$FIS" ]; then
  ok "FIS experiment templates present"
else
  pend "FIS experiment templates"
fi

# 7a. EKS Hybrid Nodes gateway (BASE infrastructure)
# This is what makes cloud-to-pod traffic work without routing a Kubernetes
# overlay across the WAN. Two pods, active-standby: if neither is Running,
# webhooks on hybrid nodes and ALB target-type ip to hybrid pods will fail in
# ways that look like anything but a gateway problem.
GW=$(kubectl -n eks-hybrid-nodes-gateway get pods --no-headers 2>/dev/null | grep -c Running || true)
if [ "${GW:-0}" -ge 2 ]; then
  ok "Hybrid Nodes gateway: ${GW} pods running (active-standby)"
elif [ "${GW:-0}" -eq 1 ]; then
  ok "Hybrid Nodes gateway: 1 pod running (standby still starting)"
else
  fail "Hybrid Nodes gateway has no running pods - cloud-to-pod traffic will not work"
fi

# 7b. GPU burst capacity (module 6.3 only)
# A brand new AWS account - and EVERY Workshop Studio event account - has a
# quota of ZERO for On-Demand G instances, and at an event the increase request
# is blocked by SCP. Better to say so here than to let the participant wait on a
# pod that will never schedule (event 66489015: Karpenter created the NodeClaim,
# EC2 answered VcpuLimitExceeded, limit of 0).
if GQ=$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA \
    --query 'Quota.Value' --output text 2>/dev/null); then
  if [ "${GQ%.*}" -ge 4 ] 2>/dev/null; then
    ok "GPU burst capacity available (G on-demand quota: ${GQ%.*} vCPUs)"
  else
    note "GPU burst quota is ${GQ%.*} vCPUs - at an AWS event that is expected and cannot be changed, so module 6.3 is a walkthrough there. Self-paced, request an increase for L-DB2E81BA and it becomes hands-on (see Getting Started > Self-Paced)"
  fi
else
  fail "Cannot read GPU quota L-DB2E81BA - this is an IAM/access problem, NOT evidence that the quota is zero"
fi

# 8. Inference images in your account's ECR. There is no fallback registry: the
# manifests always point at this ECR, so empty repositories mean the inference
# pods cannot start, and that is a failure, not a warning.
MISSING_IMAGES=""
for repo in eks-hybrid-workshop/ollama-llama32-1b eks-hybrid-workshop/ollama-llama31-8b; do
  N=$(aws ecr describe-images --repository-name "$repo" --query 'length(imageDetails)' --output text 2>/dev/null)
  [ "${N:-0}" -ge 1 ] 2>/dev/null || MISSING_IMAGES="${MISSING_IMAGES} ${repo}"
done
if [ -z "$MISSING_IMAGES" ]; then
  ok "Inference images built in your account's ECR"
else
  fail "Inference images missing from your account's ECR:${MISSING_IMAGES}. The ${CLUSTER_NAME%-*}-images CodeBuild build is still running or failed; see Troubleshooting (Getting Started > Self-Paced) for how to check it and run it again"
fi

# 9. Workshop assets on disk (this very tree)
if [ -f ~/workshop/manifests/inference-onprem.yaml ] && [ -f ~/workshop/dashboards/hybrid-nodes.json ]; then
  ok "Workshop assets in ~/workshop/"
else
  fail "Workshop assets missing from ~/workshop/ - re-run the State Manager association or call your facilitator"
fi

echo
if [ "$FAILED" = 0 ]; then
  echo "All checks passed - you are ready to start."
else
  echo "Some checks FAILED - call your facilitator (or re-run in a minute; provisioning may still be settling)."
fi
exit $FAILED
