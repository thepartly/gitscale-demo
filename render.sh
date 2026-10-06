#!/usr/bin/env bash
# render.sh [--allow-released]
#
# The deployment of exactly the sources checked out, into rendered/demo/:
# every service at the image of its own sources, from imports/compose/tags.
# It never warns: a service gets that image, or the render fails.
#
# --allow-released gives a service lacking a topic change its release, and
# its Deployment says what it lacks, in the gitscale-demo/lacks annotation.
set -euo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

usage() {
    sed -n '2,10s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

tag_options=()
case ${1-} in
"") ;;
--allow-released) tag_options=(--allow-released) ;;
-h | --help)
    usage
    exit 0
    ;;
*)
    usage >&2
    exit 2
    ;;
esac
for tool in crane jq kustomize; do
    command -v "$tool" >/dev/null || {
        echo "error: render.sh needs $tool" >&2
        exit 1
    }
done

registry=ghcr.io/thepartly/gitscale-demo
services=(application-a application-b frontend)

lines=$(imports/compose/tags "${tag_options[@]}" "${services[@]/#/imports/}")
declare -A tag=() lacks=()
while IFS='=' read -r key value; do
    name=${key#GITSCALE_DEMO_}
    case $name in
    *_TAG) tag[${name%_TAG}]=$value ;;
    *_LACKS) lacks[${name%_LACKS}]=$value ;;
    esac
done <<<"$lines"

failed=0
for service in "${services[@]}"; do
    key=${service^^}
    key=${key//-/_}
    if ! crane manifest "$registry/$service:${tag[$key]}" >/dev/null 2>&1; then
        echo "$service: no image for ${tag[$key]:0:4}…; push it, or wait for its pipeline" >&2
        failed=1
    fi
done
((failed == 0)) || exit 1

# A wrapper overlay: overlays/demo, its images at these tags, and what a
# service given its release lacks, on its Deployment.
work=rendered/.overlay
rm -rf "$work" rendered/demo
mkdir -p "$work" rendered/demo
{
    echo 'apiVersion: kustomize.config.k8s.io/v1beta1'
    echo 'kind: Kustomization'
    echo 'resources:'
    echo '  - ../../overlays/demo'
    echo 'images:'
    for service in "${services[@]}"; do
        key=${service^^}
        key=${key//-/_}
        echo "  - name: $registry/$service"
        echo "    newTag: \"${tag[$key]}\""
    done
    if ((${#lacks[@]})); then
        echo 'patches:'
        for service in "${services[@]}"; do
            key=${service^^}
            key=${key//-/_}
            [ -n "${lacks[$key]-}" ] || continue
            echo '  - patch: |-'
            echo '      apiVersion: apps/v1'
            echo '      kind: Deployment'
            echo '      metadata:'
            echo "        name: $service"
            echo '        annotations:'
            echo "          gitscale-demo/lacks: \"${lacks[$key]}\""
        done
    fi
} >"$work/kustomization.yaml"

# The output names no namespace: each environment chooses its own, and
# patches what differs through the kustomization beside it.
kustomize build "$work" >rendered/demo/manifests.yaml
printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - manifests.yaml\n' \
    >rendered/demo/kustomization.yaml
rm -rf "$work"
echo "rendered/demo: $(grep -c '^kind:' rendered/demo/manifests.yaml) objects"
