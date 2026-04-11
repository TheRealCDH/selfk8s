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
        # Use PROJECT_DIR if we are in the repo, otherwise we might be running from nix store
        # but Kubespray needs the inventory files.
        # If running via 'nix run github:...', pwd is where the user ran it.
        # We should probably copy the inventory to a writable temp dir if we want it to be fully autonomous
        # or assume the user has cloned it. 
        # But 'nix run' usually implies we want it to work without cloning.
        
        # Let's try to find where the project files are. 
        # If we are in the store, we need to copy them out to use them.
        
        PROJECT_DIR=$(pwd)
        if [ ! -d "$PROJECT_DIR/inventory" ]; then
          echo "Inventory not found in current directory. Creating a default single-node inventory..."
          mkdir -p inventory/local/group_vars/all
          mkdir -p inventory/local/group_vars/k8s_cluster
          
          cat <<EOF > inventory/local/hosts.yaml
all:
  hosts:
    localhost:
      ansible_connection: local
      ansible_host: 127.0.0.1
      ip: 127.0.0.1
      access_ip: 127.0.0.1
  children:
    kube_control_plane:
      hosts:
        localhost:
    kube_node:
      hosts:
        localhost:
    etcd:
      hosts:
        localhost:
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
EOF
          # We'll use defaults for group_vars if they don't exist
        fi

        KUBESPRAY_DIR="${patchedKubespray}"
        
        echo "Starting autonomous single-node deployment on localhost..."
        
        export ANSIBLE_HOST_KEY_CHECKING=False
        # Allow broken conditionals for Ansible 2.18+ compatibility with older playbooks
        export ANSIBLE_ALLOW_BROKEN_CONDITIONALS=True
        # IMPORTANT: Fix the roles path so Ansible can find 'dynamic_groups' and other roles
        export ANSIBLE_ROLES_PATH="$KUBESPRAY_DIR/roles"
        export PATH="${pkgs.kubectl}/bin:${pkgs.fluxcd}/bin:${pkgs.kubernetes-helm}/bin:$PATH"
        
        # Run ansible-playbook locally as root
        # We point to the cluster.yml in the kubespray source
        sudo -E ${pythonEnv}/bin/ansible-playbook -i "$PROJECT_DIR/inventory/local/hosts.yaml" \
          "$KUBESPRAY_DIR/cluster.yml" \
          -e ansible_python_interpreter=${pythonEnv}/bin/python \
          -e "ansible_connection=local" \
          -e "artifacts_dir=$PROJECT_DIR/artifacts" \
          -e "credentials_dir=$PROJECT_DIR/credentials" \
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
