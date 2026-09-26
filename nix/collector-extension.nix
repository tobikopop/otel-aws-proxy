# The OpenTelemetry Collector **Lambda extension** ("ADOT Collector for
# Lambda") built from the official sources exactly the way ADOT builds it
# (aws-observability/aws-otel-lambda's patch-upstream.sh recipe), producing the
# same layout as the published layer:
#
#   $out/opt/extensions/collector          the extension binary (static Go ELF)
#   $out/opt/collector-config/config.yaml  our collector pipeline
#
# Docker image roots that copy this derivation to / therefore get the collector
# as a platform-managed sidecar: Lambda executes everything under
# /opt/extensions/ and the binary registers itself with the Extensions API.
#
# Why build instead of copying from an image: the only official ADOT image
# (public.ecr.aws/aws-observability/aws-otel-collector) is the ECS/EKS *daemon*
# collector — no Extensions-API registration, no Telemetry-API lifecycle — and
# the Lambda variant is distributed only as Lambda layer zips (credentialed
# fetch). Building pinned official source here stays anonymous, reproducible
# and ceremony-free. See ../README.md for the full sourcing analysis.
#
# Bumping the pins: re-run the patch-upstream recipe and refresh
# go-modules-tidy.patch (README "Upgrading"), then fix vendorHash from the
# build's "got:" line.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

let
  # aws-observability/aws-otel-lambda @ the commit whose collector is
  # "ADOT Collector for Lambda" v0.156.0 (adot/collector/VERSION). The fetch
  # includes the repo's opentelemetry-lambda submodule — the collector source
  # itself — at its recorded gitlink: ONE rev, ONE hash, and the submodule pin
  # can never drift from the overlay. The upstream publishes no release tags,
  # so rev is picked by hand; `nix-update` then fixes sha256 + vendorHash.
  adotRev = "2588ace5837fff59cff28953d83354cb745bc544";
  adotSrc = fetchFromGitHub {
    owner = "aws-observability";
    repo = "aws-otel-lambda";
    rev = adotRev;
    fetchSubmodules = true;
    sha256 = "sha256-wpqGxCxHE+6u8LWUPLSkVFLkvovryzWV0IYrJcrfI6E=";
  };
in
buildGoModule {
  pname = "adot-lambda-collector";
  version = "0.156.0";

  src = adotSrc;

  # The Go module being built is the patched upstream collector.
  modRoot = "opentelemetry-lambda/collector";
  proxyVendor = true;

  # Offline tree surgery (runs in BOTH the vendor fixed-output derivation and
  # the real build — each unpacks the pristine sources fresh).
  postPatch = ''
    # ADOT's own recipe (patch-upstream.sh): overlay adot/* on the upstream
    # tree (the fetched submodule checkout)…
    chmod -R u+w opentelemetry-lambda
    cp -rf adot/* opentelemetry-lambda/

    # …then the collector-relevant patches (the dotnet/terraform patches from
    # the recipe are deliberately skipped — they do not affect the collector).
    pushd opentelemetry-lambda/collector
    patch -p2 < ../../collector.patch
    patch -p2 < ../../manager.patch
    # ADOT's component set replaces upstream's lambdacomponents module…
    go mod edit -replace github.com/open-telemetry/opentelemetry-lambda/collector/lambdacomponents=../../adot/collector/lambdacomponents
    # …and go-modules-tidy.patch is the frozen `go mod tidy` result computed
    # AFTER that replace (order matters): go build must never want to edit
    # go.mod in the network-less sandbox.
    patch -p2 < ${../nix/go-modules-tidy.patch}
    popd
  '';

  # The module graph is already tidied (go-modules-tidy.patch): the vendor
  # derivation only downloads the pinned build list.
  modBuildPhase = ''
    go mod download
  '';

  vendorHash = "sha256-6BkEWePX6ukbKGICHvirkxKEVSY1CaUdqjVcaXRxEqg=";

  # buildPhase (not postBuild) is overridden so the binary lands where the
  # installPhase expects it, without buildGoDir's $out/bin detour. nixpkgs'
  # go builds with CGO off: the extension is a fully static ELF.
  buildPhase = ''
    runHook preBuild
    go build -trimpath -ldflags "-s -w" -o collector-extension .
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/opt/extensions $out/opt/collector-config
    cp collector-extension $out/opt/extensions/collector
    cp ${../collector/config.yaml} $out/opt/collector-config/config.yaml
    runHook postInstall
  '';

  meta = {
    description = "OpenTelemetry Collector Lambda extension (ADOT component set) with the kpop collector pipeline";
    homepage = "https://github.com/aws-observability/aws-otel-lambda";
    license = lib.licenses.asl20;
  };
}
