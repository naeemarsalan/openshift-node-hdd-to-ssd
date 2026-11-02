#!/usr/bin/env bash
# Force a static-pod operator to reinstall its pod on a reinstalled node.
#
# After the reinstall, the operator still records the node at its old
# currentRevision, so it never schedules an installer pod. Lowering
# currentRevision is rejected by the CRD ("must only increase"), so instead
# remove the node's entry from status.nodeStatuses; the node controller
# re-adds it at revision 0 and an installer runs.
#
# Usage: reset-operator-node-status.sh <node> [resource ...]
#   default resources: etcd kubecontrollermanager kubescheduler
set -euo pipefail

NODE="${1:?usage: $0 <node> [resource ...]}"; shift
if [[ $# -gt 0 ]]; then RESOURCES=("$@"); else RESOURCES=(etcd kubecontrollermanager kubescheduler); fi

for r in "${RESOURCES[@]}"; do
  IDX=$(oc get "$r" cluster -o json |
    jq --arg n "$NODE" '.status.nodeStatuses | map(.nodeName) | index($n)')
  if [[ "$IDX" == "null" ]]; then
    echo "$r: $NODE not in nodeStatuses, skipping"; continue
  fi
  echo "$r: removing nodeStatuses[$IDX] ($NODE)"
  # The "test" op guards against the index having shifted.
  oc patch "$r" cluster --subresource=status --type=json -p "[
    {\"op\":\"test\",\"path\":\"/status/nodeStatuses/$IDX/nodeName\",\"value\":\"$NODE\"},
    {\"op\":\"remove\",\"path\":\"/status/nodeStatuses/$IDX\"}]"
done
