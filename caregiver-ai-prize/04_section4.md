# Section 4 — Alignment with the Caregiver AI Principles

> Maps 1:1 to ACL's seven official principles (exact order + wording). Each →
> a concrete Holdclose feature, not an aspiration. `[BRACKETS]` = verify.

Holdclose was designed around ACL's seven Caregiver AI Principles. Each is met by
a real, shipped feature:

**1. Protect privacy, dignity, and choice.** Care data is **local-first** —
stored on the caregiver's device by default. Sharing is opt-in via single-use,
explicitly confirmed invites. **Data portability** is inherent (the caregiver
owns and can export their record); we do **not** sell caregiver or care-recipient
data; consent is explicit and revocable. The app refers to the care recipient as
"your loved one," never "the patient" — dignity by design. All network traffic is
encrypted **in transit (TLS)**; on-device care data is protected by the phone's
**OS device encryption**, with OS cloud backups disabled so the local record is
not swept into iCloud or Google Drive (Android `allowBackup=false`; iOS files
excluded from backup). Server-synced care-circle data resides on Cloudflare D1
and R2.

**2. Support human-in-the-loop accountability.** Holdclose **augments, never
replaces, the caregiver's judgment.** Every AI action that changes existing care
data — in chat *or* voice — routes through an explicit **confirmation card**
before it applies; the coach's guidance is **grounded in and cites the loved
one's own data**, so the caregiver sees the reasoning; and when the model is
uncertain or the data is thin, it **flags that weak-data result and escalates to
professional help** rather than asserting. The scan-to-import extractors likewise
flag low-confidence fields for the caregiver to check, and a code-side (non-LLM)
crisis watchdog on chat and voice catches concerning messages even if the model
fails.

**3. Support caregivers' well-being and reduce burden.** This is Holdclose's
purpose — **the assistant that makes a relentless, full-time job easier.**
Hands-free voice logging removes friction when hands are full; the coach reduces
the "I don't know what to do" stress of the hard moments; tracking and the
Emergency Card cut cognitive load and crisis risk — assisting with the work *and*
the emotional weight.

**4. Supplement, not replace, human connection.** The **Care Circle** spreads
caregiving across the family instead of isolating one person, and the caregiver
**community** connects people who are otherwise alone. The AI is a tool; the
humans do the caring — Holdclose strengthens the caregiver↔loved-one and
caregiver↔family relationships rather than substituting for them.

**5. Allow personalized and flexible care.** Guidance is **grounded in the
specific loved one's situation** (their meds, history, journal), and Holdclose
works for **any** care situation — aging parents, disability, recovery, dementia
— customizable to individual needs, preferences, and lifestyle, not a single
diagnosis or a one-size template.

**6. Promote safety, reliability, and transparency.** The coach's behavior is
**transparent** (educational, not diagnostic; grounded and cited; uncertainty
flagged) and **designed to avoid bias**: a code-side (non-LLM) **crisis-keyword
watchdog** on chat, voice, and the community routes concerning content to human
help even if the model fails, human-in-the-loop confirmation gates every care-data
change, and the **model-agnostic** architecture lets us replace a model that
underperforms for any caregiver group. We will **red-team** coach outputs against
unsafe-advice scenarios and publish the results as Data Output Logs — reflecting
current evidence and best practices, with safeguards against adverse impacts.

**7. Ensure affordability and access.** Holdclose is designed to be **affordable**
[FOUNDER: state the pricing commitment — e.g. "a free core tier plus an optional
low-cost subscription; transparent, reasonable pricing"], runs on the phone
caregivers already carry, and its **local-first** design works even with limited
connectivity — meeting caregivers where they are, which is the heart of ACL's
home- and community-based mission.
