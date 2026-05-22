terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
  }
}

provider "hcloud" {
  token = var.hetzner_token
}

resource "hcloud_ssh_key" "my_ssh_key" {
  name       = "my-ssh-key"
  public_key = file("~/.ssh/id_ed25519.pub")
}

resource "hcloud_network" "network" {
  name     = "network"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "network_subnet" {
  type         = "cloud"
  network_id   = hcloud_network.network.id
  network_zone = "eu-central"
  ip_range     = "10.0.1.0/24"
}

resource "hcloud_server" "node-1" {
  name        = "node-1"
  server_type = "cax11"
  image       = "ubuntu-24.04"
  location    = "nbg1"

  ssh_keys = [hcloud_ssh_key.my_ssh_key.id]

  network {
    subnet_id = hcloud_network_subnet.network_subnet.id
    ip        = "10.0.1.11"
  }
}

resource "hcloud_server" "node-2" {
  name        = "node-2"
  server_type = "cax11"
  image       = "ubuntu-24.04"
  location    = "nbg1"

  ssh_keys = [hcloud_ssh_key.my_ssh_key.id]

  network {
    subnet_id = hcloud_network_subnet.network_subnet.id
    ip        = "10.0.1.12"
  }
}

resource "hcloud_server" "node-3" {
  name        = "node-3"
  server_type = "cax11"
  image       = "ubuntu-24.04"
  location    = "nbg1"

  ssh_keys = [hcloud_ssh_key.my_ssh_key.id]

  network {
    subnet_id = hcloud_network_subnet.network_subnet.id
    ip        = "10.0.1.13"
  }
}

module "nixos_infect_node_1" {
  source      = "./NixOS-install"
  target_host = hcloud_server.node-1.ipv4_address
}

module "nixos_infect_node_2" {
  source      = "./NixOS-install"
  target_host = hcloud_server.node-2.ipv4_address
}

module "nixos_infect_node_3" {
  source      = "./NixOS-install"
  target_host = hcloud_server.node-3.ipv4_address
}

output "node_1_ip" {
  value = hcloud_server.node-1.ipv4_address
}

output "node_2_ip" {
  value = hcloud_server.node-2.ipv4_address
}

output "node_3_ip" {
  value = hcloud_server.node-3.ipv4_address
}

output "ssh_command_node_1" {
  value = "ssh root@${hcloud_server.node-1.ipv4_address}"
}

output "ssh_command_node_2" {
  value = "ssh root@${hcloud_server.node-2.ipv4_address}"
}

output "ssh_command_node_3" {
  value = "ssh root@${hcloud_server.node-3.ipv4_address}"
}
