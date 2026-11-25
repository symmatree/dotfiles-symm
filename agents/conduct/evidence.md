# Evidence

Incidents behind the rules in [../conduct.md](../conduct.md).

## Get the actual error before naming a cause

Proxmox edge CTs failed to start with LXC's generic `sync_wait: expected sequence
number 7 / Failed to spawn container`. The config had just changed to mount a file
over `/etc/alloy`, so the agent wrote "mounting over /etc/alloy breaks the OCI spawn"
into a commit, PR, docs and an issue comment. One `pct start --debug` later the real
error was `Failed to exec "/sbin/init"`: the same change had removed the entrypoint.
The mount was innocent, which also meant a clean fix existed that had been ruled out.

The generic symptom named the stage that failed, not what failed. Instead: run the
failing operation directly with debug output (`--debug`, `journalctl`, the task log,
`dmesg`/audit) and expect a concrete message. Until you have it, say "symptom is Z;
root cause not yet captured".

## Do not hide output

`2>/dev/null`, `| head`, `grep -iE "error|fail"` over a log, and capturing output to
print only on success all optimize for the case where nothing is wrong. The real
error rarely matches the guessed keyword.

The same habit broke an approval: a `git reset --hard` was described as discarding
10 files, listed from `git status | head`. The full status showed 33, including whole
deleted directories. When the question is the set -- files to discard, gaps, "did I
miss anything" -- truncation only produces a wrong answer cheaply and hides that it
did.

Instead: let stderr print; read the raw tail or grep with `-C`; count with `wc -l`,
aggregate with `sort | uniq -c`, project columns with `awk`; if you truncate, print
"showing 10 of 33". In scripts, `cmd || { echo "failed to do X"; exit 1; }` replaces
the tool's error with a guess -- let `set -e` surface the real one. Retry only on a
specific transient signature you can recognize.

## Check an error is still happening

After a restart of five cilium agents, wk-2 logged a reconcile backlog: 9 lines over
40 minutes with a shrinking retry count, then silence for 24 hours. The agent called
it a fault "recurring every 5 minutes", and the false lead cost several turns chasing
symptoms that were Seth's work VPN. The agent's own restart had caused the burst.
Asked "did you look at the actual map?", the agent had inferred from a count rather
than dumping the state.

Instead: before "recurring", check the latest timestamp and the count in the last 1h
and 3h, and ask whether something you just did caused it. When asked about the
actual X, dump X.

## Search history broadly

A history review of tiles searched only the incident's topics and missed #589 ("wrong
yq flavor", fixed by #592), which explained the exact `yq`/`helm` symptom. The agent
re-derived it from scratch and briefly called it broken everywhere.

Instead: search for the tool name, the literal error string and the infra terms as
well as the topic. If you are re-deriving something involved, check whether it is
already filed.

## Investigate what Seth points at

During oauth2-proxy allowlist work, Seth mentioned being "welcomed back". It was a
non-allowlisted account still getting in -- the exact failure under test. The agent
explained it as cached Google consent; Seth had to repeat the clue twice. The cause,
`email_domains=*` still set in the chart's config file after the CLI flag was
removed, was one `kubectl get configmap` away.

Instead: verify the flagged thing on the live system before offering a reassuring
reading, empirically on a security boundary. When fixing a setting, check every
source that feeds it: CLI flags, config file, environment, chart defaults.

## Seth's account outranks telemetry

Seth said "I just hit it through a browser now". The proxy log had gone quiet four
minutes earlier and the session's user agent was Android, so the agent concluded Seth
had loaded the ungated hostname and explained the hostname scheme back to its
designer. The session was Seth's, the phone was the browser, and an idle loaded page
sends no more requests: silence after a load is what success looks like.

Instead: when telemetry seems to disagree with Seth's first-hand account, list at
least two explanations that do not need Seth to be wrong. Ask what would have to be
true for the event to happen unlogged -- an idle page, a websocket, sampling, a
different component. If it still does not reconcile, say what you observed and ask.
