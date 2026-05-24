{
  config,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    ./networking.nix
    ./hardware-configuration.nix
  ];

  environment = {
    systemPackages = with pkgs; [
      coreutils-full
      git
      ghostty.terminfo
      kubernetes
      kubectl
      kubernetes-helm
      cni-plugins
      conntrack-tools
      iproute2
      iptables
      ethtool
      socat
      cri-tools
    ];
  };

  boot.kernelModules = [
    "br_netfilter"
    "overlay"
    "openvswitch"
    "geneve"
    "vxlan"
    "ip_tables"
    "iptable_nat"
    "iptable_filter"
    "nf_conntrack"
  ];

  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
    "vm.swappiness" = 0;
    "fs.inotify.max_user_instances" = 8192;
    "fs.inotify.max_user_watches" = 524288;
  };

  virtualisation.containerd = {
    enable = true;
    settings = {
      plugins = {
        "io.containerd.grpc.v1.cri" = {
          containerd = {
            runtimes = {
              runc = {
                options = {
                  SystemdCgroup = true;
                };
              };
            };
          };
        };
      };
    };
  };

  networking.firewall = {
    trustedInterfaces = [ "ovn0" ];
    allowedTCPPorts = [
      22
      6443
      2379
      2380
      10250
      10257
      10259
      6641
      6642
    ];
    allowedTCPPortRanges = [
      { from = 30000; to = 32767; }
    ];
    allowedUDPPorts = [
      6081
      8472
    ];
    allowedUDPPortRanges = [
      { from = 30000; to = 32767; }
    ];
    extraCommands = ''
      iptables -A nixos-fw -s 10.0.0.0/16 -j nixos-fw-accept
    '';
  };

  systemd.tmpfiles.rules = [
    "d /etc/kubernetes/manifests 0755 root root -"
    "d /etc/kubernetes/pki 0755 root root -"
    "d /var/lib/kubelet 0755 root root -"
    "d /var/lib/etcd 0700 root root -"
    "d /opt/cni/bin 0755 root root -"
    "d /etc/cni/net.d 0755 root root -"
  ];

  system.activationScripts.cni-plugins = ''
    mkdir -p /opt/cni/bin
    for f in ${pkgs.cni-plugins}/bin/*; do
      ln -sf "$f" /opt/cni/bin/"$(basename "$f")"
    done
  '';

  systemd.services.kubelet = {
    description = "kubelet: The Kubernetes Node Agent";
    documentation = [ "https://kubernetes.io/docs/" ];
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "containerd.service" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [
      kubernetes
      util-linux
      iproute2
      iptables
      conntrack-tools
      ethtool
      socat
      mount
      cri-tools
    ];
    script = ''
      source /var/lib/kubelet/kubeadm-flags.env 2>/dev/null || true
      source /etc/default/kubelet 2>/dev/null || true
      ARGS="--pod-manifest-path=/etc/kubernetes/manifests --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
      if [ -f /etc/kubernetes/bootstrap-kubelet.conf ]; then
        ARGS="$ARGS --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf"
      fi
      if [ -f /etc/kubernetes/kubelet.conf ]; then
        ARGS="$ARGS --kubeconfig=/etc/kubernetes/kubelet.conf"
      fi
      if [ -f /var/lib/kubelet/config.yaml ]; then
        ARGS="$ARGS --config=/var/lib/kubelet/config.yaml"
      fi
      exec ${pkgs.kubernetes}/bin/kubelet $ARGS $KUBELET_KUBELET_ARGS
    '';
    serviceConfig = {
      Restart = "always";
      RestartSec = "5";
      StartLimitInterval = 0;
    };
  };

  services.openssh = {
    enable = true;
    ports = [ 22 ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
      MaxAuthTries = 3;
      LoginGraceTime = 30;
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKSO4cOiA8s9hVyPtdhUXdshxDXXPU15qM8xE0Ixfc21 justalternate@archlinux"
  ];
}
