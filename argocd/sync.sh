#!/usr/bin/env bash
# argocd/sync.sh demo [<release>]
# argocd/sync.sh topic <branch> [<pull request>]
#
# A fake Argo CD sync of an Application in argocd/: the artefact it follows,
# unpacked and printed, and the manifests it would apply. It touches no
# cluster.
#
# demo: argocd/demo.yaml, the latest release; or <release>, as a rollback
# to it would.
# topic: argocd/topics.yaml's preview of the root's pull request from
# <branch>; without its number, gh looks the open one up.
set -euo pipefail
self=$(readlink -f "${BASH_SOURCE[0]}")
cd "$(dirname "$self")"

usage() {
    sed -n '2,13s/^# \{0,1\}//p' "$self"
}

error() {
    echo "error: $*" >&2
    exit 1
}

case ${1-} in
demo)
    (($# == 1 || $# == 2)) || {
        usage >&2
        exit 2
    }
    ;;
topic)
    (($# == 2 || $# == 3)) || {
        usage >&2
        exit 2
    }
    ;;
-h | --help)
    usage
    exit 0
    ;;
*)
    usage >&2
    exit 2
    ;;
esac
for tool in crane jq kustomize yq; do
    command -v "$tool" >/dev/null || error "sync.sh needs $tool"
done

if [ "$1" = demo ]; then
    name=$(yq '.metadata.name' demo.yaml)
    spec=$(yq -o=json '.spec' demo.yaml)
    [ -z "${2-}" ] || spec=$(jq --arg release "$2" '.source.targetRevision = $release' <<<"$spec")
else
    branch=$2
    # The slug of Argo CD's pull-request generator, as the root's build tags
    # it: lower case, runs of anything else as -, at most 50 characters.
    slug=$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]' |
        sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-50 | sed -E 's/-+$//')
    number=${3-}
    if [ -z "$number" ]; then
        command -v gh >/dev/null || error "sync.sh needs gh, or the pull request's number"
        number=$(gh pr list --repo thepartly/gitscale-demo --head "$branch" --state open \
            --json number --jq '.[0].number // empty')
        [ -n "$number" ] || error "no open pull request from $branch"
    fi
    # The generator's template, its parameters filled in.
    template=$(yq -o=json '.spec.template' topics.yaml |
        sed "s/{{\.number}}/$number/g; s/{{\.branch_slug}}/$slug/g")
    name=$(jq -r '.metadata.name' <<<"$template")
    spec=$(jq '.spec' <<<"$template")
fi

repo=$(jq -r '.source.repoURL' <<<"$spec")
repo=${repo#oci://}
revision=$(jq -r '.source.targetRevision' <<<"$spec")
path=$(jq -r '.source.path' <<<"$spec")
namespace=$(jq -r '.destination.namespace' <<<"$spec")
patches=$(jq -c '.source.kustomize.patches // []' <<<"$spec")
ref=$repo:$revision

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

section() {
    printf '\n=== %s\n' "$*"
}

section "Application $name: $ref"
digest=$(crane digest "$ref") || error "no artefact at $ref"
manifest=$(crane manifest "$repo@$digest")
echo "digest:   $digest"
jq -r '.annotations // {} | to_entries[]
    | select(.key != "dev.gitscale.config") | "\(.key): \(.value)"' <<<"$manifest"

section "Unpacked"
mkdir "$work/artefact"
crane export "$repo@$digest" - | tar -x -C "$work/artefact"
(cd "$work/artefact" && find . -type f | sed 's|^\./||' | sort) | while read -r file; do
    printf '\n--- %s\n' "$file"
    cat "$work/artefact/$file"
done

# What Argo CD does with a Kustomize source: its path, the destination's
# namespace, and the Application's own patches.
[ -d "$work/artefact/$path" ] || error "the artefact has no $path"
{
    echo 'apiVersion: kustomize.config.k8s.io/v1beta1'
    echo 'kind: Kustomization'
    echo "namespace: $namespace"
    echo 'resources:'
    echo "  - artefact/$path"
    echo "patches: $patches"
} >"$work/kustomization.yaml"
kustomize build "$work" >"$work/sync.yaml"

section "Would sync into namespace $namespace"
# The unpacked files again, as Argo CD would apply them: folded in a CI log.
[ -z "${GITHUB_ACTIONS-}" ] || echo "::group::$(grep -c '^kind:' "$work/sync.yaml") objects"
cat "$work/sync.yaml"
[ -z "${GITHUB_ACTIONS-}" ] || echo "::endgroup::"

section "Summary"
yq -N '.kind + "/" + .metadata.name' "$work/sync.yaml" | sed 's/^/  /'
echo "images:"
yq -N '.. | select(has("image")) | .image' "$work/sync.yaml" | sort -u | sed 's/^/  /'
