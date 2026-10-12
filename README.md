# otel-aws-proxy

Flake that builds the [ADOT Collector for Lambda](https://github.com/aws-observability/aws-otel-lambda)
(the OpenTelemetry Collector Lambda extension, ADOT component set) from
pinned official sources, plus our collector pipeline. Copy the
`collector-extension` package's `/opt` tree into a Lambda **container image**
root and the platform runs the collector as a sidecar next to the function:

```text
/opt/extensions/collector          the extension binary (static Go ELF)
/opt/collector-config/config.yaml  the pipeline (traces -> X-Ray)
```

Why the sidecar exists: X-Ray and CloudWatch Logs accept **no OTLP**.
Something has to translate OTel spans into X-Ray segments and SigV4-sign the
calls — the collector extension does exactly that, out of process, with no
per-host/GB ingest like third-party APM and no hand-rolled segment wire
format. Application code (the `otel-aws-utils` crate) only talks OTLP to
`127.0.0.1:4318`.

## Why the binary is BUILT here (sourcing analysis)

| Route | Finding | Verdict |
| --- | --- | --- |
| Copy the binary from the official ADOT image | `public.ecr.aws/aws-observability/aws-otel-collector` contains **one file, `awscollector`** — the ECS/EKS *daemon* collector (verified by pulling the image): no Extensions-API registration, no Telemetry-API lifecycle. No Lambda-variant image exists anywhere (verified on ECR Public) | wrong binary |
| Official Lambda layer zip via `aws lambda get-layer-version-by-arn` | Prebuilt, but requires deploy creds at provisioning time, a manual per-machine step and expiring URLs | non-hermetic |
| Build pinned official source in nix | Anonymous, reproducible, ceremony-free; the same build-from-source model as the Rust services | **used here** |
| Community prebuilt zips (meijeran/aws-otel-lambda releases) | Prebuilt + anonymous, but community-built | documented fallback |

The build (`nix/collector-extension.nix`) reproduces ADOT's own
`patch-upstream.sh` recipe: the pinned `aws-otel-lambda` tree with its pinned
`opentelemetry-lambda` submodule, the ADOT `adot/*` overlay, their two
collector patches, the `lambdacomponents` module replace — plus
`nix/go-modules-tidy.patch`, the frozen `go mod tidy` result so the sandbox
build never wants to edit `go.mod`.

## Consuming

Flake input in a service repo:

```nix
inputs.otel-aws-proxy.url = "github:tobikopop/otel-aws-proxy";

# in the image root:
sidecarRoot = otel-aws-proxy.packages.${system}.collector-extension;
# copy sidecarRoot's /opt tree into the image (contract/nix/image.nix,
# otac/devenv.nix, privy-webhook/flake.nix).
```

The sidecar's config is found at its default path
(`/opt/collector-config/config.yaml`); override per deployment with
`OPENTELEMETRY_COLLECTOR_CONFIG_URI` (file:/, http(s)://, s3://) to re-route
the pipeline (e.g. `otlphttp` to a central collector) without rebuilding
images.

## Upgrading

The upstream publishes no release tags, so bumps are semi-manual — but there
is exactly ONE source pin (rev + sha256) and `nix-update` maintains the hashes:

1. Pick the new commit of `aws-observability/aws-otel-lambda` (check that
   `adot/collector/VERSION` in it reads the collector version you expect),
   **diff its `patch-upstream.sh` against the previous pin** —
   `nix/collector-extension.nix` mirrors its collector-relevant steps, so a
   changed recipe must be mirrored too — and update `adotRev` + `version`.
   The
   `opentelemetry-lambda` submodule comes along at its recorded gitlink —
   never a separate pin.
2. Fix the hashes: `nix-update adot-lambda-collector` — or plain `nix build`
   twice, taking `sha256` (the fetch) and `vendorHash` (the Go module vendor
   dir) from the "got:" lines.
3. Only if `go build` then complains about `go.mod`: re-run the tidy diff to
   refresh `nix/go-modules-tidy.patch` (overlay `adot/*` on the submodule,
   apply `collector.patch` + `manager.patch`, run `go mod edit -replace
   …/lambdacomponents=../../adot/collector/lambdacomponents`, then
   `go mod tidy` and diff `go.mod`/`go.sum` — labels `a/collector/go.mod`,
   `b/collector/go.mod`, same for `go.sum`).
4. `nix flake check`, then rebuild the services' images.
