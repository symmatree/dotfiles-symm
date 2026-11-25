# Design

Incidents behind the rules in [../conduct.md](../conduct.md).

## The stack is designed on purpose

In tiles#768 the agent called push-to-main applying both test and prod "a missing
promote gate" and proposed force-pushing the `test` tag to route around it; framed
Terraform installing Cilium and Argo CD, which `tf/nodes/k8s-cilium.tf` explains
inline, as a path to avoid; and proposed undoing control-plane nodeSelector pinning
before asking what it was for. Later in the same session, asked for a new Grafana
token, it created a new service account with a lower role instead of rotating the
existing one; asked to install uvx, it pip-installed into `$HOME` when the image's
Dockerfile says the toolchain comes from dotfiles-symm's install playbook. Seth:
"Either ask more questions or make better guesses if you refuse to ask."

Tells: "stale", "missing", "no gate", "obstacle"; a mechanism to get around a
property; "decisions I need from you" with slots for answers. Instead: ask what it is
for, bringing the mechanism and the measurement. Look for the existing artifact
before inventing a parallel one.

## Use the library

For tiles#674 the agent hand-rolled a 220-line registry client -- reference parsing,
`WWW-Authenticate` parsing, token JSON, docker.io normalization -- for "minimal
deps" and offline tests, in a module that already vendored client-go.
go-containerregistry did it in 46 lines, with other registries and docker
credentials included, and its in-memory registry made the offline test better. Keel
and Flux image automation were never checked as a whole-job alternative. Seth:
"Writing our own code isn't a virtue, it's an expensive isolation mechanism that had
better be justified."

Instead: name the library at design time. When code stays hand-written, the comment
gives the specific reason the library does not fit. This does not contradict
carrying cost: that targets guards and flags we own, and code we write is the
expensive kind.

## Do not invent infrastructure

Discussing Cubie kernel builds, the agent twice offered "an x86 Debian VM on Proxmox"
with more RAM and cores, and a "well under an hour" estimate. No such host exists:
the NUCs run the cluster, and lancer takes one ~16 GB job and is not Proxmox. Seth:
"offer an alternative that doesn't exist, and is wildly more appealing because of the
reasons why it doesn't exist."

Instead: before listing a host, point to where you confirmed it exists and has room
(inventory, `tf/nodes`, Seth's word). Otherwise ask whether there is a machine for X.
