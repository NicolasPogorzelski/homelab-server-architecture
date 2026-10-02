# Local AI Coding Assistant: Model and Harness for the Admin Workstation

## Status

Decided 2026-10-02. Chosen: `Qwen3.8-27B` on the Bazzite admin desktop (RX 7900 XT, 20 GB,
Vulkan) driven by the OpenCode harness, pointed at the local `llama-server` endpoint. `Qwen3.6-35B`
stays as a faster fallback. `Qwen3-Coder-30B` and `gpt-oss-20b` are rejected. `Devstral-Small-24B`
is an optional second coding model, not a replacement.

This was an evaluation. No platform node and no repository rule changed on the strength of it; the
desktop's model directory, the harness install and a temporary egress jail were set up, measured,
and then removed. The same evaluation on the vm100 fallback GPU (RTX 2070 Super) is the follow-up.

## Context

The goal was to see whether a local model can take over the agent, tutor and reviewer roles this
repository otherwise reaches a hosted model for, under two hard constraints: no prompt or file
content may leave the machine, and correctness is worth more than speed. "Uncensored" matters only
in the narrow sense that a legitimate security question must be answered rather than refused.

The desktop is the primary inference box; the server's GPU is the fallback. Everything below was
measured on the desktop.

## Method

Five models went through one battery, graded blind (each answer saved under a random id, the id to
model map opened only after grading):

- a quality set of short repository tasks (a changelog row, a node-failure question, a command
  explanation, a learning question that the governing rule says to answer with a counter-question);
- a review task on a real, unfixed defect in this repository's `mariadb-restore-test.sh`, graded
  against a ground truth written beforehand;
- two code-fix tasks on a separate project, each checked out at the parent of a historical commit
  with the bug present and the commit's own test hidden, then graded by running that test as an
  oracle;
- a refusal set of five legitimate security questions.

Harnesses (OpenCode, Qwen Code, Claude Code) were compared on one fixed task and model so the
difference measured is the harness, not the model.

Containment was proven, not assumed. Each harness ran a real task inside a transient `systemd`
scope with `IPAddressDeny=any` and `IPAddressAllow=localhost`: an external address timed out while
the local endpoint answered and the agent completed its task. One finding from that: the rootless
`--user` scope does not enforce the address filter at all, so only a system scope is a real jail.

## Models

The one clean objective discriminator was the A1 code-fix oracle. Only one model passed it.

| Model | A1 oracle | Review quality | Refusal (security Q) | Quant | Note |
|---|---|---|---|---|---|
| Qwen3.8-27B | pass (only one) | strong, no false findings | answered | Q3 (handicap) | also the only model to follow the counter-question rule |
| Qwen3.6-35B | fail | weak, several false findings | partial | Q4 | fastest |
| Qwen3-Coder-30B | fail | not run | refused, with a lecture | Q3 | coding-specialised, did not redeem itself |
| Devstral-Small-24B | fail | mediocre | soft refusal | Q4 (fairer) | solid but not more correct |
| gpt-oss-20b | fail, and left a syntax error | noticed the key issue, drew the wrong conclusion | hard refusal | MXFP4 | hallucinated repository facts |

Three points carry the decision:

- 27B passed the one objective code test that the other four failed, and it did so at `Q3`, the
  most aggressive quantisation of the set, forced by the need to fit a 64K context into 20 GB. The
  others failed at their healthier quants, Devstral included at `Q4`.
- The shared failure of the four losers on A1 was the same: they guarded the call sites around the
  broken function rather than the function the test checks. A plausible-looking fix that is wrong
  is worse for a reviewer than an honest gap, because the reader cannot tell the real findings from
  the invented ones.
- gpt-oss was the weakest against the stated constraints: it invented node-level facts in a
  repository question, refused a legitimate security question outright, and on one code task
  produced a file that no longer parsed.

## Harness

| Harness | Install | Local endpoint | Egress proven | A1 on 27B |
|---|---|---|---|---|
| OpenCode | single static binary | JSON config | yes | full fix |
| Qwen Code | Node toolchain | environment variables | yes | partial fix |
| Claude Code | Node plus a translation proxy | needs a router | not tested | not run |

OpenCode is the pick: cleanest to install, proven to leak nothing, and on the one head-to-head it
drove 27B to the complete fix where Qwen Code drove the same model to a partial one. Claude Code
against a local model needs an OpenAI-to-Anthropic proxy whose current version wants interactive
configuration; it was left unresolved rather than forced, and it is the harness the exercise set
out to replace.

## Decision

Use `Qwen3.8-27B` under OpenCode on the desktop for the bulk of agent, tutor and review work, with
no data leaving the machine. Keep `Qwen3.6-35B` for work where speed outweighs correctness. Drop
`Qwen3-Coder-30B` and `gpt-oss-20b`. Keep `Devstral-Small-24B` only if a faster second coding model
is wanted; it is not more correct than 27B.

## Consequences and limits

- The deepest defect in the review task, an ordering bug where a cleanup trap is armed before the
  guard that is supposed to protect against it, was found by none of the five models. Local models
  cover routine review and simple fixes; the hardest diagnosis still needs a frontier model.
- The context window is 64K tokens and the 27B at 20 GB cannot hold more. A full repository audit
  (about 400,000 tokens) does not fit at once and must run agentically, file by file, which is both
  the only way it fits and the higher-quality way to do it.
- 27B generates at roughly 35 tokens per second against the 35B's roughly 100. For interactive
  tutoring this is near reading pace; for long agent chains it is minutes per task. Speed is the
  price of the correctness that decided the choice.

## A note on the test method itself

The A1 oracle was a historical commit's own test file, and its hardest scenario patched a module
internal symbol (`traceback`) that the reference fix happened to import. A correct fix that logged
differently tripped that patch and was reported as a failure until it was re-checked by outcome.
The lesson is this repository's own: grade by outcome, not by the reference implementation's
internals. A historical test reused as an oracle must first be stripped of any monkeypatch of an
implementation-internal symbol.

## Open

- Claude Code against a local model: feasible with a translation proxy, deferred.
- Web search for the models (a news agent, repository retrieval) needs a dedicated node and is a
  separate, fleet-level step.
- The same evaluation on the vm100 fallback GPU (RTX 2070 Super, 8 GB) is the next task.
