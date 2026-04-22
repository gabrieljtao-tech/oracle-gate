# oracle-gate

An adversarial-review gate that stops AI agents from self-declaring their work complete. Extracted from a production multi-agent system where the pattern has processed 100+ real build reviews.

> Work in progress. This repo contains the cleaned schema and documentation. The full runtime (dispatch triggers, circuit breaker automation, Fortune Teller integration) runs on a private Supabase stack.

## The pattern, in one sentence

No agent can say "done." A separate reviewer agent (the Oracle) independently tests the work, and only an Oracle pass verdict reaches the human.

## Why this exists

Most multi-agent failures share a root cause: the agent that built the thing is also the agent that decides the thing is finished. This creates a structural conflict of interest. The builder is biased toward completion. It will round corners, skip edge cases, and interpret ambiguous specs in whatever direction gets to "shipped" fastest.

The oracle gate removes that conflict by splitting the build/review responsibility across independent agents with opposing incentives:

- The **builder** wants to ship.
- The **oracle** wants to find bugs.
- The **human** only sees the result after both have done their job.

## How it works

```
Builder finishes work
       |
       v
INSERT INTO oracle_queue (project, deploy_url, builder_agent, ...)
       |
       v
Dispatch trigger fires:
  - Self-audit firewall check (builder cannot review own work)
  - If clean, writes oracle_handoff to reviewer agent
  - If blocked, escalates to human
       |
       v
Oracle agent enters review mode:
  - Loads oracle system prompt (adversarial, not cooperative)
  - Tests deploy_url against spec_ref
  - Writes verdict to oracle_verdicts
       |
       v
Verdict router fires:
  - PASS  -> reset circuit breaker, notify human
  - FAIL  -> increment circuit breaker, route fix instructions to builder (silently)
  - BLOCKED -> escalate to human
       |
       v
Circuit breaker (3 consecutive fails):
  - Escalate to human: "builder loop not converging, needs intervention"
```

## Key design decisions

**The builder never sees "pass."** On pass, the Oracle notifies the coordinator (brain), which surfaces the result to the human. The builder does not get a success signal it could learn to game.

**Fail routes are silent to the human.** When Oracle fails a build, fix instructions go directly back to the builder. The human only hears about it if the circuit breaker trips (3 consecutive fails on the same project). This keeps the human's attention budget focused on things that actually need them.

**Self-audit firewall.** If the same agent that built the work is also assigned as the Oracle reviewer, the dispatch trigger blocks the review and escalates. You cannot grade your own exam.

**Circuit breaker, not infinite retry.** Three consecutive Oracle fails on a project trip the breaker, which escalates to a human with a "stuck" flag. This prevents silent infinite loops where a bad builder and a strict oracle cycle forever.

**Magician's tell.** Every Oracle verdict includes a `magicians_tell` field: a one-line note about anything the Oracle noticed that felt like the builder was trying to make things look better than they are. Named after the concept that every magic trick has a tell if you know where to look.

## Schema overview

`schema.sql` contains three tables and three functions:

**Tables**
- `oracle_queue` - builders submit work here. Status tracks the lifecycle: pending, running, done, failed_to_dispatch.
- `oracle_verdicts` - the Oracle writes its review here. Verdict is pass, fail, or blocked. Includes structured bug reports, spec deviations, and the magician's tell.
- `oracle_circuit_breaker` - tracks consecutive failures per project. Resets on pass. Escalates at 3.

**Functions**
- `oracle_dispatch_on_queue_insert()` - trigger function on oracle_queue INSERT. Runs the self-audit firewall, then dispatches to the reviewer.
- `oracle_route_verdict()` - trigger function on oracle_verdicts INSERT. Routes pass/fail/blocked to the right place.
- `oracle_audit_sample()` - utility to pull random recent verdicts for spot-checking.

## What this repo is not

This is not a framework or a library. There is no `npm install oracle-gate`. It is a pattern, documented with real SQL from a real system, that you can adapt to your own multi-agent setup. The tables assume Postgres (tested on Supabase). The inter-agent messaging (the `agent_scratchpad` inserts) assumes you have some kind of message bus between your agents. Swap in whatever you use.

## Where this came from

This pattern was built for GABS, a private multi-agent system that manages software builds, QA, deployments, and operational automation for CozyAF LLC. The oracle gate was the single biggest reliability improvement in that system. Before it existed, agents would declare work complete when it wasn't, and the human (me) wouldn't find out until something broke in production.

Related writing: LINK_TO_BLOG_POST_HERE

## License

MIT. Use it, fork it, adapt it. If you build something interesting with the pattern, I'd like to hear about it.
