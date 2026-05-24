#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
IAC_DIR="$REPO_DIR/iac"

VIP="10.0.1.10"
POD_CIDR="10.16.0.0/16"
SVC_CIDR="10.96.0.0/12"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o UpdateHostKeys=no -o ConnectTimeout=10"

log() { echo "==> $*"; }
ssh_cmd() { ssh $SSH_OPTS "root@$1" "${@:2}"; }

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

detect_private_info() {
  ssh_cmd "$1" "IFACE=\$(ip -4 route get 10.0.1.1 2>/dev/null | grep -oP 'dev \\K\\S+'); IP=\$(ip -4 addr show dev \"\$IFACE\" | grep -oP 'inet \\K[0-9.]+'); echo \"\$IFACE \$IP\""
}

step_deploy_nixos() {
  log "Deploying NixOS config to all nodes..."
  for ip in "${ALL_PUB[@]}"; do
    log "  Deploying to $ip"
    scp $SSH_OPTS "$REPO_DIR/flake.nix" "$REPO_DIR/flake.lock" "root@$ip:/root/nixcfg/"
    scp $SSH_OPTS -r "$REPO_DIR/sac" "root@$ip:/root/nixcfg/"
    ssh_cmd "$ip" "cp /etc/nixos/networking.nix /etc/nixos/hardware-configuration.nix /root/nixcfg/sac/"
    ssh_cmd "$ip" "nixos-rebuild switch --flake /root/nixcfg#nodeNixos"
  done
  log "NixOS config deployed."
}

step_detect_nodes() {
  log "Detecting node network configuration..."
  read -r PRIV_IFACE NODE1_PRIV <<< "$(detect_private_info "$NODE1_PUB")"
  read -r _ NODE2_PRIV <<< "$(detect_private_info "$NODE2_PUB")"
  read -r _ NODE3_PRIV <<< "$(detect_private_info "$NODE3_PUB")"
  log "  node-1: $NODE1_PRIV (iface: $PRIV_IFACE)"
  log "  node-2: $NODE2_PRIV"
  log "  node-3: $NODE3_PRIV"

  cat > /tmp/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: stable:$(ssh_cmd "$NODE1_PUB" "kubelet --version" | grep -oP 'v[\d.]+')
controlPlaneEndpoint: "${VIP}:6443"
networking:
  podSubnet: "${POD_CIDR}"
  serviceSubnet: "${SVC_CIDR}"
  dnsDomain: cluster.local
apiServer:
  certSANs:
    - "${VIP}"
    - "${NODE1_PRIV}"
    - "${NODE2_PRIV}"
    - "${NODE3_PRIV}"
    - "${NODE1_PUB}"
    - "${NODE2_PUB}"
    - "${NODE3_PUB}"
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
  advertiseAddress: "${NODE1_PRIV}"
  bindPort: 6443
nodeRegistration:
  criSocket: "unix:///run/containerd/containerd.sock"
  taints:
    - key: "node-role.kubernetes.io/control-plane"
      effect: "NoSchedule"
EOF
}

step_kube_vip_static_pod() {
  log "Deploying kube-vip static pod on node-1..."
  ssh_cmd "$NODE1_PUB" bash -s <<REMOTE
mkdir -p /etc/kubernetes/manifests
cat > /etc/kubernetes/manifests/kube-vip.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: kube-system
spec:
  containers:
    - name: kube-vip
      image: ghcr.io/kube-vip/kube-vip:v1.0.0
      imagePullPolicy: IfNotPresent
      args:
        - manager
      env:
        - name: vip_arp
          value: "true"
        - name: port
          value: "6443"
        - name: vip_interface
          value: "${PRIV_IFACE}"
        - name: vip_cidr
          value: "32"
        - name: cp_enable
          value: "true"
        - name: cp_namespace
          value: kube-system
        - name: svc_enable
          value: "false"
        - name: vip_leaderElection
          value: "true"
        - name: vip_leasename
          value: plndr-cp-lock
        - name: vip_leaseduration
          value: "5"
        - name: vip_renewdeadline
          value: "3"
        - name: vip_retryperiod
          value: "1"
        - name: address
          value: "${VIP}"
      securityContext:
        capabilities:
          add:
            - NET_ADMIN
            - NET_RAW
  hostNetwork: true
  hostAliases:
    - hostnames:
        - kubernetes
        - kubernetes.default
        - kubernetes.default.svc
        - kubernetes.default.svc.cluster
        - kubernetes.default.svc.cluster.local
      ip: 127.0.0.1
EOF
REMOTE
  log "Waiting for kubelet to pick up kube-vip manifest..."
  sleep 5
}

step_kubeadm_init() {
  log "Initializing control plane on node-1..."
  scp $SSH_OPTS /tmp/kubeadm-config.yaml "root@$NODE1_PUB:/root/kubeadm-config.yaml"
  ssh_cmd "$NODE1_PUB" "kubeadm init --config /root/kubeadm-config.yaml --upload-certs" 2>&1 | tee /tmp/kubeadm-init.log

  ssh_cmd "$NODE1_PUB" bash <<'REMOTE'
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
REMOTE

  scp $SSH_OPTS "root@$NODE1_PUB:/root/.kube/config" "$REPO_DIR/kubeconfig"
  log "kubeconfig saved to $REPO_DIR/kubeconfig"
}

step_kube_vip_daemonset() {
  log "Deploying kube-vip RBAC and DaemonSet..."
  export KUBECONFIG="$REPO_DIR/kubeconfig"
  kubectl apply -f "$REPO_DIR/k8s/kube-vip-rbac.yaml"
  kubectl apply -f "$REPO_DIR/k8s/kube-vip-ds.yaml"
}

step_join_control_plane() {
  log "Joining node-2 and node-3 as control plane members..."

  JOIN_TOKEN=$(ssh_cmd "$NODE1_PUB" "kubeadm token create --print-join-command")
  CERT_KEY=$(ssh_cmd "$NODE1_PUB" "kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1")

  for node_pub in "$NODE2_PUB" "$NODE3_PUB"; do
    if [ "$node_pub" = "$NODE2_PUB" ]; then
      NODE_PRIV="$NODE2_PRIV"
    else
      NODE_PRIV="$NODE3_PRIV"
    fi
    log "  Joining $node_pub ($NODE_PRIV)..."
    ssh_cmd "$node_pub" bash -s <<REMOTE
${JOIN_TOKEN} --control-plane --certificate-key ${CERT_KEY} --apiserver-advertise-address ${NODE_PRIV}
REMOTE
    ssh_cmd "$node_pub" bash <<'REMOTE'
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
REMOTE
  done
}

step_install_kube_ovn() {
  log "Installing KubeOVN via Helm..."
  export KUBECONFIG="$REPO_DIR/kubeconfig"

  helm repo add kubeovn https://kubeovn.github.io/kube-ovn 2>/dev/null || true
  helm repo update

  helm upgrade --install kube-ovn kubeovn/kube-ovn \
    --namespace kube-system \
    --values "$REPO_DIR/k8s/kube-ovn-values.yaml" \
    --wait --timeout 10m

  log "KubeOVN installed"
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

  log "Cluster info:"
  kubectl cluster-info
}

main() {
  case "${1:-all}" in
    deploy-nixos)
      load_hosts
      step_deploy_nixos
      ;;
    detect)
      load_hosts
      step_detect_nodes
      ;;
    kube-vip)
      load_hosts
      step_kube_vip_static_pod
      ;;
    init)
      load_hosts
      step_kubeadm_init
      ;;
    kube-vip-ds)     step_kube_vip_daemonset ;;
    join)
      load_hosts
      step_join_control_plane
      ;;
    kube-ovn)        step_install_kube_ovn ;;
    verify)          step_verify ;;
    all)
      load_hosts
      step_deploy_nixos
      step_detect_nodes
      step_kube_vip_static_pod
      step_kubeadm_init
      step_kube_vip_daemonset
      step_join_control_plane
      step_install_kube_ovn
      step_verify
      ;;
    *)
      echo "Usage: $0 {all|deploy-nixos|detect|kube-vip|init|kube-vip-ds|join|kube-ovn|verify}"
      exit 1
      ;;
  esac
}

main "$@"