# Scope of action

Incidents behind the rules in [../conduct.md](../conduct.md).

## Approval covers the scope you described

Seth approved a `git reset --hard` in a shared checkout described as discarding 10
files, from `git status | head`. The full status showed 33, including deleted
directories. The agent reset anyway and mentioned the difference afterwards. Every
path happened to exist in `origin/main`, so nothing was lost, by luck. Seth: "An
approval granted on information you give me, is invalidated by discovering that
information is invalid."

Instead: enumerate the target completely before any destructive command and quote
that scope when asking. If it turns out bigger, stop and re-ask; "it is bigger than I
said" goes before the command, never in the summary after it.

## Cannot do it? Say so and stop

Seth asked for a reboot of the Proxmox host carrying wk-2. With no Proxmox access,
the agent rebooted the wk-2 VM and reported the substitution at the end of a long
message; challenged, it started rebooting cp-2 instead "to complete the approved
action". Seth spent an hour trying to explain why cp-2 came back unhappy from a hard
cycle it never had.

The request carried reasoning the agent lacked: a host reboot cycles both guests on
purpose, because a thrashing guest contaminates its co-tenant through shared CPU,
memory bandwidth and NVMe. A VM reboot is not the same operation.

Instead: a substitution is a question, not a footnote. State the blocker, list the
ways through it (Seth runs it with `! cmd`, a credential path, an MCP server), and
let Seth choose. Narrowing an instruction and quoting the narrowing back as a limit
is worse than asking.

## Smallest blast radius

To recreate one pruned Secret, the agent recommended restarting
`onepassword-connect-operator`, which every OnePasswordItem in every namespace
depends on. Seth deleted the one OnePasswordItem CR and let Argo recreate it.

Instead: rank recoveries by blast radius. The already-broken unit is the cheapest
thing to disturb. Do not label a broad restart "Recommended".

## Surface conflicting repo guidance

Seth asked for memory requests on the oauth2-proxies at the p95 of the last day's
usage. The agent rounded up to the next 8Mi, following a repo rule written for
another chart, and also changed argocd's existing request. Seth: "I would have said
something lower than p95 if I thought you were sizing it up."

Instead: when a documented convention differs from the instruction, name the
difference in one line and do what Seth picks. The scope is what the request was
about.
