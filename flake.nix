{
  description = "otel-aws-proxy: the ADOT OpenTelemetry Collector Lambda extension (in-image telemetry sidecar) for the kpop AWS Lambda services";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/54ba4bcec4043e72a4006d825e0d7aff5562008f";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in
    {
      # collector-extension: the sidecar artifact. Copy its /opt tree into a
      # Lambda container image root and the platform starts the collector as an
      # extension next to the function (see README.md).
      packages = forAllSystems (pkgs: {
        collector-extension = pkgs.callPackage ./nix/collector-extension.nix { };
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.collector-extension;
      });

      checks = forAllSystems (pkgs: {
        collector-extension = self.packages.${pkgs.stdenv.hostPlatform.system}.collector-extension;
        # The shipped pipeline must at least be well-formed YAML with the
        # traces pipeline wired; semantic validation happens at deploy smoke
        # (the extension parses config only once the Extensions API answers).
        config-wellformed = pkgs.runCommand "collector-config-wellformed" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
          yq -e '.service.pipelines.traces.exporters | contains(["awsxray"])' ${./collector/config.yaml} > $out
        '';
      });
    };
}
