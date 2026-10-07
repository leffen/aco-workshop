### Your goal

You change one thing about how the hardening agent runs, measure it over three runs, and
decide whether three runs can tell you anything.

### Steps

Start the eval within the first ten minutes and work through the questions below while it
runs.

#### 1 · Pick exactly one change

- a line in `agents/prompts/harden.md`, the system prompt
- the safety net: `ACO_SAFETY_NET=0` turns it off for `make eval`. Off is our baseline
  configuration, and the unchanged default matches the "Safety net on" row below.

`MCP_FLAGS` from Lab 1 hard is not on the list: both flags remove the tool that writes, so
every run fails by construction.

#### 2 · Measure it over three runs

Three runs take about 20 minutes:

```bash
ACO_EXPERIMENT=mine-prompt make eval SCENARIO=harden-restricted N=3 AGENT=claude
```

Name the experiment after what you changed, `mine-net` for the safety net, so two tries
are never pooled. Each run starts from a reset namespace with the measured prompt from the
easy tab. To watch one run live while you wait, use `make agent MODE=harden` and paste the
easy tab's prompt.

#### 3 · Undo your change

When you have your answers, undo a prompt change and discard your runs, which were
appended to `evals/results/harden-restricted.jsonl`:

```bash
git checkout agents/prompts/harden.md
git checkout evals/results/harden-restricted.jsonl
```

### What to watch for

The harness runs with the safety net on unless you set `ACO_SAFETY_NET=0`. Pass counts
compare either way, because the net restores the insecure spec and never makes a run pass.
To compare "left broken" with our baseline's 5 of 10, run with `ACO_SAFETY_NET=0`. Each
record's `safety_net` field says what the net did, for example off, not needed or restored.

- Is your difference bigger than three runs can show? Three runs give 0, 1, 2 or 3
  passes. If your change did nothing and the rate stayed near 3 in 10, 0 or 1 of 3 is the
  likely result. Even 3 of 3 against our 3 of 10 gives Fisher's exact test p = 0.07. At
  N=10, 5 of 10 against 3 of 10 gave p = 0.65.
- Did the change move where the runs fail? The eval's calls are the latest rows in
  `make audit`. Under each REFUSED row is why it failed: `forbidden` means the cluster
  refused it, `error converting YAML` means the write was malformed. `Exit code 1` under
  a `Bash` row is the referee reporting red. Any other reason is Kubernetes rejecting what
  the write contained. In our baseline, 39 of 119 writes failed before they reached
  Kubernetes, 31 of them on YAML syntax, and only 8 touched the actual fix (the
  unprivileged image or port 8080).
- What would you need to know before shipping this change to everyone?

### For comparison

Committed records, `harden-restricted`, `gpt-oss:20b`, 10 runs each:

| Configuration | Passed | Left broken |
| --- | --- | --- |
| Baseline, net off | 3/10 | 5/10 |
| Asked for JSON instead of YAML | 1/10 | 3/10 |
| 60 turns instead of 40 | 5/10 | 2/10 |
| Safety net on | 1/10 | 0/10 (restored 4) |

None of the pass rates is distinguishable from another at N=10. `qwen3:4b` and
`llama3.2:3b` passed 0 of 10 each.

### Finished early?

Lab 3 at the same level:

```bash
make lab LAB=3 LEVEL=hard
```
