#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
IAC_DIR="$REPO_DIR/iac"

POD_CIDR="10.16.0.0/16"
SVC_CIDR="10.96.0.0/12"
K8S_VERSION="1.31"
KUBEVIRT_VERSION="v1.8.4"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o UpdateHostKeys=no -o ConnectTimeout=10"

log()  { echo "==> $*"; }
ssh_cmd() { ssh $SSH_OPTS "root@$1" "${@:2}"; }
scp_file() { scp $SSH_OPTS "$1" "root@$2:$3"; }

load_hosts() {
  log "Reading node IPs from terraform state..."
  NODE1_PUB=$(cd "$IAC_DIR" && tofu output -raw node_1_ip)
  NODE2_PUB=$(cd "$IAC_DIR" && tofu output -raw node_2_ip)
  NODE3_PUB=$(cd "$IAC_DIR" && tofu output -raw node_3_ip)
  ALL_PUB=("$NODE1_PUB" "$NODE2_PUB" "$NODE3_PUB")
  log "  node-1: $NODE1_PUB"
  log "  node-2: $NODE2_PUB"
  log "  node-3: $NODE3_PUB"
}

wait_for_ssh() {
  log "Waiting for SSH on all nodes..."
  for ip in "${ALL_PUB[@]}"; do
    for i in $(seq 1 60); do
      if ssh_cmd "$ip" "echo ok" &>/dev/null; then
        log "  $ip ready"
        break
      fi
      sleep 5
      if [ "$i" -eq 60 ]; then
        log "ERROR: SSH timeout on $ip"
        exit 1
      fi
    done
  done
}

step_provision() {
  log "Provisioning all nodes..."

  PROVISION_SCRIPT='#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Disable swap
swapoff -a
sed -i "/swap/d" /etc/fstab

# Configure private network interface
PRIV_MAC=$(ip -o link show enp7s0 2>/dev/null | awk -F"ether " "{print \$2}" | awk "{print \$1}")
if [ -n "$PRIV_MAC" ]; then
  cat > /etc/netplan/60-private-network.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    enp7s0:
      match:
        macaddress: "$PRIV_MAC"
      dhcp4: true
      dhcp4-overrides:
        route-metric: 1003
      mtu: 1450
NETPLAN
  netplan apply
  chmod 600 /etc/netplan/60-private-network.yaml
  sleep 2
fi

# Kernel modules
cat > /etc/modules-load.d/k8s.conf <<EOF
br_netfilter
overlay
openvswitch
geneve
vxlan
EOF
modprobe br_netfilter overlay openvswitch geneve vxlan

# Sysctl
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv6.conf.all.forwarding        = 1
vm.swappiness                       = 0
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 524288
EOF
sysctl --system

# Install containerd
apt-get update
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i "s/SystemdCgroup = false/SystemdCgroup = true/" /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# Install kubeadm, kubelet, kubectl
apt-get install -y apt-transport-https ca-certificates curl gpg
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl conntrack
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

# Install helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Firewall - allow K8s ports + private network
apt-get install -y iptables-persistent || true
iptables -F INPUT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -s 10.0.0.0/16 -j ACCEPT
iptables -A INPUT -p tcp --dport 6443 -j ACCEPT
iptables -A INPUT -p tcp --dport 2379:2380 -j ACCEPT
iptables -A INPUT -p tcp --dport 10250 -j ACCEPT
iptables -A INPUT -p tcp --dport 10257 -j ACCEPT
iptables -A INPUT -p tcp --dport 10259 -j ACCEPT
iptables -A INPUT -p tcp --dport 6641 -j ACCEPT
iptables -A INPUT -p tcp --dport 6642 -j ACCEPT
iptables -A INPUT -p tcp --dport 6643 -j ACCEPT
iptables -A INPUT -p tcp --dport 6644 -j ACCEPT
iptables -A INPUT -p tcp --dport 30000:32767 -j ACCEPT
iptables -A INPUT -p udp --dport 6081 -j ACCEPT
iptables -A INPUT -p udp --dport 8472 -j ACCEPT
iptables -A INPUT -p udp --dport 30000:32767 -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
iptables -A INPUT -j DROP
iptables-save > /etc/iptables/rules.v4

echo "PROVISION_DONE"
'

  for ip in "${ALL_PUB[@]}"; do
    log "  Provisioning $ip..."
    echo "export K8S_VERSION=$K8S_VERSION" | cat - <(echo "$PROVISION_SCRIPT") | ssh_cmd "$ip" bash
    log "  $ip provisioned"
  done
}

step_kubeadm_init() {
  log "Initializing control plane on node-1..."

  NODE1_PRIV="10.0.1.11"
  NODE2_PRIV="10.0.1.12"
  NODE3_PRIV="10.0.1.13"

  cat > /tmp/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: ${K8S_VERSION}.0
controlPlaneEndpoint: "${NODE1_PUB}:6443"
networking:
  podSubnet: "${POD_CIDR}"
  serviceSubnet: "${SVC_CIDR}"
  dnsDomain: cluster.local
apiServer:
  certSANs:
    - "${NODE1_PUB}"
    - "${NODE2_PUB}"
    - "${NODE3_PUB}"
    - "${NODE1_PRIV}"
    - "${NODE2_PRIV}"
    - "${NODE3_PRIV}"
controllerManager:
  extraArgs:
    - name: node-cidr-mask-size
      value: "24"
etcd:
  local:
    dataDir: /var/lib/etcd
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${NODE1_PUB}"
  bindPort: 6443
nodeRegistration:
  criSocket: "unix:///run/containerd/containerd.sock"
  taints:
    - key: "node-role.kubernetes.io/control-plane"
      effect: "NoSchedule"
EOF

  scp_file /tmp/kubeadm-config.yaml "$NODE1_PUB" /root/kubeadm-config.yaml
  ssh_cmd "$NODE1_PUB" "kubeadm init --config /root/kubeadm-config.yaml --upload-certs" 2>&1 | tee /tmp/kubeadm-init.log

  ssh_cmd "$NODE1_PUB" bash <<'REMOTE'
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
REMOTE

  scp $SSH_OPTS "root@$NODE1_PUB:/root/.kube/config" "$REPO_DIR/kubeconfig"
  log "kubeconfig saved to $REPO_DIR/kubeconfig"
}

step_join_control_plane() {
  log "Joining node-2 and node-3 as control plane members..."

  JOIN_TOKEN=$(ssh_cmd "$NODE1_PUB" "kubeadm token create --print-join-command")
  CERT_KEY=$(ssh_cmd "$NODE1_PUB" "kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1")

  for node_pub in "$NODE2_PUB" "$NODE3_PUB"; do
    log "  Joining $node_pub..."
    ssh_cmd "$node_pub" bash -s <<REMOTE
${JOIN_TOKEN} --control-plane --certificate-key ${CERT_KEY} --apiserver-advertise-address ${node_pub}
REMOTE
    ssh_cmd "$node_pub" bash <<'REMOTE'
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
REMOTE
  done
}

step_install_kube_ovn() {
  log "Labeling nodes for KubeOVN..."
  export KUBECONFIG="$REPO_DIR/kubeconfig"
  kubectl label node node-1 node-2 node-3 kube-ovn/role=master --overwrite

  log "Templating MASTER_NODES into kube-ovn values..."
  MASTER_NODES="${NODE1_PUB},${NODE2_PUB},${NODE3_PUB}"
  TMP_VALUES="$(mktemp)"
  sed "s|^MASTER_NODES: .*|MASTER_NODES: \"${MASTER_NODES}\"|" \
    "$REPO_DIR/k8s/kube-ovn-values.yaml" > "$TMP_VALUES"

  log "Installing KubeOVN via Helm (MASTER_NODES=${MASTER_NODES})..."

  helm repo add kubeovn https://kubeovn.github.io/kube-ovn 2>/dev/null || true
  helm repo update

  helm upgrade --install kube-ovn kubeovn/kube-ovn \
    --namespace kube-system \
    --values "$TMP_VALUES" \
    --wait --timeout 10m

  rm -f "$TMP_VALUES"
  log "KubeOVN installed"
}

step_untaint_control_plane() {
  log "Untainting control-plane nodes (all-control-plane lab cluster)..."
  export KUBECONFIG="$REPO_DIR/kubeconfig"
  kubectl taint nodes node-1 node-2 node-3 node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
  log "Control-plane taints removed"
}

step_install_kubevirt() {
  log "Installing KubeVirt ${KUBEVIRT_VERSION}..."
  export KUBECONFIG="$REPO_DIR/kubeconfig"

  log "Applying KubeVirt operator..."
  kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"

  log "Applying KubeVirt CR (useEmulation=true, tolerates control-plane)..."
  kubectl apply -f "$REPO_DIR/k8s/kubevirt-cr.yaml"

  log "Waiting for KubeVirt to become Available (this pulls ~3 images, ~5-10 min)..."
  kubectl -n kubevirt wait kv kubevirt --for condition=Available --timeout=600s

  log "KubeVirt installed"

  log "Installing virtctl..."
  VIRTCTL_DIR="$REPO_DIR/bin"
  mkdir -p "$VIRTCTL_DIR"
  case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *)       log "Unsupported host arch $(uname -m) for virtctl"; return 0 ;;
  esac
  curl -sSL -o "$VIRTCTL_DIR/virtctl" \
    "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-${ARCH}"
  chmod +x "$VIRTCTL_DIR/virtctl"
  log "virtctl installed at $VIRTCTL_DIR/virtctl"
}

step_verify() {
  log "Verifying cluster..."
  export KUBECONFIG="$REPO_DIR/kubeconfig"

  log "Nodes:"
  kubectl get nodes -o wide

  log "System pods:"
  kubectl get pods -n kube-system

  log "Waiting for all system pods to be ready..."
  kubectl wait --for=condition=ready pod --all -n kube-system --timeout=300s || true

  log "Subnets:"
  kubectl get subnet 2>/dev/null || log "  (KubeOVN subnets not yet available)"

  log "OVN topology:"
  kubectl ko nbctl show 2>/dev/null || log "  (kubectl ko not available yet)"

  log "KubeVirt:"
  kubectl get kv -n kubevirt 2>/dev/null || log "  (KubeVirt not installed)"
  kubectl get pods -n kubevirt 2>/dev/null || true

  log "Cluster info:"
  kubectl cluster-info
}

main() {
  case "${1:-all}" in
    provision)
      load_hosts
      wait_for_ssh
      step_provision
      ;;
    detect)
      load_hosts
      ;;
    init)
      load_hosts
      step_kubeadm_init
      ;;
    join)
      load_hosts
      step_join_control_plane
      ;;
    kube-ovn)
      step_install_kube_ovn
      ;;
    untaint)
      step_untaint_control_plane
      ;;
    kubevirt)
      step_install_kubevirt
      ;;
    verify)
      step_verify
      ;;
    all)
      load_hosts
      wait_for_ssh
      step_provision
      step_kubeadm_init
      step_join_control_plane
      step_install_kube_ovn
      step_untaint_control_plane
      step_install_kubevirt
      step_verify
      ;;
    *)
      echo "Usage: $0 {all|provision|detect|init|join|kube-ovn|untaint|kubevirt|verify}"
      exit 1
      ;;
  esac
}

main "$@"
