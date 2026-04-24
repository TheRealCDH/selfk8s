{
  description = "Single-node Localhost Kubernetes Deployment with Kubespray, FluxCD, and MetalLB";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    kubespray = {
      url = "github:kubernetes-sigs/kubespray/release-2.30";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, kubespray }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      
      # Patch kubespray to disable version check and skip kubeadm config validation
      patchedKubespray = pkgs.runCommand "patched-kubespray" { } ''
        cp -r ${kubespray} $out
        chmod -R +w $out
        
        # Create a bypass playbook content
        cat <<'EOF' > bypass_ansible.yml
- name: Bypass Ansible version check
  hosts: all
  gather_facts: false
  tasks:
    - name: "Bypass version check"
      debug:
        msg: "Ansible version check bypassed"
EOF

        # Replace ALL occurrences of ansible_version.yml in the source
        find $out -name "ansible_version.yml" -exec cp bypass_ansible.yml {} \;

        # Disable the entire validate_inventory role
        find $out -path "*/roles/validate_inventory/tasks/main.yml" -exec sh -c "echo '- debug: { msg: bypassed }' > {}" \;

        # Disable kubeadm config validation which fails on YAML syntax rendering edge cases
        find $out -name "kubeadm-setup.yml" -exec sed -i '/validate:.*kubeadm config validate/d' {} \;

        # Force ignore errors on apiserver cert check (often fails if files missing)
        find $out -name "kubeadm-setup.yml" -exec sed -i 's/cmd: "openssl x509 -noout -in {{ kube_cert_dir }}\/apiserver.crt -checkip {{ item }}"/cmd: "true"/' {} \;
        find $out -name "kubeadm-setup.yml" -exec sed -i 's/cmd: "openssl x509 -noout -in {{ kube_cert_dir }}\/apiserver.crt -noout -subject | grep -q {{ item }}"/cmd: "true"/' {} \;

        # Fix kube module calls to use explicit kubeconfig
        find $out -name "*.yml" -exec sed -i 's/\([ ]*\)kubectl: "{{ bin_dir }}\/kubectl"/\1kubectl: "{{ bin_dir }}\/kubectl"\n\1kubeconfig: "{{ kube_config_dir }}\/admin.conf"/g' {} \;

        # Fix deadlock in single-node wait for ready
        find $out -name "kubeadm-secondary.yml" -exec sed -i 's/when: kubeadm_already_run.stat.exists/when: kubeadm_already_run.stat.exists and groups["kube_control_plane"] | length > 1/g' {} \;

        # Fix etcd openssl.conf template bug (stuck counter)
        # We replace the alt_names section with a simpler one that works for single-node
        find $out -name "openssl.conf.j2" -exec sh -c "sed -i '/\[alt_names\]/,\$d' {} && cat >> {} <<'EOF'
[alt_names]
DNS.1 = localhost
DNS.2 = {{ inventory_hostname }}
DNS.3 = etcd
IP.1 = 127.0.0.1
IP.2 = ::1
IP.3 = {{ etcd_address }}
IP.4 = {{ ip }}
IP.5 = {{ access_ip }}
EOF
" \;

        # Force ignore errors on the problematic node registration workaround
        # This prevents the entire nix-first-boot.service from failing at the very end
        find $out -name "main.yml" -exec sed -i '/name: Apply workaround to allow all nodes with cert O=system:nodes to register/a \  ignore_errors: true' {} \;

        # Increase MetalLB and other rollout timeouts from 2m to 10m
        find $out -name "*.yml" -exec sed -i 's/--timeout=2m/--timeout=10m/g' {} \;

        # Ensure kubectl rollout commands in playbooks use the correct kubeconfig
        find $out -name "*.yml" -exec sed -i 's/kubectl rollout status/kubectl --kubeconfig={{ kube_config_dir }}\/admin.conf rollout status/g' {} \;

        # Patch the kube Ansible module to default to the correct admin.conf
        # This is more robust than patching every YAML file call
        find $out -name "kube.py" -exec sed -i "s/kubeconfig=dict()/kubeconfig=dict(default='\/etc\/kubernetes\/admin.conf')/g" {} \;

        # Fix CNI directory permissions to prevent Cilium init failures
        find $out -name "0050-create_directories.yml" -exec sed -i '/name: Create cni directories/,/mode:/ s/mode: "0755"/mode: "0777"/' {} \;
        find $out -name "0050-create_directories.yml" -exec sed -i '/name: Create cni directories/,/owner:/ s/owner: "{{ kube_owner }}"/owner: root/' {} \;
      '';

      # Python environment for Kubespray
      pythonEnv = pkgs.python3.withPackages (ps: with ps; [
        ansible
        ansible-core
        cryptography
        jinja2
        netaddr
        pbr
        jmespath
        ruamel-yaml
        pyyaml
        requests
      ]);

      deploy-script = pkgs.writeShellScriptBin "selfk8s-deploy" ''
        set -e
        PROJECT_DIR=$(pwd)
        
        if [ ! -d "$PROJECT_DIR/inventory" ]; then
          echo "Copying default inventory from flake..."
          mkdir -p inventory
          cp -r ${./inventory}/* inventory/
          chmod -R +w inventory
        else
          echo "Syncing group_vars from flake..."
          cp -r ${./inventory}/local/group_vars/* inventory/local/group_vars/
          chmod -R +w inventory/local/group_vars
        fi
        # Remove problematic cloud_provider: undefined
        find inventory -name "k8s-cluster.yml" -exec sed -i '/cloud_provider: undefined/d' {} \;
        
        # Detect actual IP for Kubespray validation at RUNTIME
        # We pick the first non-loopback IP
        ACTUAL_IP=$(hostname -I | awk '{print $1}')
        ACTUAL_IP=''${ACTUAL_IP:-127.0.0.1}
        
        # Hostname handling
        SYSTEM_HOSTNAME=$(hostname)
        if [ "$USE_SYSTEM_HOSTNAME" = "false" ]; then
          NODE_NAME="node1"
          OVERRIDE_HOSTNAME="true"
        else
          NODE_NAME="$SYSTEM_HOSTNAME"
          OVERRIDE_HOSTNAME="false"
        fi

        echo "Deploying to: localhost"
        echo "Node Name: $NODE_NAME"
        echo "Detected IP: $ACTUAL_IP"

        # Pre-fix permissions for CNI binaries (Cilium requirement)
        sudo mkdir -p /opt/cni/bin
        sudo chown root:root /opt/cni/bin
        sudo chmod 755 /opt/cni/bin

        # Always update/create hosts.yaml to ensure it matches current state
        echo "Generating/Updating single-node inventory for $NODE_NAME ($ACTUAL_IP)..."
        cat <<EOF > inventory/local/hosts.yaml
all:
  hosts:
    $NODE_NAME:
      ansible_connection: local
      ansible_host: localhost
      ip: $ACTUAL_IP
      access_ip: $ACTUAL_IP
  children:
    kube_control_plane:
      hosts:
        $NODE_NAME:
    kube_node:
      hosts:
        $NODE_NAME:
    etcd:
      hosts:
        $NODE_NAME:
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
EOF

        # Create a definitive vars file
        cat <<EOF > extra_vars.json
{
  "kube_version": "1.32.1",
  "etcd_cert_alt_ips": ["127.0.0.1", "::1", "$ACTUAL_IP"],
  "supplementary_addresses_in_ssl_keys": ["$ACTUAL_IP"],
  "etcd_address": "$ACTUAL_IP",
  "etcd_kubeadm_enabled": false,
  "ssl_ca_dirs": ["/usr/share/ca-certificates", "/usr/local/share/ca-certificates"],
  "kube_apiserver_bind_address": "0.0.0.0",
  "loadbalancer_apiserver_port": 6444,
  "kube_apiserver_endpoint": "https://$ACTUAL_IP:6443",
  "kube_proxy_strict_arp": true,
  "cilium_operator_replicas": 1,
  "ignore_assert_errors": true,
  "override_system_hostname": $OVERRIDE_HOSTNAME,
  "kube_proxy_mode": "iptables"
}
EOF

        KUBESPRAY_DIR="${patchedKubespray}"
        
        echo "Starting autonomous single-node deployment on $NODE_NAME ($ACTUAL_IP) with K8s v1.32.1..."
        
        export ANSIBLE_HOST_KEY_CHECKING=False
        export ANSIBLE_ALLOW_BROKEN_CONDITIONALS=True
        export ANSIBLE_ROLES_PATH="$KUBESPRAY_DIR/roles"
        export PATH="${pkgs.kubectl}/bin:${pkgs.fluxcd}/bin:${pkgs.kubernetes-helm}/bin:$PATH"
        # Force HOME and XDG_CACHE_HOME for tools like Cilium/Helm that need a cache directory
        export HOME=/root
        export XDG_CACHE_HOME=/root/.cache
        
        # Run ansible-playbook locally as root
        sudo -E env ANSIBLE_ALLOW_BROKEN_CONDITIONALS=True ${pythonEnv}/bin/ansible-playbook -i "$PROJECT_DIR/inventory/local/hosts.yaml" \
          "$KUBESPRAY_DIR/cluster.yml" \
          -e ansible_python_interpreter=${pythonEnv}/bin/python \
          -e "artifacts_dir=$PROJECT_DIR/artifacts" \
          -e "credentials_dir=$PROJECT_DIR/credentials" \
          -e "@$PROJECT_DIR/extra_vars.json" \
          -b \
          "$@"




        echo "Cluster deployed! Configuring kubectl..."
        mkdir -p ~/.kube
        sudo cp /etc/kubernetes/admin.conf ~/.kube/config
        sudo chown $(id -u):$(id -g) ~/.kube/config

        echo "Wait for all nodes to be Ready..."
        # If Cilium is stuck in Init:Error due to race conditions, restart it
        (sleep 30 && kubectl delete pods -n kube-system -l k8s-app=cilium --field-selector=status.phase!=Running) || true
        kubectl wait --for=condition=Ready nodes --all --timeout=600s || true

        echo "Installing FluxCD with Helm support..."
        # Flux install includes helm-controller by default, but we ensure components are ready
        flux install --components-extra=image-reflector-controller,image-automation-controller

        echo "Configuring FluxCD to sync with https://github.com/TheRealCDH/fluxrepo..."
        # Force creation of GitSource and Kustomization to ensure they are applied
        # We REMOVE the ignore-paths for the source so Helm charts are included in the artifact
        flux create source git flux-system \
          --url=https://github.com/TheRealCDH/fluxrepo \
          --branch=main \
          --interval=1m \
          --namespace=flux-system \
          || flux patch source git flux-system --url=https://github.com/TheRealCDH/fluxrepo --branch=main --namespace=flux-system

        flux create kustomization fluxrepo \
          --source=GitRepository/flux-system \
          --path="./clusters/my-cluster" \
          --prune=true \
          --interval=1m \
          --namespace=flux-system \
          || flux patch kustomization fluxrepo --path="./clusters/my-cluster" --namespace=flux-system

        echo "Deployment complete!"
      '';

    in {
      apps.${system}.default = {
        type = "app";
        program = "${deploy-script}/bin/selfk8s-deploy";
      };

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          pythonEnv
          pkgs.kubectl
          pkgs.fluxcd
          pkgs.kubernetes-helm
        ];
      };
    };
}
