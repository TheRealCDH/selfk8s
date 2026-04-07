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
        
        # We need to copy some files from Kubespray to a writable directory
        # because Kubespray might try to create some temp files in its own dir.
        # But since we use it as a flake input, it's in the nix store (read-only).
        # Most of the playbooks should be fine, but we'll see.
        
        echo "Running Kubespray deployment on localhost..."
        export ANSIBLE_HOST_KEY_CHECKING=False
        export PATH="${pkgs.kubectl}/bin:${pkgs.fluxcd}/bin:${pkgs.kubernetes-helm}/bin:$PATH"
        
        # Use ansible-playbook from the python environment
        # We need to run it as sudo because it will manage system packages and directories
        sudo ${pythonEnv}/bin/ansible-playbook -i $PROJECT_DIR/inventory/local/hosts.yaml \
          $KUBESPRAY_DIR/cluster.yml \
          -e ansible_connection=local \
          -e ansible_python_interpreter=${pythonEnv}/bin/python \
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
