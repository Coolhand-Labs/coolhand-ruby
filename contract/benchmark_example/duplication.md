# Benchmark example duplication

## The local and live scenarios stay separate

The two scenarios read as two linear scripts: a local one against a fake in-process LLM server,
and a live one against real providers. Both compute the same three medians. Sharing that four-line
fragment would add a helper to a script that is read top to bottom to see what each scenario
measures, for no reuse beyond these two.

```parallel
Object#run_local_scenario
Object#run_live_scenario
```
