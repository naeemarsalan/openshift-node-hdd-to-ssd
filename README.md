# OpenShift control-plane node: HDD to SSD

How to move a running OpenShift control-plane node's RHCOS install from an HDD
to an SSD by reinstalling RHCOS in place, without rebuilding the cluster.

Example environment: a 3-node compact cluster (OpenShift 4.20.32, OpenShift
Virtualization) on Dell hardware, with the node booting from a 1 TB HDD and
a new SSD added alongside it. The old HDD is left untouched as a boot fallback.

Placeholders: `<node>` is the node name, `<node-ip>` its IP, `<old>` the old
disk (e.g. `sdb`), `<ssd>` the new disk, `<etcd-member-id>` the etcd member ID.

## Prerequisites

- An ignition file for the SSD install. In this example it was a small wrapper
  that `merge`s the full rendered master config (fetched from the
  machine-config-server and embedded inline as a `data:` URL), and in addition:
  - sets `/etc/hostname`;
  - copies `/etc/iscsi/initiatorname.iscsi`, `/etc/nvme/hostid` and
    `/etc/nvme/hostnqn` from the old install, so the node's storage initiator
    identity is unchanged;
  - optionally partitions a second SSD (label `containers`, xfs) and mounts it
    at `/var/lib/containers` via a systemd mount unit plus a `restorecon` unit.
- A RHCOS metal image on the node (e.g. `/var/tmp/rhcos-metal.raw.gz`).
- Never commit the ignition file: it contains cluster credentials.

## Procedure

### 1. Install RHCOS to the SSD from the running node

```bash
sudo coreos-installer install /dev/disk/by-id/wwn-<ssd> \
  --ignition-file ~/node-ssd.ign \
  --copy-network \
  --image-file /var/tmp/rhcos-metal.raw.gz --insecure
```

### 2. Verify the ignition

The embedded rendered config must match the pool's current config:

```bash
oc get mcp master -o jsonpath='{.spec.configuration.name}'
```

Also check that the preserved iSCSI initiator name and NVMe hostid/hostnqn in
the ignition match the live node's files.

### 3. Drain the node

```bash
oc adm cordon <node>
oc adm drain <node> --ignore-daemonsets --delete-emptydir-data --force
```

If a VM won't live-migrate and can be stopped (dev VMs here):

```bash
virtctl stop <vm> -n <ns> --force --grace-period=0
```

Guard PDBs that show 0 allowed disruptions are just covering the cordoned
node's own replicas. They don't block anything.

### 4. Relabel the old disk's filesystems

Both disks now have filesystems labelled `boot` and `root`. The SSD's ESP
`grub.cfg` has no `bootuuid.cfg` and falls back to `search --label boot`, and
RHCOS requires the `boot` label to be unique. The old disk's ESP pins by UUID,
so it stays bootable after the relabel. Do this online, as root:

```bash
e2label /dev/<old>3 hdd-boot
xfs_io -c "label -s hdd-root" /var     # XFS online relabel via the mounted fs
```

See [`scripts/relabel-old-disk.sh`](scripts/relabel-old-disk.sh).

### 5. Add an EFI boot entry for the SSD

```bash
efibootmgr -c -d /dev/<ssd> -p 2 -L "RHCOS SSD" -l '\EFI\redhat\shimx64.efi'
```

This puts the new entry first in `BootOrder`. Keep the old entry as a fallback.

### 6. Remove the node's etcd member before rebooting

The SSD has an empty `/var/lib/etcd`, so remove the member and its certs first.
The cluster keeps running on the other 2 voters in the meantime.

```bash
# From an etcd pod on another control-plane node:
oc rsh -n openshift-etcd -c etcdctl etcd-<other-node>
etcdctl member list -w table
etcdctl member remove <etcd-member-id>
exit

oc delete secret -n openshift-etcd \
  etcd-peer-<node> etcd-serving-<node> etcd-serving-metrics-<node>
```

### 7. Reboot onto the SSD

```bash
sudo systemctl reboot
```

On first boot kubelet fails because the bootimage has no cri-o. This is
expected: `machine-config-daemon-firstboot` rebases to the cluster's node image
(adding cri-o and openshift-kubelet, a newer kernel and kargs) and reboots
again on its own.

### 8. Rejoin the cluster

```bash
ssh-keygen -R <node-ip>                 # the SSH host key has changed
oc get csr | grep Pending
oc adm certificate approve <csr-name>   # repeat for the serving CSR
```

Device names (`sdX`) may be reordered. That's harmless, because everything
references labels and UUIDs.

### 9. Restore the OVN chassis ID

`ovnkube-controller` goes into CrashLoopBackOff with:

```
admission webhook "node.network-node-identity.openshift.io" denied ...
k8s.ovn.org/node-chassis-id cannot be changed once set
```

The reinstall generated a new OVS `system-id`. Put the old one back:

```bash
OLD_ID=$(oc get node <node> -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/node-chassis-id}')
# On the node, as root:
echo "$OLD_ID" > /etc/openvswitch/system-id.conf
ovs-vsctl set Open_vSwitch . external_ids:system-id="$OLD_ID"
# Then restart ovnkube-node on that node:
oc delete pod -n openshift-ovn-kubernetes -l app=ovnkube-node \
  --field-selector spec.nodeName=<node>
```

The node goes `Ready`. See
[`scripts/restore-ovs-chassis-id.sh`](scripts/restore-ovs-chassis-id.sh).

### 10. Force the static-pod operators to reinstall

The etcd, kube-controller-manager and kube-scheduler operators still list the
node at its old `currentRevision`, so they never schedule an installer pod.
(kube-apiserver may come back only because an unrelated new revision happens
to roll out.) The CRD rejects lowering `currentRevision` ("must only
increase"), so remove the node's entry from the operator status instead.
Check the index first:

```bash
oc get etcd cluster -o jsonpath='{range .status.nodeStatuses[*]}{.nodeName}{" "}{.currentRevision}{"\n"}{end}'

oc patch etcd cluster --subresource=status --type=json -p '[
  {"op":"test","path":"/status/nodeStatuses/0/nodeName","value":"<node>"},
  {"op":"remove","path":"/status/nodeStatuses/0"}]'
```

The node controller re-adds the node at revision 0 and an installer runs. etcd
starts, receives a snapshot from the leader, and is promoted from learner to
voter. Repeat for `kubecontrollermanager` and `kubescheduler`. See
[`scripts/reset-operator-node-status.sh`](scripts/reset-operator-node-status.sh).

### 11. Verify, then uncordon

```bash
oc get co etcd kube-controller-manager kube-scheduler kube-apiserver
oc get pods -n openshift-etcd -o wide | grep <node>
oc rsh -n openshift-etcd -c etcdctl etcd-<node> etcdctl endpoint health --cluster
oc adm uncordon <node>
```

### 12. (Optional) Restore the etcd hardware speed

If etcd was set to `controlPlaneHardwareSpeed: Slower` because of the HDD,
switch it back to `Standard` once WAL fsync p99 is under about 4 ms on every
member:

```promql
histogram_quantile(0.99, sum by (instance, le) (rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])))
```

```bash
oc patch etcd cluster --type=merge -p '{"spec":{"controlPlaneHardwareSpeed":"Standard"}}'
```

## Gotchas

- **Duplicate `boot`/`root` labels**: relabel the old disk before rebooting
  (step 4). If you skip this, the SSD may boot the wrong `/boot` or fail to
  boot at all.
- **etcd member removal must happen before the reboot**: the new install has
  an empty data dir, and a stale member with old certs won't rejoin.
- **The first-boot "kubelet failure" is normal**: wait for the MCD firstboot
  rebase and the second reboot.
- **New OVS system-id**: the network-node-identity webhook blocks the chassis
  ID from changing. Restore the old one (step 9).
- **Static pods aren't reinstalled automatically**: the operators think the
  node is already at the current revision. Remove its `nodeStatuses` entry
  (step 10). Patching `currentRevision` down is rejected.
- **Don't uncordon early**: uncordoning before etcd, KCM and the scheduler
  were back let the scheduler flood the empty node (load average around 40),
  and the etcd installer then failed with
  `CreateContainerError: context deadline exceeded`. Cordoning again let it
  recover.
- **Live migration failures during drain**: force-stop VMs only if that's
  acceptable for those workloads.
- **The SSH host key changes**: run `ssh-keygen -R <node-ip>`.
- **`rotational=1` isn't reliable**: PERC RAID virtual disks always report as
  rotational, so measure fsync latency instead.
- **Storage identity**: carry over the iSCSI initiator name and NVMe
  hostid/hostnqn, or storage backends will see a new host.

## Final state

The node is `Ready` on the SSD, etcd has 3/3 healthy voters, all control-plane
static pods are running, and the old HDD is untouched as an EFI boot fallback.
