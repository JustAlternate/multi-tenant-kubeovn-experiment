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
    timeout     = "60s"
  }

  provisioner "remote-exec" {
    inline = [
      "nohup bash -c 'curl https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect | PROVIDER=hetznercloud NIX_CHANNEL=nixos-25.11 bash' > /tmp/infect.log 2>&1 & disown",
    ]
  }
}

resource "time_sleep" "wait_reboot" {
  depends_on      = [null_resource.NixOS_install]
  create_duration = "240s"
}

resource "null_resource" "rebuild" {
  depends_on = [time_sleep.wait_reboot]

  connection {
    type        = "ssh"
    user        = "root"
    host        = var.target_host
    private_key = file("~/.ssh/id_ed25519")
    host_key    = null
    agent       = false
    timeout     = "600s"
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p /root/nixcfg/sac",
    ]
  }

  provisioner "file" {
    source      = "${path.root}/../flake.nix"
    destination = "/root/nixcfg/flake.nix"
  }

  provisioner "file" {
    source      = "${path.root}/../sac/"
    destination = "/root/nixcfg/sac/"
  }

  provisioner "remote-exec" {
    inline = [
      "nixos-rebuild switch --flake /root/nixcfg#nodeNixos",
    ]
  }
}
