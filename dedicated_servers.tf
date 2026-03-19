# Dedicated Servers (Hetzner Robot)
# Manages dedicated bare-metal servers joining the cluster as workers via vSwitch.
# vSwitch subnet must be created externally and passed via dedicated_servers_vswitch_subnet_id.

locals {
  # Normalize dedicated servers with computed fields
  dedicated_servers_normalized = [
    for s in var.dedicated_servers : {
      hostname          = s.hostname
      server_number     = s.server_number
      public_ipv4       = s.public_ipv4
      private_ipv4      = s.private_ipv4
      private_ipv4_cidr = s.private_ipv4_cidr
      network_interface = s.network_interface
      vlan_id           = s.vlan_id
      mode              = s.mode
      labels = merge(
        s.labels,
        { "node.kubernetes.io/dedicated-server" = "true" }
      )
      annotations = s.annotations
      taints = [for taint in s.taints : regex(
        "^(?P<key>[^=:]+)=?(?P<value>[^=:]*?):(?P<effect>.+)$",
        taint
      )]
      install_disk        = s.install_disk
      rescue_ssh_key_path = s.rescue_ssh_key_path
      reinstall           = s.reinstall
    }
  ]

  # Map for lookups
  dedicated_servers_map = {
    for s in local.dedicated_servers_normalized : s.hostname => s
  }

  # Filter by mode
  dedicated_servers_talos = [
    for s in local.dedicated_servers_normalized : s if s.mode == "talos"
  ]
  dedicated_servers_manual = [
    for s in local.dedicated_servers_normalized : s if s.mode == "manual"
  ]

  # IP lists for health checks
  dedicated_servers_private_ipv4_list = [
    for s in local.dedicated_servers_normalized : s.private_ipv4
  ]
  dedicated_servers_talos_private_ipv4_list = [
    for s in local.dedicated_servers_talos : s.private_ipv4
  ]
}


# vSwitch subnet — łączy vSwitch z Cloud Network
resource "hcloud_network_subnet" "dedicated_vswitch" {
  for_each = toset(distinct([for s in local.dedicated_servers_normalized : tostring(s.vlan_id)]))

  network_id   = local.hcloud_network_id
  type         = "vswitch"
  network_zone = local.hcloud_network_zone
  ip_range     = var.dedicated_servers_vswitch_ip_range
  vswitch_id   = var.dedicated_servers_vswitch_id

  depends_on = [
    hcloud_network_subnet.control_plane,
    hcloud_network_subnet.load_balancer
  ]
}


# Metal schematic — no qemu-guest-agent (blocks boot on bare metal)
resource "talos_image_factory_schematic" "metal" {
  count = length(local.dedicated_servers_talos) > 0 ? 1 : 0
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = []
      }
    }
  })
}

# Metal image for dedicated servers
data "talos_image_factory_urls" "metal_amd64" {
  talos_version = var.talos_version
  schematic_id  = length(talos_image_factory_schematic.metal) > 0 ? talos_image_factory_schematic.metal[0].id : local.talos_schematic_id
  platform      = "metal"
  architecture  = "amd64"
}


# Talos Configuration (mode: talos)

locals {
  # Talos config patches for dedicated servers — uses VLAN interface
  dedicated_server_talos_config_patch = {
    for s in local.dedicated_servers_talos : s.hostname => {
      machine = {
        install = {
          disk            = s.install_disk
          image           = data.talos_image_factory_urls.metal_amd64.urls.installer
          extraKernelArgs = var.talos_extra_kernel_args
        }
        nodeLabels      = s.labels
        nodeAnnotations = s.annotations
        certSANs        = local.certificate_san
        network = {
          interfaces = [{
            deviceSelector = {
              physical = true
            }
            dhcp      = true
            vlans = [{
              vlanId    = s.vlan_id
              mtu       = 1400
              addresses = ["${s.private_ipv4}/${s.private_ipv4_cidr}"]
              routes = concat(
                [{
                  network = local.network_ipv4_cidr
                  gateway = cidrhost(var.dedicated_servers_vswitch_ip_range, 1)
                }],
                [for cidr in var.talos_extra_routes : {
                  network = cidr
                  gateway = cidrhost(var.dedicated_servers_vswitch_ip_range, 1)
                  metric  = 512
                }]
              )
            }]
          }]
          nameservers      = local.talos_nameservers
          extraHostEntries = local.talos_extra_host_entries
        }
        kubelet = {
          extraArgs = merge(
            {
              "cloud-provider"             = "external"
              "rotate-server-certificates" = true
              "provider-id"                = "hcloud://bm-${s.server_number}"
            },
            var.kubernetes_kubelet_extra_args
          )
          extraConfig = merge(
            {
              shutdownGracePeriod             = "90s"
              shutdownGracePeriodCriticalPods = "15s"
              registerWithTaints              = s.taints
              systemReserved = {
                cpu               = "100m"
                memory            = "300Mi"
                ephemeral-storage = "1Gi"
              }
              kubeReserved = {
                cpu               = "100m"
                memory            = "350Mi"
                ephemeral-storage = "1Gi"
              }
            },
            var.kubernetes_kubelet_extra_config
          )
          extraMounts = local.talos_kubelet_extra_mounts
          nodeIP = {
            validSubnets = [local.network_ipv4_cidr]
          }
        }
        kernel = {
          modules = var.talos_kernel_modules
        }
        sysctls = merge(
          {
            "net.core.somaxconn"                 = "65535"
            "net.core.netdev_max_backlog"        = "4096"
            "net.ipv6.conf.default.disable_ipv6" = "${var.talos_ipv6_enabled ? 0 : 1}"
            "net.ipv6.conf.all.disable_ipv6"     = "${var.talos_ipv6_enabled ? 0 : 1}"
          },
          var.talos_sysctls_extra_args
        )
        registries           = var.talos_registries
        systemDiskEncryption = local.talos_system_disk_encryption
        features = {
          hostDNS = local.talos_host_dns
        }
        time = {
          servers = var.talos_time_servers
        }
        logging = {
          destinations = var.talos_logging_destinations
        }
      }
      cluster = {
        network = {
          dnsDomain      = var.cluster_domain
          podSubnets     = [local.network_pod_ipv4_cidr]
          serviceSubnets = [local.network_service_ipv4_cidr]
          cni            = { name = "none" }
        }
        proxy = {
          disabled = var.cilium_kube_proxy_replacement_enabled
        }
        discovery = local.talos_discovery
      }
    }
  }
}

# Generate Talos machine configurations
data "talos_machine_configuration" "dedicated_server" {
  for_each = { for s in local.dedicated_servers_talos : s.hostname => s }

  talos_version      = var.talos_version
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.kube_api_url_internal
  kubernetes_version = var.kubernetes_version
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  docs               = false
  examples           = false

  config_patches = concat(
    [yamlencode(local.dedicated_server_talos_config_patch[each.key])],
    [yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = each.key
      auto       = "off"
    })],
    [for patch in var.dedicated_servers_config_patches : yamlencode(patch)]
  )
}

# Apply Talos configuration to dedicated servers
resource "talos_machine_configuration_apply" "dedicated_server" {
  for_each = { for s in local.dedicated_servers_talos : s.hostname => s }

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.dedicated_server[each.key].machine_configuration
  endpoint                    = each.value.public_ipv4
  node                        = each.value.private_ipv4
  apply_mode                  = var.talos_machine_configuration_apply_mode

  on_destroy = {
    graceful = var.cluster_graceful_destroy
    reset    = false
    reboot   = false
  }

  depends_on = [
    hcloud_network_subnet.dedicated_vswitch,
    terraform_data.dedicated_server_talos_install,
    terraform_data.upgrade_kubernetes,
    talos_machine_configuration_apply.worker
  ]
}


# Automated Talos Installation
# Checks if Talos is already running. If not — activates rescue via Robot API,
# installs Talos via SSH, and reboots.

resource "terraform_data" "dedicated_server_talos_install" {
  for_each = {
    for s in local.dedicated_servers_talos : s.hostname => s
  }

  triggers_replace = [
    var.talos_version,
    local.talos_schematic_id,
    each.value.install_disk,
    each.value.reinstall
  ]

  provisioner "local-exec" {
    environment = {
      TALOSCONFIG = nonsensitive(data.talos_client_configuration.this.talos_config)
      ROBOT_USER  = nonsensitive(var.dedicated_servers_robot_user)
      ROBOT_PASS  = nonsensitive(var.dedicated_servers_robot_password)
    }
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -eu

      SERVER_NUM="${each.value.server_number}"
      PUBLIC_IP="${each.value.public_ipv4}"
      PRIVATE_IP="${each.value.private_ipv4}"
      HOSTNAME="${each.value.hostname}"
      INSTALL_DISK="${each.value.install_disk}"
      SSH_KEY="$(eval echo ${each.value.rescue_ssh_key_path})"
      IMAGE_URL="${data.talos_image_factory_urls.metal_amd64.urls.disk_image}"

      TALOS_CFG=$(mktemp)
      trap 'rm -f "$TALOS_CFG"' EXIT
      echo "$TALOSCONFIG" > "$TALOS_CFG"

      REINSTALL="${each.value.reinstall}"
      echo "=== Dedicated server $HOSTNAME ($PUBLIC_IP) ==="

      # 1. Check if Talos is already running (skip if reinstall=true)
      if [ "$REINSTALL" != "true" ]; then
        if talosctl --talosconfig "$TALOS_CFG" \
           -e "$PUBLIC_IP" -n "$PRIVATE_IP" version >/dev/null 2>&1; then
          echo "Talos is already running on $HOSTNAME. Skipping install."
          exit 0
        fi
      else
        echo "Reinstall requested for $HOSTNAME. Forcing rescue + install."
      fi

      echo "Talos not running on $HOSTNAME."

      # 2. Check if server is in rescue mode (SSH reachable)
      if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=10 root@"$PUBLIC_IP" "echo rescue_ok" >/dev/null 2>&1; then

        echo "Server not in rescue mode. Activating rescue via Robot API..."

        # Activate rescue
        SSH_KEY_FINGERPRINT=$(ssh-keygen -lf "$SSH_KEY.pub" -E md5 | awk '{print $2}' | sed 's/MD5://')
        curl -sf -u "$ROBOT_USER:$ROBOT_PASS" \
          -d "os=linux" -d "arch=64" -d "authorized_key[]=$SSH_KEY_FINGERPRINT" \
          "https://robot-ws.your-server.de/boot/$SERVER_NUM/rescue" >/dev/null

        # Rename server
        curl -sf -u "$ROBOT_USER:$ROBOT_PASS" \
          -d "server_name=$HOSTNAME" \
          "https://robot-ws.your-server.de/server/$SERVER_NUM" >/dev/null

        # Hardware reset
        curl -sf -u "$ROBOT_USER:$ROBOT_PASS" \
          -d "type=hw" \
          "https://robot-ws.your-server.de/reset/$SERVER_NUM" >/dev/null

        echo "Server resetting into rescue mode. Waiting 60s..."
        sleep 60

        # Wait for SSH
        for i in $(seq 1 30); do
          if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=5 root@"$PUBLIC_IP" "echo rescue_ok" >/dev/null 2>&1; then
            break
          fi
          echo "Waiting for rescue SSH... ($i/30)"
          sleep 10
        done
      fi

      echo "Installing Talos on $HOSTNAME..."

      # 3. SSH into rescue and install Talos
      echo "Installing Talos (metal image) on $HOSTNAME..."

      ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=30 root@"$PUBLIC_IP" \
          "set -eu; \
           echo 'Downloading Talos metal image...'; \
           wget -q -O /tmp/talos.img '$IMAGE_URL'; \
           echo 'Stopping RAID and wiping all disks...'; \
           mdadm --stop --scan 2>/dev/null || true; \
           for d in /dev/nvme*n1 /dev/sd?; do \
             if [ -b \$d ]; then echo \"  wiping \$d\"; dd if=/dev/zero of=\$d bs=1M count=100 2>/dev/null; wipefs -af \$d 2>/dev/null; fi; \
           done; \
           echo 'Writing Talos to disk $INSTALL_DISK...'; \
           case '$IMAGE_URL' in \
             *.zst) zstd -d -c /tmp/talos.img | dd of=$INSTALL_DISK bs=4M status=progress ;; \
             *.xz)  xz -d -c /tmp/talos.img | dd of=$INSTALL_DISK bs=4M status=progress ;; \
             *)     dd if=/tmp/talos.img of=$INSTALL_DISK bs=4M status=progress ;; \
           esac; \
           sync; \
           echo 'Talos installation complete. Rebooting...'; \
           reboot" || true

      echo "Server $HOSTNAME rebooting into Talos. Waiting 120s..."
      sleep 120

      # 4. Wait for Talos API (port 50000)
      for i in $(seq 1 20); do
        if nc -z -w3 "$PUBLIC_IP" 50000 2>/dev/null; then
          echo "Talos is up on $HOSTNAME!"
          exit 0
        fi
        echo "Waiting for Talos API on $HOSTNAME... ($i/20)"
        sleep 10
      done

      echo "WARNING: Talos API not reachable after timeout."
    EOT
  }
}


# Bootstrap Tokens (mode: manual)

resource "random_id" "dedicated_server_bootstrap_token_id" {
  for_each = { for s in local.dedicated_servers_manual : s.hostname => s }

  byte_length = 3
}

resource "random_password" "dedicated_server_bootstrap_token_secret" {
  for_each = { for s in local.dedicated_servers_manual : s.hostname => s }

  length  = 16
  special = false
  lower   = true
  upper   = false
}

locals {
  dedicated_servers_join_info = {
    for s in local.dedicated_servers_manual : s.hostname => {
      hostname     = s.hostname
      private_ipv4 = s.private_ipv4
      token_id     = random_id.dedicated_server_bootstrap_token_id[s.hostname].hex
      token_secret = random_password.dedicated_server_bootstrap_token_secret[s.hostname].result
      token        = "${random_id.dedicated_server_bootstrap_token_id[s.hostname].hex}.${random_password.dedicated_server_bootstrap_token_secret[s.hostname].result}"
      api_server   = local.kube_api_url_internal
      labels       = s.labels
      taints       = s.taints
      bootstrap_secret_manifest = yamlencode({
        apiVersion = "v1"
        kind       = "Secret"
        metadata = {
          name      = "bootstrap-token-${random_id.dedicated_server_bootstrap_token_id[s.hostname].hex}"
          namespace = "kube-system"
        }
        type = "bootstrap.kubernetes.io/token"
        stringData = {
          "token-id"                       = random_id.dedicated_server_bootstrap_token_id[s.hostname].hex
          "token-secret"                   = random_password.dedicated_server_bootstrap_token_secret[s.hostname].result
          "usage-bootstrap-authentication" = "true"
          "usage-bootstrap-signing"        = "true"
          "auth-extra-groups"              = "system:bootstrappers:dedicated-workers"
          "description"                    = "Bootstrap token for dedicated server ${s.hostname}"
        }
      })
    }
  }
}
