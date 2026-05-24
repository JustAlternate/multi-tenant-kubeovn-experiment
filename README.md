# Multi-Tenant KubeOVN Experiment

## Objective

Build a production-like multi-tenant Kubernetes environment on 3 Hetzner cloud nodes, using **KubeOVN** as the SDN overlay (logical switches, VPCs, subnet isolation).

**Stack:** Ubuntu 24.04 + kubeadm + KubeOVN (CNI)

## Success Metrics

- [x] 3-node cluster provisioned via Terraform + bash script, all nodes Ready
- [x] KubeOVN installed via Helm, OVN raft cluster healthy
- [ ] 3 isolated tenants created via KubeOVN VPCs/Subnets — pods in tenant A cannot reach pods in tenant B
- [ ] Cross-tenant communication via OVN logical routers (controlled, explicit)
- [ ] Cilium policy-only mode operational: Hubble shows flows, CiliumNetworkPolicy enforced

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

### Cilium Policy-Only Mode Concepts

- **CNI Chaining**: Cilium integrates with existing CNI via `cni.chainingMode=generic-veth`
- **Policy Audit Mode**: Deploy policies without enforcing (visibility first, then enforce)
- **Hubble**: Flow observability, service map, network policy verdicts
- **CiliumNetworkPolicy vs K8s NetworkPolicy**: CRD superset (L7, DNS, FQDN, entities)

### Resources

- [KubeOVN Documentation](https://kubeovn.github.io/docs/stable/en/)
- [OVN Architecture](https://www.ovn.org/en/architecture/)
- [Cilium CNI Chaining](https://docs.cilium.io/en/stable/network/concepts/chaining/)
- [KubeOVN + Cilium integration guide](https://kubeovn.github.io/docs/stable/en/advance/cilium-integration/)

---

## Phase 1 — Provision 3 Ubuntu Nodes on Hetzner

- [x] Provision 3 × Hetzner CAX11 (ARM 2 vCPU, 4 GB RAM, 40 GB SSD) via OpenTofu
- [x] Hetzner Cloud Network for private IPs (10.0.1.0/24)
- [x] Bootstrap script (`scripts/bootstrap-cluster.sh`) handles everything:
  - apt install containerd, kubeadm, kubelet, kubectl, helm, conntrack
  - Kernel modules: br_netfilter, overlay, openvswitch, geneve, vxlan
  - Sysctl: bridge-nf-call-iptables, ip_forward, IPv6 forwarding
  - Firewall: K8s ports + OVN ports (6641-6644) + private network (10.0.0.0/16)
  - Netplan config for enp7s0 (private network, MTU 1450)
  - kubeadm init + join, KubeOVN Helm install
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

## Phase 3 — Multi-Tenant Network Setup

### Target Topology

```
VPC tenant-a (10.35.0.0/16) ── Logical Switch "net-a" ── isolated
VPC tenant-b (10.36.0.0/16) ── Logical Switch "net-b" ── isolated
VPC tenant-c (10.37.0.0/16) ── Logical Switch "net-c" ── isolated
Default subnet (10.16.0.0/16) ──────────────────────────── infra (monitoring, flux)
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
- [ ] Deploy test pods in each tenant namespace (`nginx`)
- [ ] Verify:
  - Pods get IPs from their respective subnets (`kubectl get pod -o wide`)
  - 4 logical switches visible in OVN topology
- [ ] **Isolation test:** pod in tenant-a cannot ping pod in tenant-b
  - Different VPC = no route between logical switches
  - Verify egress from each tenant works (default route/gateway handles internet)
- [ ] (Optional) **Controlled cross-tenant routing:**
  - Create a logical router that connects two VPCs
  - Add static route or OVN ACL
  - Verify pod-A can now reach pod-B (controlled, explicit)

**Success:** Cross-tenant ping fails, same-tenant ping works, internet egress works

---

## Phase 4 — Cilium Policy-Only Mode

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
  - Pods still get KubeOVN IPs (Cilium not managing IPAM)
  - `cilium connectivity test` passes
- [ ] Enable Hubble UI:
  ```bash
  cilium hubble port-forward &
  # Browse to localhost:12000
  ```
- [ ] Deploy sample apps in tenant namespaces → observe flows in Hubble
- [ ] Write `CiliumNetworkPolicy` per tenant (default-deny + DNS egress)
- [ ] Verify enforcement:
  - `hubble observe` shows policy verdicts (ALLOWED / DENIED)
  - Cilium policy acts as a **second layer** on top of KubeOVN VPC isolation

**Success:** Hubble shows all flows with policy verdicts, CiliumNetworkPolicy enforced

---

## Phase 5 — LGTM Stack via FluxCD

- [ ] **Bootstrap FluxCD**
- [ ] **Grafana** — KubeOVN dashboards, Cilium dashboards, node metrics
- [ ] **Loki** — container logs via Promtail or Grafana Alloy
- [ ] **Mimir** — long-term metrics from kube-state-metrics + KubeOVN metrics
- [ ] **Alerting**: OVN DB leader changes, tunnel health, subnet IP exhaustion, CNI errors

**Success:** Grafana dashboards show KubeOVN + Cilium metrics, logs queryable in Loki

---

## Phase 6 — Chaos & Validation

- [ ] **Automated isolation test:** netshoot probe pods in all 3 tenant namespaces, ping sweep
- [ ] **Node failure:** stop kubelet on node-2, verify pods reschedule, OVN quorum OK
- [ ] **OVN control plane resilience:** kill ovn-central leader, measure election time (< 30s)
- [ ] **Cilium policy audit toggle:** audit mode shows "would be denied" in Hubble

**Success:** All chaos scenarios pass, tenant isolation intact throughout

---

## Phase 7 — Document & Tear Down

- [ ] ASCII diagram of the network topology (VPCs, logical switches, OVN routers)
- [ ] Screenshots: Hubble service map, Grafana KubeOVN dashboard
- [ ] Key learnings and pitfalls
- [ ] Tear down Hetzner instances when done

---

## Timeline

| Phase | Description | Est. Effort |
|-------|-------------|-------------|
| 0 | Concepts & reading | 2-3 days |
| 1 | Provision 3 Ubuntu nodes | 1 day |
| 2 | kubeadm + KubeOVN install | 1 day |
| 3 | Multi-tenant SDN setup | 1 day |
| 4 | Cilium policy-only + Hubble | 1 day |
| 5 | LGTM stack + FluxCD | 1-2 days |
| 6 | Chaos & validation | 1 day |
| 7 | Documentation & cleanup | 0.5 day |
| **Total** | | **7-9 days** |

---

## Infrastructure

### Nodes

| Node | Public IP | Private IP | Role |
|------|-----------|------------|------|
| node-1 | 178.105.181.208 | 10.0.1.11 | control-plane |
| node-2 | 178.105.184.10 | 10.0.1.12 | control-plane |
| node-3 | 178.105.178.225 | 10.0.1.13 | control-plane |

### Network

- Pod CIDR: `10.16.0.0/16`
- Service CIDR: `10.96.0.0/12`
- Join CIDR: `100.64.0.0/16`
- Private network: `10.0.0.0/16` (Hetzner Cloud Network)
- Tunnel type: GENEVE

### Key Commands

```bash
# Deploy infrastructure
cd iac && tofu apply

# Bootstrap cluster (provision + init + join + KubeOVN)
./scripts/bootstrap-cluster.sh all

# Individual steps
./scripts/bootstrap-cluster.sh provision
./scripts/bootstrap-cluster.sh init
./scripts/bootstrap-cluster.sh join
./scripts/bootstrap-cluster.sh kube-ovn
./scripts/bootstrap-cluster.sh verify

# Kubeconfig
export KUBECONFIG=$(pwd)/kubeconfig

# KubeOVN status
kubectl get pods -n kube-system
kubectl get nodes -o wide
kubectl get subnet
```

---

## Pitfalls Encountered

1. **OVN raft ports 6643/6644 must be open in firewall** — KubeOVN docs list 4 ports (6641-6644) but it's easy to miss the raft ports. Without them, ovn-central pods enter CrashLoopBackOff with "split-brain recovery" errors.
2. **NixOS broke Hetzner private networking** — nixos-infect replaced the network config and lost the private interface. Ubuntu works out of the box.
3. **`MASTER_NODES` must match node InternalIP** — If `ENABLE_BIND_LOCAL_IP=true`, the host IP must be in NODE_IPS. On Hetzner, InternalIP is the public IP.
4. **`kubectl ko` plugin not installed by default** — The KubeOVN Helm chart doesn't install the `kubectl ko` CLI helper. Use `ovn-nbctl` / `ovn-sbctl` inside ovn-central pods directly.
