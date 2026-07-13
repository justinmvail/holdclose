# Backend ops — changing deployed config without breaking testers

Written after the **2026-07-13 session-wedge incident**, which burned most of a
day. Read the incident first; the rules are only memorable with it attached.

## The incident

1. The live test suite needed to forge session JWTs, so the deployed dev
   `FORUM_JWT_SECRET` was rotated to match the local one. Approved, reasonable,
   and **the trigger for everything below**.
2. Rotating that secret invalidates the SIGNATURE of every session token already
   issued. The tester's phone was holding one.
3. From that moment every authenticated call from the phone — sync, chat, bug
   reports — returned **401**. Nothing surfaced: all care data is local, so the
   app looked completely healthy.
4. The app could not self-heal. Session recovery was gated on the
   `Token-Expired: true` header, which the Worker only sets for a genuinely
   EXPIRED token. A bad *signature* returns a plain 401 → no re-exchange → the
   session was wedged permanently.
5. Diagnosis then went sideways for hours because `wrangler tail` was read for
   its `outcome` field. **`outcome: "ok"` means "the Worker didn't throw", NOT
   "the request succeeded."** A wall of 401s scrolled past looking fine.

Total cost: a day, a wild goose chase through the feedback pipeline, and three
"can you see it yet?" round-trips with the tester.

## Rules

### 1. Treat a deployed-secret change as a BREAKING client change

`FORUM_JWT_SECRET` signs every session token. Rotating it logs out every client
that holds one — but silently, as a permanent 401 rather than a sign-in prompt,
unless the client can recover (it now can — see rule 2).

Before rotating any deployed secret, state out loud what already-issued
artifacts it invalidates, and how existing clients recover. If the answer is
"they don't", the rotation is not ready to run.

### 2. Any 401 must be recoverable, not just `Token-Expired`

`ForumApiClient` and `FeedbackSender` now re-exchange the session and retry once
on **any** 401 (`forum_api_client.dart`, `feedback_service.dart`), so a rotated
secret degrades to one silent re-auth instead of a bricked install. Regression
tests pin this — a plain 401 with no `Token-Expired` header must still recover.
**Do not re-narrow that condition.**

Any NEW client that talks to the Worker with a raw HTTP client (rather than
through `ForumApiClient`) must wire the same recovery. `FeedbackSender` is the
cautionary example: it bypassed the client, so it missed the recovery the rest
of the app had.

### 3. Read STATUS, never `outcome`

Use **`tools/worker_tail.sh`** (status-first, flags every non-2xx). It exists
solely because `outcome: "ok"` is a trap. Never eyeball a raw `wrangler tail`
for request health.

### 4. After changing deployed config, verify a REAL client — not just the suite

The live suites (`npm run test:live`, `tools/live_backend_test.sh`) **forge a
fresh token every run**, so they are structurally blind to "existing clients are
broken". They passed 40+ green while the tester's phone was 401ing on every
call.

So after any deployed secret/var/binding change, additionally:

```bash
tools/worker_tail.sh 120        # then open the app on a real device
```

and confirm the device's requests are **2xx**. A device that has held a session
across the change is the only thing that proves it.

### 5. When a device "can't reach" the backend, check the status codes FIRST

Before theorising about client code, endpoints, or queues: tail with status and
look at what the device's requests actually return. One 401 line would have
ended the incident in five minutes.

## Deploy checklist (deployed secret / var / binding change)

- [ ] Name what the change invalidates for clients already in the field.
- [ ] `npx wrangler deploy --env dev` (+ `wrangler d1 migrations apply … --remote`
      if the schema moved).
- [ ] `cd backend && npm run test:live` — the Worker's own contract.
- [ ] `tools/live_backend_test.sh` — the APP's client code against it.
- [ ] `tools/worker_tail.sh 120`, open the app on a device that was already
      signed in, confirm **2xx** — the step the suites cannot do for you.
