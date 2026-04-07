# selfk8s

A single-node Kubernetes deployment on localhost using Kubespray, FluxCD, and MetalLB.

## Prerequisites

- Nix with Flakes enabled.
- Sudo access.
- (Recommended) A system that Kubespray supports (Ubuntu/Debian/CentOS). 
  **Note:** Running this directly on NixOS to target the host might encounter issues with package management (Kubespray expects `apt` or `yum`).

## Usage

To deploy the cluster:

```bash
nix run .
```

To use kubectl after deployment:

```bash
nix develop -c kubectl get nodes
```

## Features

- **Kubespray**: Latest version from master.
- **Single Node**: Localhost acts as both control plane and worker.
- **MetalLB**: Layer2 mode enabled with range `10.0.0.240-10.0.0.250`.
- **FluxCD**: Automatically installed after cluster setup.
- **Containerd**: Default container runtime.

## Customization

- Inventory: `inventory/local/hosts.yaml`
- Cluster config: `inventory/local/group_vars/k8s_cluster/k8s-cluster.yml`
- Addons (MetalLB): `inventory/local/group_vars/k8s_cluster/addons.yml`
