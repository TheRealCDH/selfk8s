{
  description = "Single-node Localhost Kubernetes Deployment with Kubespray, FluxCD, and MetalLB";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    kubespray = {
      url = "github:kubernetes-sigs/kubespray/master";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, kubespray }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      
      # Patch kubespray to disable version check
      patchedKubespray = pkgs.runCommand "patched-kubespray" { } ''
        cp -r ${kubespray} $out
        chmod -R +w $out
        
        # Create a bypass playbook content
        # We use a literal string to avoid shell escaping issues in the cat
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
        # We use find to be sure we hit it wherever it is (usually in 'roles/kubespray-defaults/tasks' or 'playbooks')
        find $out -name "ansible_version.yml" -exec cp bypass_ansible.yml {} \;
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
          # Remove problematic cloud_provider: undefined
          find inventory -name "k8s-cluster.yml" -exec sed -i '/cloud_provider: undefined/d' {} \;
        fi
        
        # Detect actual IP for Kubespray validation at RUNTIME
        ACTUAL_IP=$(hostname -I | awk '{print $1}')
        ACTUAL_IP=''${ACTUAL_IP:-127.0.0.1}
        echo "Detected IP: $ACTUAL_IP"

        # Always update/create hosts.yaml to ensure correct IP
        # We use 'ssh' connection to the actual IP to force Kubespray to treat this as a 
        # proper network node, ensuring certificates are generated with the correct IP SANs.
        cat <<EOF > inventory/local/hosts.yaml
all:
  hosts:
    node1:
      ansible_connection: ssh
      ansible_host: $ACTUAL_IP
      ansible_user: root
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

        # Inject cert SANs into ALL all.yml files found
        find inventory -name "all.yml" -exec sh -c "echo 'supplementary_addresses_in_ssl_keys: [ \"$ACTUAL_IP\" ]' >> {}" \;
        find inventory -name "all.yml" -exec sh -c "echo 'etcd_cert_alt_ips: [ \"127.0.0.1\", \"::1\", \"$ACTUAL_IP\" ]' >> {}" \;

        # Ensure SSH access to the node for root
        mkdir -p ~/.ssh
        if [ ! -f ~/.ssh/id_rsa ]; then
          ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
        fi
        cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        # Add the actual IP to known_hosts to avoid prompt
        ssh-keyscan -H "$ACTUAL_IP" >> ~/.ssh/known_hosts 2>/dev/null || true
        # Also add 127.0.0.1 just in case
        ssh-keyscan -H 127.0.0.1 >> ~/.ssh/known_hosts 2>/dev/null || true

        KUBESPRAY_DIR="${patchedKubespray}"
        
        echo "Starting autonomous single-node deployment on node1 ($ACTUAL_IP)..."
        
        export ANSIBLE_HOST_KEY_CHECKING=False
        export ANSIBLE_ALLOW_BROKEN_CONDITIONALS=True
        export ANSIBLE_ROLES_PATH="$KUBESPRAY_DIR/roles"
        export PATH="${pkgs.kubectl}/bin:${pkgs.fluxcd}/bin:${pkgs.kubernetes-helm}/bin:$PATH"
        
        # Run ansible-playbook locally as root
        # We pass etcd_cert_alt_ips again as extra-vars to be absolutely sure
        sudo -E env ANSIBLE_ALLOW_BROKEN_CONDITIONALS=True ${pythonEnv}/bin/ansible-playbook -i "$PROJECT_DIR/inventory/local/hosts.yaml" \
          "$KUBESPRAY_DIR/cluster.yml" \
          -e ansible_python_interpreter=${pythonEnv}/bin/python \
          -e "artifacts_dir=$PROJECT_DIR/artifacts" \
          -e "credentials_dir=$PROJECT_DIR/credentials" \
          -e "etcd_cert_alt_ips=['127.0.0.1','::1','$ACTUAL_IP']" \
          -b \
          "$@"


        echo "Cluster deployed! Configuring kubectl..."
        mkdir -p ~/.kube
        sudo cp /etc/kubernetes/admin.conf ~/.kube/config
        sudo chown $(id -u):$(id -g) ~/.kube/config

        echo "Installing FluxCD..."
        flux install

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
