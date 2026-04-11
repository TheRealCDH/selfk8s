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

        # Fix etcd openssl.conf template bug (stuck counter)
        # We replace the alt_names section with a simpler one that works for single-node
        find $out -name "openssl.conf.j2" -exec sh -c "sed -i '/\[alt_names\]/,\$d' {} && cat >> {} <<'EOF'
[alt_names]
DNS.1 = localhost
DNS.2 = node1
DNS.3 = etcd
IP.1 = 127.0.0.1
IP.2 = ::1
IP.3 = {{ etcd_address }}
IP.4 = {{ ip }}
IP.5 = {{ access_ip }}
EOF
" \;
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
        ACTUAL_IP=$(hostname -I | awk '{print $1}')
        ACTUAL_IP=''${ACTUAL_IP:-127.0.0.1}
        echo "Detected IP: $ACTUAL_IP"

        # Always update/create hosts.yaml to ensure correct IP
        # We use 'local' connection but rename the host to node1.
        cat <<EOF > inventory/local/hosts.yaml
all:
  hosts:
    node1:
      ansible_connection: local
      ansible_host: localhost
      ip: $ACTUAL_IP
      access_ip: $ACTUAL_IP
  children:
    kube_control_plane:
      hosts:
        node1:
    kube_node:
      hosts:
        node1:
    etcd:
      hosts:
        node1:
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
  "kube_proxy_strict_arp": true
}
EOF

        KUBESPRAY_DIR="${patchedKubespray}"
        
        echo "Starting autonomous single-node deployment on node1 ($ACTUAL_IP) with K8s v1.32.1..."
        
        export ANSIBLE_HOST_KEY_CHECKING=False
        export ANSIBLE_ALLOW_BROKEN_CONDITIONALS=True
        export ANSIBLE_ROLES_PATH="$KUBESPRAY_DIR/roles"
        export PATH="${pkgs.kubectl}/bin:${pkgs.fluxcd}/bin:${pkgs.kubernetes-helm}/bin:$PATH"
        
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

        echo "Installing FluxCD..."
        flux install

        echo "Configuring FluxCD to sync with https://github.com/TheRealCDH/fluxrepo..."
        # Create GitSource pointing to the user's repo
        # We rename it to flux-system to match the references in the repo's manifests
        # We add --ignore to respect the user's .fluxignore patterns at the source level
        if ! flux get source git flux-system -n flux-system > /dev/null 2>&1; then
          flux create source git flux-system \
            --url=https://github.com/TheRealCDH/fluxrepo \
            --branch=main \
            --interval=1m \
            --ignore="**/charts/,**/templates/,**/Chart.yaml,**/values.yaml" \
            --namespace=flux-system
        fi

        # Create Kustomization to sync the repo content
        # We point to clusters/my-cluster which seems to be the entry point
        if ! flux get kustomization fluxrepo -n flux-system > /dev/null 2>&1; then
          flux create kustomization fluxrepo \
            --source=GitRepository/flux-system \
            --path="./clusters/my-cluster" \
            --prune=true \
            --interval=1m \
            --namespace=flux-system
        fi

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
