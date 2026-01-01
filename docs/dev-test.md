# MicroShift HA Development and Testing

Fast iteration workflow for testing MicroShift multinode HA changes.

Target: Developers working on MicroShift internals
Reading time: ~8 minutes

## Prerequisites

- MicroShift source repository: https://github.com/openshift/microshift
- Test framework repository (this repo): https://github.com/microshift-io/microshift
- Containerized deployment environment (Podman)
- `make` and container build tools

## Build Requirements

**CRITICAL**: Build MicroShift with `MICROSHIFT_VARIANT=community`:
```bash
cd <microshift-source-path>
make build MICROSHIFT_VARIANT=community
```

Without `community` variant:
- No CA secrets published (kube-signer missing)
- Multinode effectively disabled
- Certificate sharing between nodes fails

## Fast Development Cycle

### dev-patch Target

Fastest iteration: patch running cluster with new binary.

```bash
# In test framework directory
make dev-patch USHIFT_LOCAL_PATH=<microshift-source-path>
```

What it does:
1. Copies fresh `microshift` binary from source repository
2. Rebuilds microshift-okd-dev image with new binary (--no-cache enforced)
3. Preserves container caches (no network pulls)
4. Does NOT restart cluster (manual restart required)

**Restart cluster after patch**:
```bash
make clean && make run ENABLE_HA=1 USHIFT_IMAGE=microshift-okd-dev
```

### Full Build Cycle

Complete rebuild when changing dependencies or Containerfile:

```bash
# 1. Build MicroShift binary
cd <microshift-source-path>
make build MICROSHIFT_VARIANT=community

# 2. Build container images
cd <test-framework-path>
make build-images USHIFT_LOCAL_PATH=<microshift-source-path>

# 3. Clean and run cluster
make clean && make run USHIFT_IMAGE=microshift-okd-dev

# 4. Wait for ready
make run-ready
```

## Network Configuration

Pod CIDR: `10.42.0.0/16` (Kubernetes pod network)
Service CIDR: `10.43.0.0/16` (Kubernetes service network)
Link-local: `169.254.169.1` (firewall trusted zone)
Node network: Dynamically allocated by podman (container subnet)
VIP: `<node-subnet>.100` (active after 2+ control planes)
LoadBalancer range: `<node-subnet>.101-<node-subnet>.199`

Node IPs follow pattern: `<node-subnet>.(node_id+10)`

## Multinode Cluster Setup

### Bootstrap (First Control Plane)

```bash
make run ENABLE_HA=1 USHIFT_IMAGE=microshift-okd-dev
make run-ready
```

Creates `microshift-okd-1` (first control plane) with HA enabled.
**IMPORTANT**: Use `ENABLE_HA=1` to enable multinode control plane support.

### Add First Worker

```bash
make add-node WORKER_ONLY=1 USHIFT_IMAGE=microshift-okd-dev
make run-ready
```

Creates `microshift-okd-2` (first worker)

### Add Second Control Plane

```bash
make add-node WORKER_ONLY=0 USHIFT_IMAGE=microshift-okd-dev
make run-ready
```

Creates `microshift-okd-3` (second control plane)
VIP becomes active after 2nd CP joins

### Add Second Worker

```bash
make add-node WORKER_ONLY=1 USHIFT_IMAGE=microshift-okd-dev
make run-ready
```

Creates `microshift-okd-4` (second worker)

### Add Third Control Plane

```bash
make add-node WORKER_ONLY=0 USHIFT_IMAGE=microshift-okd-dev
make run-ready
```

Creates `microshift-okd-5` (third control plane)

### Add Third Worker

```bash
make add-node WORKER_ONLY=1 USHIFT_IMAGE=microshift-okd-dev
make run-ready
```

Creates `microshift-okd-6` (third worker)

### Node Naming

Control Planes: okd-1, okd-3, okd-5
Workers: okd-2, okd-4, okd-6

## Firewall Ports

All required ports opened automatically via src/rpm/postinstall.sh:

**Control Plane ↔ Control Plane**:
```
2379, 2380          etcd client/peer
6443                kube-apiserver
9641, 9642          OVN NB/SB client
9643, 9644          OVN NB/SB RAFT
10250               kubelet
10256               kube-proxy health
10257               kube-controller-manager
10259               kube-scheduler
```

**Worker → Control Plane**:
Same ports except etcd (2379/2380) not needed from workers.

## Container Access

### Execute into Containers

```bash
podman exec -it microshift-okd-1 bash  # First control plane
podman exec -it microshift-okd-3 bash  # Second control plane
podman exec -it microshift-okd-5 bash  # Third control plane
```

## Debugging Tools

### etcd Inspection

```bash
# Inside container - built-in tool
microshift-etcd member list

# If etcdctl available (copy during dev-patch)
export ETCDCTL_API=3
export ETCDCTL_CACERT=/var/lib/microshift/certs/etcd-signer/ca.crt
export ETCDCTL_CERT=/var/lib/microshift/certs/etcd-signer/apiserver-etcd-client/client.crt
export ETCDCTL_KEY=/var/lib/microshift/certs/etcd-signer/apiserver-etcd-client/client.key
export ETCDCTL_ENDPOINTS=https://10.89.0.11:2379

etcdctl member list --write-out=table
etcdctl endpoint status --cluster --write-out=table
```

### OVN Status

```bash
kubectl exec -n openshift-ovn-kubernetes ovnkube-master-XXX -c nbdb -- \
  ovn-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound

kubectl exec -n openshift-ovn-kubernetes ovnkube-master-XXX -c sbdb -- \
  ovn-appctl -t /var/run/ovn/ovnsb_db.ctl cluster/status OVN_Southbound
```

### kube-vip Verification

```bash
# Check DaemonSet pods
kubectl get pod -n kube-vip -o wide

# Check VIP on br-ex (using node subnet .100)
podman exec microshift-okd-1 ip addr show br-ex

# Check LoadBalancer services
kubectl get svc --all-namespaces | grep LoadBalancer

# Cloud provider logs
kubectl logs -n kube-vip deployment/kube-vip-cloud-controller
```

## Outside Container Debugging

### Podman Commands

```bash
# List all containers
podman ps -a

# View container logs
podman logs microshift-okd-1

# Check resource usage
podman stats microshift-okd-1

# Inspect container
podman inspect microshift-okd-1 | jq '.[]
.NetworkSettings'
```

### Network Inspection

```bash
# List networks
podman network ls

# Inspect MicroShift network
podman network inspect microshift-net

# Check connectivity between containers
podman exec microshift-okd-1 ping -c 3 <target-container-ip>
```

## Image Caching

Container images cached locally:
- Base OKD images pulled once from quay.io
- Rebuilt images reuse layers
- dev-patch preserves full cache

Clear cache if needed:
```bash
podman system prune -a  # WARNING: Deletes all unused images
```

## Node Removal

**No automated remove-node**.

Manual process (requires care):
1. Drain node: `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`
2. Delete from K8s: `kubectl delete node <node>`
3. Remove etcd member (if CP): `etcdctl member remove <ID>`
4. Remove container: `podman rm -f microshift-okd-X`
5. Update cluster config on remaining nodes

## Parallel Node Addition

**NOT SUPPORTED**. Sequential only.

Adding nodes in parallel causes:
- etcd cluster formation races
- OVN RAFT join conflicts
- Certificate CSR approval timing issues

Always wait for `make run-ready` before adding next node.

## Makefile Targets

```bash
make build-images       # Build all container images
make dev-patch          # Fast patch with new binary
make run                # Start bootstrap node
make run-ready          # Wait for node ready
make add-node           # Add control plane or worker
make clean              # Destroy all containers (preserves images)
make logs               # Follow MicroShift logs
```

## Variables

```bash
USHIFT_LOCAL_PATH       # Path to microshift-dsm repo (required for builds)
USHIFT_IMAGE            # Image to use (default: microshift-okd, use microshift-okd-dev for dev)
WORKER_ONLY             # 0 for control plane, 1 for worker (default: 0)
```

## Troubleshooting

**Cluster won't start after dev-patch**:
Check binary variant: `strings _output/bin/microshift | grep BuildVariant`
Should show: `BuildVariant=community`

**Cannot add control plane**:
Error: "Cannot add control plane - bootstrap node not created with ENABLE_HA=1"
Solution: Recreate cluster with `make clean && make run ENABLE_HA=1`
Workers can join any cluster, but control planes require HA mode.

**Firewall blocking connections**:
Verify ports opened: `firewall-cmd --list-all` (inside container)
Or check src/rpm/postinstall.sh was executed

**etcdctl not found**:
Download on host, copy during dev-patch via packaging/microshift-dev-patch.Containerfile

**OVN split-brain**:
Check "Servers:" output from cluster/status on all pods
Should be identical. If different, network partition or 2-node issue.

**VIP not assigned**:
Check kube-vip DaemonSet pods running
Verify 2+ control planes exist (VIP needs HA)
Check br-ex interface exists with `ip addr show br-ex`

## Sample

```
> podman ps -a
CONTAINER ID  IMAGE                                COMMAND     CREATED            STATUS            PORTS       NAMES
d35fa7f02de2  localhost/microshift-okd-dev:latest  /sbin/init  3 hours ago        Up 3 hours                    microshift-okd-1
79df73b04e0c  localhost/microshift-okd-dev:latest  /sbin/init  2 hours ago        Up 2 hours                    microshift-okd-2
97447812de5e  localhost/microshift-okd-dev:latest  /sbin/init  2 hours ago        Up 2 hours                    microshift-okd-3
9701624ba964  localhost/microshift-okd-dev:latest  /sbin/init  About an hour ago  Up About an hour              microshift-okd-4
f9e14e054f54  localhost/microshift-okd-dev:latest  /sbin/init  About an hour ago  Up About an hour              microshift-okd-5
46b0caa02264  localhost/microshift-okd-dev:latest  /sbin/init  38 minutes ago     Up 38 minutes                 microshift-okd-6

> podman exec -it microshift-okd-1 bash -c 'oc get no -owide; echo; oc get po -A -owide'
NAME               STATUS   ROLES                         AGE    VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE          KERNEL-VERSION          CONTAINER-RUNTIME
microshift-okd-1   Ready    control-plane,master,worker   154m   v1.34.1   10.89.0.11    <none>        CentOS Stream 9   6.8.9-300.fc40.x86_64   cri-o://1.34.2-2.rhaos4.21.gitc8e8b46.el9
microshift-okd-2   Ready    worker                        122m   v1.34.1   10.89.0.12    <none>        CentOS Stream 9   6.8.9-300.fc40.x86_64   cri-o://1.34.2-2.rhaos4.21.gitc8e8b46.el9
microshift-okd-3   Ready    worker                        101m   v1.34.1   10.89.0.13    <none>        CentOS Stream 9   6.8.9-300.fc40.x86_64   cri-o://1.34.2-2.rhaos4.21.gitc8e8b46.el9
microshift-okd-4   Ready    worker                        88m    v1.34.1   10.89.0.14    <none>        CentOS Stream 9   6.8.9-300.fc40.x86_64   cri-o://1.34.2-2.rhaos4.21.gitc8e8b46.el9
microshift-okd-5   Ready    control-plane,master,worker   60m    v1.34.1   10.89.0.15    <none>        CentOS Stream 9   6.8.9-300.fc40.x86_64   cri-o://1.34.2-2.rhaos4.21.gitc8e8b46.el9
microshift-okd-6   Ready    control-plane,master,worker   36m    v1.34.1   10.89.0.16    <none>        CentOS Stream 9   6.8.9-300.fc40.x86_64   cri-o://1.34.2-2.rhaos4.21.gitc8e8b46.el9

NAMESPACE                              NAME                                        READY   STATUS    RESTARTS      AGE    IP           NODE               NOMINATED NODE   READINESS GATES
kube-system                            csi-snapshot-controller-f7998d4c7-c6djf     1/1     Running   0             154m   10.42.0.4    microshift-okd-1   <none>           <none>
kube-vip                               kube-vip-cloud-controller-99d56b46d-8hcb8   1/1     Running   0             59m    10.42.0.9    microshift-okd-1   <none>           <none>
kube-vip                               kube-vip-spn6p                              1/1     Running   0             57m    10.89.0.15   microshift-okd-5   <none>           <none>
kube-vip                               kube-vip-tlt89                              1/1     Running   0             33m    10.89.0.16   microshift-okd-6   <none>           <none>
kube-vip                               kube-vip-vnnmb                              1/1     Running   1 (57m ago)   59m    10.89.0.11   microshift-okd-1   <none>           <none>
openshift-dns                          dns-default-5n7kx                           2/2     Running   0             33m    10.42.5.3    microshift-okd-6   <none>           <none>
openshift-dns                          dns-default-68flb                           2/2     Running   0             154m   10.42.0.8    microshift-okd-1   <none>           <none>
openshift-dns                          dns-default-6lmfr                           1/2     Running   0             119m   10.42.1.3    microshift-okd-2   <none>           <none>
openshift-dns                          dns-default-jqq72                           1/2     Running   0             88m    10.42.3.3    microshift-okd-4   <none>           <none>
openshift-dns                          dns-default-p9lhj                           2/2     Running   0             57m    10.42.4.3    microshift-okd-5   <none>           <none>
openshift-dns                          dns-default-zcg5f                           1/2     Running   0             98m    10.42.2.3    microshift-okd-3   <none>           <none>
openshift-dns                          node-resolver-26lxm                         1/1     Running   0             122m   10.89.0.12   microshift-okd-2   <none>           <none>
openshift-dns                          node-resolver-4kksl                         1/1     Running   0             59m    10.89.0.15   microshift-okd-5   <none>           <none>
openshift-dns                          node-resolver-4qtdj                         1/1     Running   0             154m   10.89.0.11   microshift-okd-1   <none>           <none>
openshift-dns                          node-resolver-8hvlq                         1/1     Running   0             101m   10.89.0.13   microshift-okd-3   <none>           <none>
openshift-dns                          node-resolver-flw2m                         1/1     Running   0             88m    10.89.0.14   microshift-okd-4   <none>           <none>
openshift-dns                          node-resolver-gnmmn                         1/1     Running   0             36m    10.89.0.16   microshift-okd-6   <none>           <none>
openshift-ingress                      router-default-dd5dc96b5-fdkdx              1/1     Running   0             154m   10.42.0.7    microshift-okd-1   <none>           <none>
openshift-operator-lifecycle-manager   catalog-operator-77fff445d7-6xwrz           1/1     Running   0             154m   10.42.0.5    microshift-okd-1   <none>           <none>
openshift-operator-lifecycle-manager   olm-operator-55f9776dc7-85qc2               1/1     Running   0             154m   10.42.0.6    microshift-okd-1   <none>           <none>
openshift-ovn-kubernetes               ovnkube-master-4kw5f                        4/4     Running   4 (34m ago)   36m    10.89.0.16   microshift-okd-6   <none>           <none>
openshift-ovn-kubernetes               ovnkube-master-9r7rl                        4/4     Running   0             33m    10.89.0.15   microshift-okd-5   <none>           <none>
openshift-ovn-kubernetes               ovnkube-master-glbzt                        4/4     Running   0             36m    10.89.0.11   microshift-okd-1   <none>           <none>
openshift-ovn-kubernetes               ovnkube-node-6qhmg                          2/2     Running   0             32m    10.89.0.15   microshift-okd-5   <none>           <none>
openshift-ovn-kubernetes               ovnkube-node-8trdf                          2/2     Running   0             36m    10.89.0.16   microshift-okd-6   <none>           <none>
openshift-ovn-kubernetes               ovnkube-node-98sml                          2/2     Running   0             33m    10.89.0.12   microshift-okd-2   <none>           <none>
openshift-ovn-kubernetes               ovnkube-node-c8c98                          2/2     Running   0             33m    10.89.0.11   microshift-okd-1   <none>           <none>
openshift-ovn-kubernetes               ovnkube-node-cxrwt                          2/2     Running   0             33m    10.89.0.13   microshift-okd-3   <none>           <none>
openshift-ovn-kubernetes               ovnkube-node-f9khl                          2/2     Running   0             36m    10.89.0.14   microshift-okd-4   <none>           <none>
openshift-service-ca                   service-ca-8478bdfd58-blq9n                 1/1     Running   0             154m   10.42.0.3    microshift-okd-1   <none>           <none>
```
