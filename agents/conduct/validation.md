# Validating changes

Incidents behind the rules in [../conduct.md](../conduct.md).

## Validate the step that gates success

To read the host journal, tiles#692 made the Proxmox edge Alloy CT privileged. The
agent validated that a privileged CT's root can read the journal -- near-certain by
definition -- and marked "can a privileged CT be created from the OCI image at all?"
as verified at rollout. It cannot: Proxmox OCI app containers create only
unprivileged (`setgid(0): Invalid argument`). `tf/nodes` applies prod on merge, so
rollout meant destroying all four CTs and failing to recreate them: about two days
without the edge feed and a wedged prod apply, reverted in #694.

Instead: ask which one step, if it fails, makes the rest moot, and validate that. If
it is provable only at apply, say so plainly and do not bundle it. A destroy and
recreate is a replace: if the create fails, the resource is gone.

## No credentials is not untestable

For tiles#772 the agent could not run `terraform plan` in `tf/bootstrap`, so it
shipped `import` blocks marked unverified. Seth's plan showed `1 to import, 3 to
add`: Terraform honours only the first of several static `import` blocks aimed at
instances of one `for_each` module. That is a question about a Terraform mechanism,
and it reproduced in two minutes in a scratch directory with `terraform_data` and no
credentials.

Instead: split the unknown into "needs the real system's state" and "does this
construct behave as I think". The second kind almost always reproduces offline; build
the sandbox before calling it unverifiable.

## A local validator is not the system

`HostnameConfig: auto: off`, a value seen only in web docs, passed `talosctl
validate` and went straight into a prod taint and apply with reboot. The nodes
rejected it (`either 'auto' or 'hostname' must be set`: `off` is the enum's zero
value, read as unset), config apply failed on all six VMs, etcd never bootstrapped
and prod went down until a revert and full re-apply.

Instead: apply a value the running system has not accepted before to the test cluster
or one node first. If that is not possible, say the local validator is necessary,
not sufficient, before a destructive operation.

## Test on the real path

Asked whether Talos could run on the Cubie, the agent turned the question into a list
of worries to disprove, with throwaway setups: a non-joined Talos config, forced
kernel hangs, trial runs of fallback options, a boot-counter test that only confirmed
a description. Seth: "I don't see any point in trying things that we don't want to
end up with, unless there's a specific thing we can learn better that way."

Instead: name the end state and take the shortest path to it -- the actual image,
joined as the actual worker -- and fix what breaks there. Name a risk as "this is
where it could break, and we will see it when we get there".

## Do not run CI's checks serially before CI

Mid-outage, Seth asked for memory requests on the oauth2-proxies -- two lines of
YAML. The agent ran tiles' full `render-apps-diff.sh` locally before pushing, which
renders every Application for both clusters twice, and Seth waited minutes for output
the `render-diff` workflow posts on the PR anyway. The instruction to run it locally
had been agent-written; Seth had it changed (tiles#955).

Instead: commit and push so CI starts, then run whatever local check helps while it
runs. Run one first only when its answer changes what you push. Say before starting
anything that takes more than a few seconds.
