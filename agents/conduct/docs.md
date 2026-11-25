# Filing and docs

Incidents behind the rules in [../conduct.md](../conduct.md).

## Docs describe the tree as it is

- "In this PR", "planned follow-up" and "next we'll" are stale on merge. A doc that
  restates an issue's roadmap rots when the issue moves; link the issue.
- A plain-YAML `deploy/` dir written "to be kubectl-appliable" before the Helm chart
  existed became dead duplicate config and needed a second PR (#673) to delete. Drop
  scaffolding before the PR, not after.
- Docs written as an argument -- "the point is not X, it is Y", bolded corrections,
  recited measurements -- defend the design against an imagined skeptic. Seth is a
  stricter test than the skeptic and does not need the defense carried in the repo.
  Write what is. No "corrected from" or "this previously said".

## Never invent a rationale

For tiles#749 the agent did not know why Grafana OAuth was wanted, so it wrote a
borgmon/WAN dependency into the issue as Seth's intent. The actual reason was not
having to fetch the admin password from 1Password. Invented reasons later get cited
back at Seth as authority. If the why is unknown, ask, or write only the what.

## Concepts belong in docs, not comments

The agent wrote multi-paragraph essays at the top of `.tf` files -- why `helm_release`
can plan against an absent cluster, taint versus state-rm ordering -- and gave a new
chart no README in a directory where all nine siblings had one. Seth: "a CONCEPT can't
really be described in the various files that implement it, because it's inherently
distributed across them and you don't even know it exists so you would never find
them."

The split: write local intent ("this field matches the value in file X, so the
frontend discovers the backend"). Do not write global intent -- why this package,
which incident, proof the conclusion was right -- which is usually invented for lack
of asking. In tiles#758, `charts/cilium/application.yaml` got twelve lines reciting a
202/202 key measurement where one sentence of mechanism was the fact.
