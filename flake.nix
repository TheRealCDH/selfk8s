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
        KUBESPRAY_DIR="${kubespray}"
        
        # Configuration from environment or defaults
        TARGET_IP=''${TARGET_IP:-127.0.0.1}
        ANSIBLE_CONNECTION=''${ANSIBLE_CONNECTION:-local}
        ANSIBLE_USER=''${ANSIBLE_USER:-$(whoami)}
        
        echo "Preparing deployment for $TARGET_IP via $ANSIBLE_CONNECTION..."
        
        export ANSIBLE_HOST_KEY_CHECKING=False
        export PATH="${pkgs.kubectl}/bin:${pkgs.fluxcd}/bin:${pkgs.kubernetes-helm}/bin:${pkgs.gnused}/bin:${pkgs.openssh}/bin:$PATH"
        
        # Create a temporary inventory file with the correct IP
        TEMP_INVENTORY=$(mktemp)
        cat <<EOF > "$TEMP_INVENTORY"
all:
  hosts:
    target-node:
      ansible_host: $TARGET_IP
      ip: $TARGET_IP
      access_ip: $TARGET_IP
      ansible_connection: $ANSIBLE_CONNECTION
      ansible_user: $ANSIBLE_USER
  children:
    kube_control_plane:
      hosts:
        target-node:
    kube_node:
      hosts:
        target-node:
    etcd:
      hosts:
        target-node:
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
EOF

        # Run ansible-playbook
        # Use extra vars to override any local settings
        # We use -b for become (sudo on remote)
        ANSIBLE_BECOME_CMD=""
        if [ "$ANSIBLE_CONNECTION" = "local" ]; then
          ANSIBLE_BECOME_CMD="sudo"
        fi

        # Set python interpreter for the target node
        PYTHON_INTERPRETER="/usr/bin/python3"
        if [ "$ANSIBLE_CONNECTION" = "local" ]; then
          PYTHON_INTERPRETER="${pythonEnv}/bin/python"
        fi

        $ANSIBLE_BECOME_CMD ${pythonEnv}/bin/ansible-playbook -i "$TEMP_INVENTORY" \
          $KUBESPRAY_DIR/cluster.yml \
          -e "ansible_python_interpreter=$PYTHON_INTERPRETER" \
          -e "ansible_connection=$ANSIBLE_CONNECTION" \
          -e "ansible_user=$ANSIBLE_USER" \
          -e "artifacts_dir=$PROJECT_DIR/artifacts" \
          -e "credentials_dir=$PROJECT_DIR/credentials" \
          -e "@$PROJECT_DIR/inventory/local/group_vars/all/all.yml" \
          -e "@$PROJECT_DIR/inventory/local/group_vars/k8s_cluster/k8s-cluster.yml" \
          -e "@$PROJECT_DIR/inventory/local/group_vars/k8s_cluster/addons.yml" \
          -b \
          "$@"

        echo "Cluster deployed! Configuring kubectl..."
        
        if [ "$TARGET_IP" = "127.0.0.1" ] || [ "$TARGET_IP" = "localhost" ]; then
          mkdir -p ~/.kube
          sudo cp /etc/kubernetes/admin.conf ~/.kube/config
          sudo chown $(id -u):$(id -g) ~/.kube/config
        else
          echo "Remote deployment detected. Fetching kubeconfig..."
          mkdir -p ~/.kube
          # Try to fetch from remote
          ssh $ANSIBLE_USER@$TARGET_IP "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/config.tmp
          # Update the server address in the fetched config
          sed -i "s/127.0.0.1/$TARGET_IP/g" ~/.kube/config.tmp
          mv ~/.kube/config.tmp ~/.kube/config
          echo "Kubeconfig updated for remote access at $TARGET_IP"
        fi

        echo "Installing FluxCD..."
        flux install

        echo "Deployment complete!"
        rm "$TEMP_INVENTORY"
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
