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

locals {
  nodes = {
    node-1 = "10.0.1.11"
    node-2 = "10.0.1.12"
    node-3 = "10.0.1.13"
  }
}

resource "hcloud_server" "nodes" {
  for_each    = local.nodes
  name        = each.key
  server_type = "cpx22"
  image       = "ubuntu-24.04"
  location    = "fsn1"

  ssh_keys = [hcloud_ssh_key.my_ssh_key.id]

  network {
    subnet_id = hcloud_network_subnet.network_subnet.id
    ip        = each.value
  }
}

output "node_1_ip" {
  value = hcloud_server.nodes["node-1"].ipv4_address
}

output "node_2_ip" {
  value = hcloud_server.nodes["node-2"].ipv4_address
}

output "node_3_ip" {
  value = hcloud_server.nodes["node-3"].ipv4_address
}
