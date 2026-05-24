terraform {
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

resource "null_resource" "NixOS_install" {
  connection {
    type        = "ssh"
    user        = "root"
    host        = var.target_host
    private_key = file("~/.ssh/id_ed25519")
    host_key    = null
    agent       = false
    timeout     = "1800s"
  }

  provisioner "remote-exec" {
    inline = [
      "if grep -q NixOS /etc/os-release 2>/dev/null; then echo 'Already NixOS, skipping infect'; exit 0; fi",
      "curl -fsSL https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect -o /tmp/nixos-infect",
      "chmod +x /tmp/nixos-infect",
      "PROVIDER=hetznercloud NIX_CHANNEL=nixos-25.11 /tmp/nixos-infect",
    ]
  }
}

resource "time_sleep" "wait_reboot" {
  depends_on      = [null_resource.NixOS_install]
  create_duration = "300s"
}
