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
        
        echo "Starting autonomous single-node deployment on localhost..."
        
        export ANSIBLE_HOST_KEY_CHECKING=False
        export PATH="${pkgs.kubectl}/bin:${pkgs.fluxcd}/bin:${pkgs.kubernetes-helm}/bin:$PATH"
        
        # Run ansible-playbook locally as root
        sudo ${pythonEnv}/bin/ansible-playbook -i "$PROJECT_DIR/inventory/local/hosts.yaml" \
          $KUBESPRAY_DIR/cluster.yml \
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
