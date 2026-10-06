# The GitScale demo

Six repositories, every dependency pinned to a release:

```
gitscale-demo ──┬── application-a ──┐
                ├── application-b ──┴── shared-libs
                └── frontend ──┬── application-a
                               └── application-b
```

Every repository but shared-libs also asks for compose, at `imports/compose`.
Releases are calendar versions with a major, `v1-YYYY.MM.DD-hhmmss`, one per
merge to `main`.

You need GitScale, Docker Compose v2, `jq`, and for step 10 `crane` and
`kustomize`. Commands are the [GitScale command line](https://github.com/thepartly/gitscale/blob/main/docs/cli.md).

## 0. Clone

```sh
git clone https://github.com/thepartly/gitscale-demo.git && cd gitscale-demo
git scale ls
git explain imports/shared-libs     # two requests: the higher wins
git explain imports/application-a   # the root's request over frontend's
```

The root never names shared-libs: it arrives through the applications.
application-b asks for an older shared-libs than application-a, and frontend
for an older application-a than the root.

## 1–6. Topics

Each topic below has the same steps. Only the code changes are edited by hand.

```sh
git topic start DEMO-<n>
git topic join imports/<repo>              # the ones it changes
# edit the code
git scale commit -am "DEMO-<n>: <what>"
git scale push                             # dependencies first
git topic status
```

The pull requests' `check` fails: they test the topic, not a release. Merge in
the order `git topic status` gives as next to merge, and after each merge:

```sh
git upgrade --commit && git scale push
```

A repository joined without a code change is rebuilt against the topic, and
its pins are written by `git upgrade --commit`. Join those with
`git topic join --dependants` once the level below carries a change; take off
the ones the row leaves at their release with `git topic leave`. Finish with
`git topic finish`.

| # | Code changed in | Joined, no code change | Left at its release | Render on the topic |
|---|---|---|---|---|
| 1 | application-a | — | application-b, frontend | frontend lacks application-a: label |
| 2 | application-a, frontend | — | application-b | passes |
| 3 | shared-libs | application-a | application-b, frontend | application-b lacks shared-libs, frontend lacks application-a: label |
| 4 | shared-libs | application-a, frontend | application-b | application-b lacks shared-libs: label |
| 5 | shared-libs | application-a, application-b | frontend | frontend lacks both: label |
| 6 | shared-libs, application-a, frontend | application-b | — | passes |

"Label" is `render:allow-released` on the root's pull request: the render
then gives the service lacking a change its release, and says so in its
Deployment's `gitscale-demo/lacks` annotation.

In topic 2, application-a also reads `GREETING_PREFIX`, added to its
`deploy/app.env` in the same commit as the code: the local stack and the
topic's preview get it from that one line.

What promotion writes: shared-libs' release into the configs of the joined
applications only — application-b keeps its older pin in 3 and 4, and
`git explain imports/shared-libs` shows application-a's request winning; an
application's release into frontend's config when frontend is joined, and
always into the root's.

## 7. Raise

After topic 3:

```sh
git topic start DEMO-7-shared-libs
git topic join --dependants imports/shared-libs   # application-b: it asks for less
git upgrade imports/shared-libs                    # raises its pin
git scale push
```

Merge, then `git upgrade --commit`.

## 8. Artefacts

In a clone of frontend:

```sh
git scale prefer --artefact imports/application-a imports/application-b
git scale pull
git scale ls          # both as artefact: sdk/ and nothing of the application
npm ci && npm run build
```

frontend builds from the SDKs' `dist/`. Then topic 2 again:
`git topic join imports/application-a` gives a writable source checkout for
the change, and `git topic finish` returns it to its preference. No file
changes at any step.

## 9. Local stack

During topic 6, from frontend:

```sh
cd imports/frontend
./imports/compose/compose up -d
./imports/compose/compose logs -f application-a
```

shared-libs, application-a and frontend are on the topic: application-a and
frontend run from their working trees with reload, application-b and
application-a's postgres from their images. Open http://localhost:8080/a. An
edit to `greet` in shared-libs restarts application-a, and the page shows it,
with the count carried over.

Once application-a's pipeline has built the pushed commits,
`./imports/compose/compose --image imports/application-a up -d` runs its
image instead. From the root with nothing joined, `./imports/compose/compose
up -d` runs the whole system from its release images.

## 10. Deployment artefacts

The root's build renders the deployment and publishes it as the root's
artefact. During topic 6, after a push to the root:

```sh
R=ghcr.io/thepartly/gitscale-demo/gitscale
crane manifest $R:topic-demo-6 | jq '.layers | length, .annotations["dev.gitscale.hash"]'
git scale hash                              # the same hash
crane export $R:topic-demo-6 - | tar -x
kustomize build rendered/demo | grep image: # every service at the image of its sources
```

Another push to the root moves `topic-demo-6` to the new hash. After the
merges and `git upgrade --commit`:

```sh
crane ls $R
crane digest $R:<release>; crane digest $R:released
```

The release, `released` and the topic's last render are one digest: nothing
was rendered twice. An Argo CD following those tags — `argocd/` — deploys a
preview per topic and the demo environment; the demo itself touches no
cluster.
