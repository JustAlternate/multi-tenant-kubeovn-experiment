{ config, pkgs, lib, ... }:
{
  imports = [
    /etc/nixos/networking.nix
    /etc/nixos/hardware-configuration.nix
  ];

  environment = {
    systemPackages = with pkgs; [
      coreutils-full
      git
      ghostty.terminfo
      kubectl
      kubeadm
      kubernetes-utils
      crictl
      cni-plugins
    ];
  };

  boot.kernelModules = [ "br_netfilter" "overlay" ];
  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
    "net.ipv4.ip_forward" = 1;
    "vm.swappiness" = 0;
  };

  virtualisation.containerd = {
    enable = true;
  };

  networking.firewall = {
    trustedInterfaces = [ "geneve_sys_6081" "ovn0" ];
    allowedTCPPorts = [
      22
      6443
      2379 2380
      10250 10251 10252 10255 10256 10257
    ];
    allowedTCPPortRanges = [
      { from = 30000; to = 32767; }
    ];
    allowedUDPPortRanges = [
      { from = 30000; to = 32767; }
    ];
    extraCommands = ''
      iptables -A INPUT -p tcp --dport 6641:6642 -j ACCEPT
      iptables -A INPUT -p udp --dport 8472 -j ACCEPT
    '';
  };

  services = {
    openssh = {
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

    kubelet = {
      enable = true;
      extraConfig = {
        cgroupDriver = "systemd";
      };
    };
  };

  systemd.services.kubelet.preStart = lib.mkForce "";
}
