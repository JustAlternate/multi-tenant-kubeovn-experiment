# Multi-Tenant KubeVirt + KubeOVN Lab

## Objective

Build a multi-tenant Kubernetes platform on 3 Hetzner cloud nodes:
**KubeOVN** as the SDN overlay (VPCs, subnet isolation, EIP) + **KubeVirt** for tenant
VMs + **Cilium** policy-only mode for perimeter observability.

**Stack:** Ubuntu 24.04 + kubeadm + KubeOVN (CNI) + KubeVirt (VMs) + Cilium (policy/Hubble)

## Hardware & KubeVirt performance

Nodes: 3 × Hetzner **CPX22** (x86, 2 vCPU / 4 GB / 80 GB) in `fsn1`, ~€13.77/mo total.

I decided to not go with bare metal nodes because of the lack of flexibility for provisionning them and their high price.

Problem is that Hetzner cloud VMs do **not** expose nested KVM. KubeVirt is therefore running with
`useEmulation: true` (QEMU TCG software emulation). VMs boot in ~20-30s (cirros) and
CPU is emulated. This is acceptable for a lab because the goal is to exercise the
**API surface and integration topology** (KubeVirt CRDs, KubeOVN subnet binding, Cilium
perimeter visibility), not to measure VM performance.

## Success Metrics

- [x] 3-node cluster provisioned via OpenTofu + bash script, all nodes Ready
- [x] KubeOVN installed via Helm, OVN raft cluster healthy
- [x] KubeVirt operator installed, a test cirros VM boots and gets an IP from `ovn-default`
- [ ] 3 isolated tenants: each tenant has a Vpc + Subnet + 1 VirtualMachine
- [ ] Tenant isolation: VM in tenant-A cannot reach VM in tenant-B
- [ ] Tenant egress: a VM is reachable from outside via KubeOVN EIP/FloatingIP
- [ ] Cilium policy-only mode operational: Hubble shows flows at veth boundary
- [ ] Write-up: topology diagram + the inside-VM visibility boundary doc

---

## Phase 0 — Learn the Concepts

Before touching any infrastructure.

### KubeOVN Concepts

- **OVN Architecture**: ovn-central (NB/SB databases), ovn-controller, ovs-vswitchd, ovsdb-server
- **Logical Switch**: Layer-2 broadcast domain, maps 1:1 to a KubeOVN Subnet
- **Logical Router**: L3 routing between switches, maps to KubeOVN Vpc or default router
- **Subnet CRD**: K8s-native subnet definition (CIDR, gateway, excludeIPs, namespace binding)
- **Vpc CRD**: Multi-tenant isolation primitive — owns subnets, exposes NAT gateways
- **Distributed Gateway**: OVN distributes routing to each node (no single chokepoint)
- **GENEVE Overlay**: KubeOVN uses GENEVE (not VXLAN) for cross-node encapsulation
- **kube-ovn-controller / kube-ovn-cni / ovn0 interface**: DaemonSet components
- **IPAM**: KubeOVN manages IP allocation per Subnet (not default K8s IPAM)
- **SNAT / DNAT / EIP / FloatingIP**: NAT primitives for external traffic
- **ACL / SecurityGroup**: OVN-native ACLs (coexist with K8s NetworkPolicy)
- **QoS**: Bandwidth limits per pod via Subnet annotations

### KubeVirt Concepts

- **VirtualMachine vs VirtualMachineInstance**: VM is declarative/stop-start, VMI is the running instance
- **virt-launcher pod**: every VMI runs inside a `virt-launcher` pod; from the CNI's point of view a VM is just a pod
- **kube-ovn binding**: KubeVirt attaches the VM's tap interface to the KubeOVN-managed pod veth → VM gets an IP from the Subnet, VPC isolation applies transparently

### Cilium Policy-Only Mode Concepts

- **CNI Chaining**: Cilium integrates with existing CNI via `cni.chainingMode=generic-veth`
- **Policy Audit Mode**: Deploy policies without enforcing (visibility first, then enforce)
- **Hubble**: Flow observability, service map, network policy verdicts
- **CiliumNetworkPolicy vs K8s NetworkPolicy**: CRD superset (L7, DNS, FQDN, entities)
- **KubeVirt boundary**: Cilium sees the `virt-launcher` pod at the veth outer side. Inside-VM L4/L7 flows are **opaque** to Hubble (separate kernel). Cilium identity is per-pod, not per-VM-process.

### Resources

- [KubeOVN Documentation](https://kubeovn.github.io/docs/stable/en/)
- [OVN Architecture](https://www.ovn.org/en/architecture/)
- [Cilium CNI Chaining](https://docs.cilium.io/en/stable/network/concepts/chaining/)
- [KubeOVN + Cilium integration guide](https://kubeovn.github.io/docs/stable/en/advance/cilium-integration/)
- [KubeVirt Documentation](https://kubevirt.io/user-guide/)
- [KubeOVN + KubeVirt integration](https://kubeovn.github.io/docs/stable/en/advance/kubevirt/)

---

## Phase 1 — Provision 3 Ubuntu Nodes on Hetzner

- [x] Provision 3 × Hetzner CPX22 (x86 2 vCPU, 4 GB RAM, 80 GB SSD) via OpenTofu
- [x] Hetzner Cloud Network for private IPs (10.0.1.0/24)
- [x] Bootstrap script (`scripts/bootstrap-cluster.sh`) handles everything:
  - apt install containerd, kubeadm, kubelet, kubectl, helm, conntrack
  - Kernel modules: br_netfilter, overlay, openvswitch, geneve, vxlan
  - Sysctl: bridge-nf-call-iptables, ip_forward, IPv6 forwarding
  - Firewall: K8s ports + OVN ports (6641-6644) + private network (10.0.0.0/16)
  - Netplan config for enp7s0 (private network, MTU 1450)
  - kubeadm init + join, KubeOVN Helm install, KubeVirt operator install
- [x] Verify: SSH to all 3 nodes, private IPs reachable between nodes

---

## Phase 2 — Install Kubernetes with kubeadm + KubeOVN

- [x] **Init control plane** (node-1):
  - `controlPlaneEndpoint: <public-ip>:6443`
  - `podSubnet: 10.16.0.0/16`, `serviceSubnet: 10.96.0.0/12`
  - `advertiseAddress: <public-ip>` (Hetzner nodes have public IPs available)
- [x] **Join control plane** (node-2, node-3): `kubeadm join ... --control-plane`
- [x] **Install KubeOVN** via Helm (`kubeovn/kube-ovn` v1.16.1):
  - `MASTER_NODES: "<pub1>,<pub2>,<pub3>"` — must match node InternalIP
  - `ENABLE_BIND_LOCAL_IP: true` — OVN binds to node IP
  - `NETWORK_TYPE: geneve`, `TUNNEL_TYPE: geneve`
  - `POD_CIDR: 10.16.0.0/16`, `SVC_CIDR: 10.96.0.0/12`
  - Label all nodes: `kube-ovn/role=master`
- [x] Validate:
  - `kubectl get nodes` → 3/3 Ready
  - `kubectl get subnet` → `ovn-default` and `join` subnets created
  - All pods in `kube-system` Running (ovn-central, ovs-ovn, kube-ovn-controller, kube-ovn-cni, kube-ovn-pinger, coredns)

---

## Phase 3 — KubeVirt Operator + First VM

Goal: prove KubeVirt attaches a VM to a KubeOVN subnet before going multi-tenant.

- [x] Install KubeVirt operator (v1.8.4) with `useEmulation: true` (no `/dev/kvm` on Hetzner cloud)
- [x] Patch KubeVirt CR with control-plane toleration (lab cluster has no workers)
- [x] Untaint control-plane nodes so `virt-launcher` pods can schedule
- [x] Create a `VirtualMachine` in the `default` namespace using a cirros `containerDisk`
- [x] Verify:
  - `virt-launcher` pod Running (3 containers: compute + containerDisk sidecar + init containers)
  - VMI reaches `Running` state
  - VM gets an IP from `10.16.0.0/16` (`kubectl get vmi -o wide`)
  - VM appears in OVN NB as a port on `ovn-default` switch (`ovn-nbctl show`)
  - `virtctl console` reaches the VM serial console

**Success:** cirros VM `vm-cirros-test` boots on node-1, gets IP `10.16.0.17` from KubeOVN's
`ovn-default` subnet, OVN shows it as port `vm-cirros-test.default` with MAC `42:4c:1d:89:4d:a4`.

---

## Phase 4 — Multi-Tenant Network Setup (VPCs + VMs)

### Target Topology

```
VPC tenant-a (10.35.0.0/16) ── Logical Switch "net-a" ── VM-a isolated
VPC tenant-b (10.36.0.0/16) ── Logical Switch "net-b" ── VM-b isolated
VPC tenant-c (10.37.0.0/16) ── Logical Switch "net-c" ── VM-c isolated
Default subnet (10.16.0.0/16) ──────────────────────────── infra
```

- [ ] Create namespaces: `lab-tenant-a`, `lab-tenant-b`, `lab-tenant-c`
- [ ] Create `Vpc` CRDs:
  ```yaml
  apiVersion: kubeovn.io/v1
  kind: Vpc
  metadata:
    name: vpc-tenant-a
  spec:
    namespaces:
      - lab-tenant-a
  ```
- [ ] Create `Subnet` CRDs:
  ```yaml
  apiVersion: kubeovn.io/v1
  kind: Subnet
  metadata:
    name: subnet-tenant-a
  spec:
    vpc: vpc-tenant-a
    cidrBlock: 10.35.0.0/16
    gateway: 10.35.0.1
    namespaces:
      - lab-tenant-a
  ```
- [ ] Deploy one `VirtualMachine` per tenant namespace
- [ ] Verify:
  - Each VM gets an IP from its tenant subnet
  - 4 logical switches visible in OVN topology
- [ ] **Isolation test:** VM in tenant-a cannot ping VM in tenant-b
  - Different VPC = no route between logical switches

**Success:** Cross-tenant ping fails, same-tenant ping works, internet egress works.

---

## Phase 5 — Tenant Egress (EIP / FloatingIP)

Goal: a tenant VM is reachable from outside the cluster.

- [ ] Enable KubeOVN EIP/SNAT (`func.ENABLE_EIP_SNAT: true` already set in values)
- [ ] Allocate a `SwitchBean` external subnet / loadBalancer on the underlay
- [ ] Create an `Eip` CRD for VM-a → external IP bound to the VM's pod IP
- [ ] Create a `FloatingIP` rule associating EIP ↔ VM IP (DNAT inbound + SNAT outbound)
- [ ] Verify: from your laptop, `ssh`/`nc` to the EIP reaches the VM
- [ ] Verify: VM egress to internet uses the EIP (SNAT)

**Success:** A tenant VM is reachable from the outside via a KubeOVN-managed floating IP.

---

## Phase 6 — Cilium Policy-Only Mode (Perimeter)

- [ ] Install Cilium Helm repo
- [ ] Deploy Cilium in chaining mode:
  ```bash
  helm install cilium cilium/cilium \
    --namespace kube-system \
    --set routingMode=native \
    --set cni.chainingMode=generic-veth \
    --set cni.chainingTarget=kube-ovn \
    --set cni.exclusive=false \
    --set policyEnforcementMode=default \
    --set hubble.enabled=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true
  ```
- [ ] Verify coexistence:
  - `cilium status` — all agents OK
  - VMs still get KubeOVN IPs (Cilium not managing IPAM)
  - `cilium connectivity test` passes (against non-VM pods)
- [ ] Enable Hubble UI:
  ```bash
  cilium hubble port-forward &
  # Browse to localhost:12000
  ```
- [ ] Observe flows hitting `virt-launcher` pods in Hubble
- [ ] Write `CiliumNetworkPolicy` per tenant (default-deny + DNS egress at the pod level)
- [ ] Verify enforcement:
  - `hubble observe` shows policy verdicts (ALLOWED / DENIED) at the veth boundary
  - Cilium policy acts as a **second layer** on top of KubeOVN VPC isolation

**Success:** Hubble shows perimeter flows with policy verdicts, CiliumNetworkPolicy enforced on `virt-launcher` pods.

---

## Phase 7 — Write-up: Topology + Visibility Boundary

- [ ] **ASCII diagram** of the topology: 3 nodes, GENEVE tunnels, 3 tenant VPCs, logical switches, EIP path, Cilium enforcement points
- [ ] **Screenshots**: Hubble flows hitting `virt-launcher` pods, KubeOVN `kubectl get vpc/subnet`, a booted VM
- [ ] **Visibility boundary doc** :
  - What Cilium/Hubble sees: perimeter flows, pod identity, policy verdicts at the veth
  - What Cilium/Hubble cannot see: inside-VM L4/L7 flows (separate kernel, eBPF cannot attach)
  - What KubeOVN sees: L2-L4 on the veth, ACLs enforced at OVN level
  - Inside-VM observability requires guest agents (qemu-guest-agent, opt-in sidecar) → customer-side concern, not platform-side
  - Implications for a SecNumCloud audit: platform can guarantee tenant isolation + perimeter policy; cannot guarantee inside-VM observability without customer opt-in
- [ ] Key learnings and pitfalls
- [ ] Tear down Hetzner instances when done

---

## Infrastructure

### Nodes

| Node | Public IP | Private IP | Role | Server type |
|------|-----------|------------|------|-------------|
| node-1 | 91.98.40.77 | 10.0.1.11 | control-plane | Hetzner CPX22 (fsn1) |
| node-2 | 91.98.37.139 | 10.0.1.12 | control-plane | Hetzner CPX22 (fsn1) |
| node-3 | 178.105.200.24 | 10.0.1.13 | control-plane | Hetzner CPX22 (fsn1) |

IPs are outputs of `tofu output` and templated into `MASTER_NODES` by the bootstrap script — the values file carries a `PLACEHOLDER`.

### Network

- Pod CIDR: `10.16.0.0/16`
- Service CIDR: `10.96.0.0/12`
- Join CIDR: `100.64.0.0/16`
- Private network: `10.0.0.0/16` (Hetzner Cloud Network)
- Tunnel type: GENEVE
- Tenant VPCs (Phase 4): `10.35.0.0/16`, `10.36.0.0/16`, `10.37.0.0/16`

### KubeVirt

- Version: `v1.8.4` (pinned in `scripts/bootstrap-cluster.sh:KUBEVIRT_VERSION`)
- Mode: `useEmulation: true` (QEMU TCG, no nested KVM on Hetzner cloud)
- Feature gates: `LiveMigration` (enabled but inert without KVM)
- Control-plane toleration baked into `k8s/kubevirt-cr.yaml` (lab has no workers)
- `virtctl` binary installed at `bin/virtctl` (gitignored, arch-detected)

### Key Commands

```bash
# Deploy infrastructure
cd iac && tofu apply

# Bootstrap cluster (provision + init + join + KubeOVN + untaint + KubeVirt)
./scripts/bootstrap-cluster.sh all

# Individual steps
./scripts/bootstrap-cluster.sh provision
./scripts/bootstrap-cluster.sh init
./scripts/bootstrap-cluster.sh join
./scripts/bootstrap-cluster.sh kube-ovn
./scripts/bootstrap-cluster.sh untaint
./scripts/bootstrap-cluster.sh kubevirt
./scripts/bootstrap-cluster.sh verify

# Kubeconfig
export KUBECONFIG=$(pwd)/kubeconfig

# KubeOVN status
kubectl get pods -n kube-system
kubectl get nodes -o wide
kubectl get subnet
kubectl get vpc

# KubeVirt status
kubectl get kubevirt -n kube-system
kubectl get vmi -A -o wide
./bin/virtctl console <vmi-name> -n <tenant-ns>
```

---

## Pitfalls Encountered

1. **OVN raft ports 6643/6644 must be open in firewall** — KubeOVN docs list 4 ports (6641-6644) but it's easy to miss the raft ports. Without them, ovn-central pods enter CrashLoopBackOff with "split-brain recovery" errors.
2. **NixOS broke Hetzner private networking** — nixos-infect replaced the network config and lost the private interface. Ubuntu works out of the box.
3. **`MASTER_NODES` must match node InternalIP** — If `ENABLE_BIND_LOCAL_IP=true`, the host IP must be in NODE_IPS. On Hetzner, InternalIP is the public IP. The bootstrap script now templates this from `tofu output` so you never edit the values file by hand.
4. **`kubectl ko` plugin not installed by default** — The KubeOVN Helm chart doesn't install the `kubectl ko` CLI helper. Use `ovn-nbctl` / `ovn-sbctl` inside ovn-central pods directly. Note: `ovn-nbctl`/`ovn-sbctl` need an explicit `--db=unix:/var/run/ovn/ovnnb_db.sock` (or `ovnsb_db.sock`) — the default socket lookup doesn't find KubeOVN's layout.
5. **Hetzner CAX11 (ARM) capacity-constrained** — At provisioning time, CAX11 was `resource_unavailable` across nbg1, fsn1, hel1. Switched to CPX22 (x86, slightly more expensive but in stock). x86 also means `kubevirt/cirros-container-disk-demo` works out of the box (no arm64 image build needed).
6. **virt-handler doesn't tolerate control-plane taint by default** — In an all-control-plane lab cluster (no workers), `virt-handler` DaemonSet and `virt-launcher` pods won't schedule. Two fixes needed: (a) add a toleration to `spec.workloads.nodePlacement.tolerations` in the KubeVirt CR, (b) untaint the nodes themselves (`kubectl taint node node-X node-role.kubernetes.io/control-plane:NoSchedule-`). Both are scripted in `bootstrap-cluster.sh` (`untaint` and `kubevirt` steps).
