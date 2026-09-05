# The Agents Kit — the full post-mortem

Five failures that a production autonomous agent hid behind green logs, in full: what the
symptom looked like, what was actually wrong underneath, how each one was finally found, and
the code that stops it happening again.

The code in this kit is free and MIT-licensed — `pip install agents-kit`. This document is the
part that is not reproducible: the specific diagnoses, the numbers they were found by, and the
method that found them. Every incident below cost weeks before it was understood.

Licence: see LICENSE-POSTMORTEM.txt. Read it, apply it, quote it with attribution — just don't
resell it.

---

## 1. The money rail that had never once fired

**Symptom:** a live product, a working checkout, a correct webhook handler, and $0 recorded.

Four independent breaks, each individually silent, stacked:

- The webhook was registered against **the wrong service** — a sibling backend that did not
  own fulfilment. `last_sent_at: null`. It had never fired in its life.
- It was registered in **test mode**, so a real purchase would fire nothing at all.
- The signing secret was **empty** in the app's vault. `verify()` returned False for every
  call, so even correctly-routed webhooks 401'd. The secret existed — in a `.env` file forty
  feet away, under a different key name.
- Retries were **not deduplicated**, so anything that did get through would double-count.

Any monitoring you would plausibly have — endpoint uptime, error rate, latency — was green
throughout. The endpoint was *up*. Nothing ever asked it to do anything.

**The fix is an order of operations**, in `kit/webhook_rail.py`:

```
verify -> parse -> dedupe -> record -> fulfil
```

Fulfilment runs **last**, and its failure does not roll back the recording:

> A sale you recorded but failed to deliver is a support ticket.
> A sale you delivered but failed to record is a hole in your books that nothing will surface.

Three rules inside `verify()` that are each easy to get wrong:

- Verify the **raw bytes**, never a re-serialised dict. `json.loads` then `json.dumps`
  reorders keys and changes whitespace; the signature will never match again.
- An **empty secret returns False**. It must never mean "skip the check" — an internet-facing
  revenue route that mints on an unverified call is a free-money endpoint for whoever finds it.
- Compare with `hmac.compare_digest`, not `==`, so you do not leak the expected digest
  one byte at a time.

**Test-mode money must never be income.** `Event.live` is the most important field on the
struct. Processor test orders, sandbox checkouts and your own smoke tests have to land in a
separate ledger. Mine did not, once: a hand-fired test webhook put **$98.99** into the
briefings, the P&L and the fitness function that decided what to build next. The system spent
weeks optimising toward a number that was a rehearsal.

**How to verify yours actually works — do this today:**

```bash
# 1. bad signature must be rejected
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://your-host/webhook/provider \
  -H "X-Signature: deadbeef" --data-binary @payload.json     # expect 401

# 2. good signature must record exactly one row
#    (compute the HMAC over the exact bytes you send)
```

Then check your processor's webhook list for `last_sent_at`. If it is null, your rail has
never run, regardless of how good the handler code is.

> **Trap I lost an hour to:** if your endpoint is behind Cloudflare, it may return **403 error
> 1010** to `Python-urllib` while accepting browsers and your processor perfectly well. Test
> with a realistic `User-Agent` or you will debug a rail that was fine.

---

## 2. The gate that fails closed and deadlocks everything

This one cost the most, and it is four lines of code.

A quality gate scored products with an LLM panel before allowing a launch:

```python
try:
    verdict = llm.judge(persona, job, deliverable)
    return {"success": verdict["success"], "reuse": verdict["reuse"]}
except Exception:
    return {"success": False, "reuse": False}      # <-- here
```

That `except` conflates two entirely different facts: **"the user said no"** and **"I could
not ask the user."**

When the free LLM pool started returning 429s, every judgement became a rejection. The score
pinned to `0.0`, the threshold was `0.5`, and the gate blocked every launch. Permanently.
The tally when I found it: **47 blocked, 3 passed**, every recent one reading
`score=0.0 basis=dogfood_proxy thr=0.5`.

And it was self-sealing. The gate fell back to a live-retention signal once enough real users
existed — but no launch meant no page, no page meant no traffic, no traffic meant no users, so
it fell back to the broken proxy forever:

```
no launch -> no page -> no traffic -> no retention data -> proxy -> no launch
```

Nothing in the logs said "your gate is stuck." Every line said `status=ok`.

**The rule: a gate may only block on evidence.** Absence of evidence is `UNKNOWN`, and
`UNKNOWN` passes through loudly. `kit/gates.py` has three verdicts, not two:

| Verdict | Meaning | Allowed? |
|---|---|---|
| `PASS` | measured, good enough | yes |
| `BLOCK` | measured, not good enough | **no** |
| `UNKNOWN` | could not measure | **yes**, and it says so |

The distinction lives in `Judgement.error`, and `evaluate()` scores only judgements that
actually happened. Five judges that all time out gives you `UNKNOWN`, not `0.0`.

`enabled=False` gives you measure-only mode. **Run every new gate that way for a week**
before letting it block. You want to know what it *would* have done while it cannot hurt you.

The punchline: once I fixed the fail-closed bug and the gate could measure properly again, it
returned `0.30 < 0.50` and blocked anyway — correctly. The product really was bad. The gate
had been the most honest component in the system the entire time; it just could not tell me
so through a bug that made every answer identical.

---

## 3. The loop that ran for three weeks and produced nothing

The single hardest failure to see, because every signal you normally watch says "fine."

A discovery loop logged this on every tick for three weeks:

```
discovery scan ok :: candidates=17 recorded=0
```

Status `ok`. No exception, no error rate, uptime 100%, dashboards green. It evaluated the
same 17 candidates and recorded none of them, every time, forever. It also **won its
scheduling slot 81 times out of 81** — the most reliably-scheduled component in the system,
and the least productive.

It had company:

| Loop | Logged, every tick, for | Actual output |
|---|---|---|
| `perception` | 7 days | `new=0` |
| `falsification` | its entire life | `refuted=0` — beliefs only ever died of old age |
| `capability_mining` | 81/81 ticks | re-upserted the same 7 rows |
| `postmortem` | every tick | replayed the same 2 failures, `lessons=0` |

Note `capability_mining`: `found=7 stored=7` looks like the healthiest line in the log. It is
an idempotent upsert of identical rows. **Zero new information per tick, reported as success.**

**Health checks answer "did it run?" Almost nothing answers "did running it change
anything?"** For an autonomous system those are completely different questions, and only the
second one matters — a step that changes nothing is indistinguishable from a step that never
ran, except that it also burns your budget.

`kit/staleness.py` tracks the **output delta** and alarms on a zero-streak:

```python
monitor = StalenessMonitor(patience=5)

if monitor.record("discovery", produced=len(newly_recorded)):
    alert("discovery has produced nothing for 5 consecutive ticks")
```

`produced` must count **new** output. An idempotent upsert of the same rows produces `0`,
not `7`. Getting that one line wrong is exactly how `found=7 stored=7` read as healthy for a
month.

Wire `monitor.report()` into whatever you read daily. Worst-first, so the dead things are at
the top where you cannot miss them.

---

## 4. The tunable that was secretly an off-switch

An agent with more to do than budget needs an arbiter. Mine scored bids as

```
score = (0.4*value + 0.4*info + 0.2*urgency) / cost
```

and spent greedily under a per-tick budget. Perfectly reasonable. It also silently disabled a
third of the system for months.

The arithmetic: **13 registered bids cost 6.5 units in total. The budget was 3.0.** Because
greedy-by-ratio buys cheap work first, the three most expensive bids — the deep reasoning,
the self-simulation, the dreaming, which is to say *the entire reason the system was
interesting* — won **0 of 81** consecutive arbitrations.

Not "rarely". Never. Their feature flags were all `1`. The modules imported fine, passed
their tests, and had been dead for months. A single number that nobody thought of as a switch
had switched them off.

`kit/attention.py` adds the two things that would have caught it in a day:

```python
arbiter.starving()   # bids that have competed but NEVER won
arbiter.feasible(bids)
# {'budget': 3.0, 'total_cost': 6.5, 'coverage': 0.46, 'never_affordable': ['deep_reasoning']}
```

Run `feasible()` at startup and log it. If `never_affordable` is non-empty, you have a module
that can never run — **raise the budget or delete the bid, but do not leave it registered and
dead.** A registered-but-impossible bid is worse than a deleted one, because it makes the
system look more capable than it is, to you.

Urgency also rises the longer a bid goes unchosen, so an expensive bid eventually outbids
cheap ones instead of losing on ratio forever.

---

## 5. Delivering the sales page to the person who just bought it

Three ways I have actually failed a paying customer:

1. **Delivered nothing.** Revenue recorded, no delivery step existed. The buyer paid and got
   silence. Nothing knew anything was wrong, because the sale itself looked perfect.
2. **Delivered twice.** The processor retried and the buyer got two emails. Harmless for a
   PDF; not harmless for a licence key or a credit top-up.
3. **Delivered a link back to the sales page they had just bought from.**

The third is my favourite, because it passed every test that existed. The code collected
"the venture's best URL" — and the venture's best URL was its own landing page. The success
condition was *a link was produced*. A link was produced. To the buyer it reads exactly like
being scammed.

Its cousin: a publisher that fell back to a local "dry" mode when its API returned an error,
logged that at `INFO`, and returned a `file:///C:/Users/...` URL that was then stored as the
product link. Delivery is downstream of every silent failure in your publishing path, so it
is where you find out — if you look.

`kit/delivery.py` encodes three rules:

- **Idempotent per order.** A retry is a no-op. Mark delivered only *after* a confirmed send,
  so a failure retries instead of being sealed as done.
- **A deliverable must be verified to be a deliverable**, not merely to exist.
  `usable_links()` rejects the sales page (and its `/` vs `/index.html` twin), `file://`, and
  localhost.
- **Never fail silently.** No usable link means `PENDING` plus an alert — not "send the
  least-bad link". An honest pending beats a delivery the buyer reads as a scam, and unlike
  the scam, somebody finds out about it.

---

## The pattern behind all five

Every one is the same shape: **a component that reports success as a side effect of running,
rather than as a consequence of producing something.**

- The webhook endpoint was *up* — it had never been called.
- The gate *returned a verdict* — the verdict was an error in disguise.
- The discovery loop *completed* — it recorded nothing.
- The arbiter *ran* — a third of its bids could never win.
- Delivery *produced a link* — the link was the sales page.

So the check that would have caught all five is the same check:

> **Does this component's output change? If it stopped working, what number would move?**

If you cannot answer the second question for a component, you cannot tell whether it works —
and in an autonomous system, one you cannot tell about is one that is probably already broken.
Instrument the delta, not the heartbeat.

---

*Written from a production post-mortem, not from theory. All 29 tests pass; the incidents were
real; the numbers are the real ones.*
