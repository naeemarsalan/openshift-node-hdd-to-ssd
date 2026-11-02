#!/usr/bin/env bash
# Restore the node's original OVS system-id (OVN chassis ID) after a reinstall.
#
# Symptom: ovnkube-controller CrashLoopBackOff with
#   admission webhook "node.network-node-identity.openshift.io" denied ...
#   k8s.ovn.org/node-chassis-id cannot be changed once set
#
# Usage: restore-ovs-chassis-id.sh <node>
set -euo pipefail

NODE="${1:?usage: $0 <node>}"

OLD_ID=$(oc get node "$NODE" \
  -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/node-chassis-id}')
[[ -n "$OLD_ID" ]] || { echo "no chassis-id annotation on $NODE" >&2; exit 1; }
echo "Restoring system-id $OLD_ID on $NODE"

oc debug "node/$NODE" -- chroot /host bash -c "
  set -euo pipefail
  echo '$OLD_ID' > /etc/openvswitch/system-id.conf
  ovs-vsctl set Open_vSwitch . external_ids:system-id='$OLD_ID'
"

# Restart ovnkube-node on that node so it picks up the restored ID.
oc delete pod -n openshift-ovn-kubernetes \
  -l app=ovnkube-node --field-selector "spec.nodeName=$NODE"
