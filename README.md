# Multi-Tenant KubeOVN + Cilium Experiment

## Objective

Build a production-like multi-tenant Kubernetes environment on 3 Hetzner cloud nodes, using **KubeOVN** as the SDN overlay (logical switches, VPCs, subnet isolation) with **Cilium in policy-only mode** for advanced network policies and Hubble observability.

**Stack:** kubeadm + KubeOVN (CNI) + Cilium (policy-only) 

## Success Metrics

- [ ] 3-node HA cluster provisioned via Terraform and NixOS + kubeadm and kube-vip, all nodes Ready
- [ ] KubeOVN installed as primary CNI, OVN control plane healthy
- [ ] 3 isolated tenants created via KubeOVN VPCs/Subnets — pods in tenant A cannot reach pods in tenant B
- [ ] Cross-tenant communication via OVN logical routers (controlled, explicit)
- [ ] Cilium policy-only mode operational: Hubble shows flows, CiliumNetworkPolicy enforced
- [ ] OVN traffic visible in Hubble (Cilium observes KubeOVN-managed pods)

---

## Phase 0 — Learn the Concepts (`2-3 days`)

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
- **Endpoint Identity**: Cilium assigns identity labels to pods (used in policy enforcement)

### OVN Underlay / Debugging

- `ovn-nbctl`, `ovn-sbctl`, `ovs-vsctl` — debugging commands
- `kubectl ko` — KubeOVN CLI helper (wraps kubectl + ovn commands)

### Resources

- [KubeOVN Documentation](https://kubeovn.github.io/docs/stable/en/)
- [OVN Architecture](https://www.ovn.org/en/architecture/)
- [Cilium CNI Chaining](https://docs.cilium.io/en/stable/network/concepts/chaining/)
- [KubeOVN + Cilium integration guide](https://kubeovn.github.io/docs/stable/en/advance/cilium-integration/)

---

## Phase 1 — Provision 3 NixOS Nodes on Hetzner

- [X] Create a reproducible `nixosConfigurations` in `./flake.nix` with the minimal required configuration for the nodes to install kubernetes and kube-ovn.
- [X] Provision 3 × Hetzner CAX22 (ARM 2 vCPU, 4 GB RAM, 40 GB SSD) with opentofu Hetzner provider
- [X] Verify:
  - SSH to all 3 nodes
  - Private IPs reachable between all nodes
  - Hostnames resolve (node-1, node-2, node-3)

---

## Phase 2 — Install Kubernetes with kubeadm + KubeOVN

- [X] Install container runtime: `containerd`
  - Verify with `crictl ps`
- [ ] Install `pkgs.kubeadm`, `pkgs.kubelet`, `pkgs.kubectl` via NixOS
  - Configure kubelet extra args: `--node-ip=<private-ip>`, `--cgroup-driver=systemd`
  - Enable kubelet systemd service
- [ ] **Init control plane** (node 1):
  ```
  kubeadm init \
    --pod-network-cidr=10.16.0.0/16 \
    --apiserver-advertise-address=<private-ip> \
    --upload-certs
  ```
  - Copy kubeconfig: `mkdir ~/.kube && cp /etc/kubernetes/admin.conf ~/.kube/config`
- [ ] **Join workers** (node 2, node 3): `kubeadm join ...`
- [ ] **Install KubeOVN**:
  ```bash
  kubectl apply -f https://raw.githubusercontent.com/kubeovn/kube-ovn/release-1.13/dist/images/install.sh
  # Or use Helm for more control
  ```
  - Wait for: `ovn-central`, `ovs-ovn`, `kube-ovn-controller`, `kube-ovn-cni` DaemonSets to be Running
  - Verify: `kubectl get pods -n kube-system`
- [ ] Validate:
  - `kubectl get nodes` → 3/3 Ready
  - `kubectl ko nbctl show` → OVN logical topology visible
  - `kubectl get subnet` → default subnet created
  - Deploy test pod → IP from `10.16.0.0/16`
  - pod-to-pod ping across nodes → works

**Success:** `kubectl get nodes` shows 3 Ready, `kubectl ko nbctl show` shows OVN topology

---

## Phase 3 — Multi-Tenant Network Setup (`1 day`)

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
      # pods in lab-tenant-a auto-join this subnet
  ```
- [ ] Deploy test pods in each tenant namespace (`nginx`)
- [ ] Verify:
  - Pods get IPs from their respective subnets (`kubectl get pod -o wide`)
  - `kubectl ko nbctl show` → 4 logical switches visible
- [ ] **Isolation test:** pod in tenant-a cannot ping pod in tenant-b
  - Different VPC = no route between logical switches
  - Verify egress from each tenant works (default route/gateway handles internet)
- [ ] (Optional) **Controlled cross-tenant routing:**
  - Create a logical router that connects two VPCs
  - Add static route or OVN ACL
  - Verify pod-A can now reach pod-B (controlled, explicit)

**Success:** Cross-tenant ping fails, same-tenant ping works, internet egress works

---

## Phase 4 — Cilium Policy-Only Mode (`1 day`)

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
  - `cilium connectivity test` passes (uses existing KubeOVN networking)
- [ ] Enable Hubble UI:
  ```bash
  cilium hubble port-forward &
  # Browse to localhost:12000
  ```
- [ ] Deploy sample apps in tenant namespaces → observe flows in Hubble
- [ ] Write `CiliumNetworkPolicy` per tenant:
  ```yaml
  apiVersion: cilium.io/v2
  kind: CiliumNetworkPolicy
  metadata:
    name: tenant-a-default-deny
    namespace: lab-tenant-a
  spec:
    endpointSelector: {}
    ingress:
      - fromEndpoints:
          - matchLabels:
              k8s:io.kubernetes.pod.namespace: lab-tenant-a
    egress:
      - toEndpoints:
          - matchLabels:
              k8s:io.kubernetes.pod.namespace: kube-system
            toPorts:
              - ports:
                  - port: "53"
                    protocol: UDP
  ```
- [ ] Verify enforcement:
  - `hubble observe` shows policy verdicts (ALLOWED / DENIED)
  - Test: pod in tenant-a-ns cannot reach another pod in tenant-a-ns if policy denies it
  - Cilium policy acts as a **second layer** on top of KubeOVN VPC isolation

**Success:** Hubble shows all flows with policy verdicts, CiliumNetworkPolicy enforced

---

## Phase 5 — LGTM Stack via FluxCD (`1-2 days`)

- [ ] **Bootstrap FluxCD**:
  ```bash
  flux bootstrap github \
    --owner=<github-user> \
    --repository=multi-tenant-KubeOVN-cilium-experiment \
    --path=./clusters/lab
  ```
- [ ] **Grafana** — deploy via Flux `HelmRelease`
  - Import KubeOVN dashboards (community: Kube-OVN overview, OVN DB, OVS)
  - Import Cilium dashboards (Hubble metrics, policy verdicts)
  - Import node metrics (Node Exporter)
- [ ] **Loki** — ship container logs via Promtail or Grafana Alloy
  - Configure LogQL queries for OVN components
- [ ] **Mimir** — long-term metrics from kube-state-metrics + KubeOVN metrics
  - Scrape `/metrics` from `ovn-central`, `ovs-ovn`, `kube-ovn-controller`
- [ ] **Alerting**:
  - OVN DB leader changes
  - Tunnel health between nodes
  - Subnet IP exhaustion (>80% used)
  - Pod creation failures (CNI errors)

**Success:** Grafana dashboards show KubeOVN + Cilium metrics, logs queryable in Loki

---

## Phase 6 — Chaos & Validation (`1 day`)

- [ ] **Automated isolation test:**
  - Script that deploys `netshoot` probe pods in all 3 tenant namespaces
  - Continuous ping sweep: A→B, A→C, B→A, B→C, C→A, C→B
  - Expected: all pings fail (0% success)
  - In-tenant ping: A-pod1→A-pod2 passes
- [ ] **Node failure:**
  - Stop kubelet on node 2
  - Verify: pods rescheduled, KubeOVN IPAM reallocates correctly
  - Verify: OVN control plane healthy (2/3 ovn-central remaining, quorum OK)
  - Verify: tenant isolation still enforced on remaining 2 nodes
  - Restore node 2 → verify rejoin
- [ ] **OVN control plane resilience:**
  - Kill ovn-central pod on the current leader
  - Measure time to new leader election (< 30s target)
  - Verify: no pod connectivity disruption during election
  - Verify: new pods can still be scheduled
- [ ] **Cilium policy audit toggle:**
  - Set `policyEnforcementMode=audit` on a CiliumNetworkPolicy
  - Verify Hubble shows "would be denied" (audit mode)
  - Set back to `enforcing` → verify actual drops

**Success:** All chaos scenarios pass, tenant isolation intact throughout

---

## Phase 7 — Document & Tear Down (`0.5 day`)

- [ ] ASCII diagram of the network topology (VPCs, logical switches, OVN routers)
- [ ] Screenshots: Hubble service map, Grafana KubeOVN dashboard
- [ ] Key learnings and pitfalls
- [ ] Tear down Hetzner instances when done

---

## Timeline

| Phase | Description | Est. Effort |
|-------|-------------|-------------|
| 0 | Concepts & reading | 2-3 days |
| 1 | Provision 3 NixOS nodes | 1 day |
| 2 | kubeadm + KubeOVN install | 1-2 days |
| 3 | Multi-tenant SDN setup | 1 day |
| 4 | Cilium policy-only + Hubble | 1 day |
| 5 | LGTM stack + FluxCD | 1-2 days |
| 6 | Chaos & validation | 1 day |
| 7 | Documentation & cleanup | 0.5 day |
| **Total** | | **8-10 days** |

---

## Success Metrics Summary

| # | Metric | How to verify |
|---|--------|---------------|
| 1 | 3 nodes Ready | `kubectl get nodes` |
| 2 | KubeOVN topology healthy | `kubectl ko nbctl show` → 4 logical switches |
| 3 | Tenant isolation verified | Script: 0 cross-tenant reachability |
| 4 | Hubble sees all flows | `hubble observe` → flows + policy verdicts |
| 5 | CiliumNetworkPolicy enforced | Default-deny per tenant, DNS egress allowed |
| 6 | LGTM stack operational | Grafana dashboards populated with metrics |
| 7 | OVN HA functional | Leader election after kill `ovn-central` |
| 8 | Everything deployed via FluxCD | `flux get all` → all resources synced |
