# Google Play Console content — Holdclose

Draft to paste into Play Console, grounded in the actual app (permissions,
backend tables, privacy policy at junocode.studio/holdclose/privacy.html).
Everything here is accurate as of build 0.1.0+51. **Where a field is a judgment
call, it's flagged ⚠.**

Publisher: **JCSV One LLC, dba Juno Code Studio** · Package: `com.holdclose.holdclose`
Support email: **jcsvonellc@gmail.com** · Privacy policy:
**https://junocode.studio/holdclose/privacy.html**

---

## 1. Store listing

**App name** (≤30 chars)
```
Holdclose: Caregiver Coach
```
(26 chars. Alternative if you want the name alone: `Holdclose`.)

**Short description** (≤80 chars)
```
An AI coach that knows your loved one — meds, appointments, and a care circle.
```
(78 chars.)

**Full description** (≤4000 chars)
```
Caring for someone is a hundred small things at once — the medications and
their timing, the appointments, the questions you meant to ask the doctor, the
details only you seem to hold. Holdclose keeps them in one place, and gives you
a coach that actually knows your person's situation.

Unlike a blank chat box, Holdclose's coach is grounded in the real details you
keep — medications and dose windows, appointments, your health log, your notes.
Ask it how to handle a hard moment, what to raise at the next visit, or simply
what's coming up today, and it answers from your loved one's actual care, not
generic advice.

WHAT'S INSIDE
• A coach that knows your loved one — grounded in the meds, appointments, and
  history you keep, so its help fits your situation.
• Medications & dose windows — track what they take and when, with refill
  runway alerts before a prescription runs out.
• Appointments — keep the schedule, and get AI-suggested questions to bring to
  each visit.
• A shared Care Circle — invite family, so everyone sees the same plan.
• Scan to import — snap a prescription label, appointment card, or insurance
  card and let the app read the details for you to confirm.
• Health log, journal, and an emergency/handoff card — the essentials in one
  place, ready when someone else needs to step in.
• Find a provider, a shareable care-summary PDF, and tap-to-call for pharmacy,
  provider, and insurance.
• A community of caregivers — a place to ask, share, and not feel alone.

Holdclose is general-purpose caregiving — for anyone caring for someone who
needs it: an aging parent, a disabled family member, recovery after surgery,
dementia. Whatever your situation, it meets you there.

YOUR DATA, YOUR CONTROL
You decide what to enter. We don't sell your data or use it for advertising.
You can delete your account and everything in it anytime from Settings.

Holdclose is a wellbeing tool for caregivers — not a medical service, and not a
substitute for professional care. It never gives medication dosing advice,
diagnoses, or a prognosis; it helps you, the caregiver, stay organized and
supported.
```

**Category:** Medical
⚠ Alternatively "Health & Fitness." "Medical" fits a care-coordination tool
better and is what the copy implies; either is defensible.

**Tags** (pick up to 5 in console): Caregiving, Medical records, Health,
Medication reminder, Family organizer.

**Contact details:** email jcsvonellc@gmail.com · website
https://junocode.studio/holdclose · (phone optional).

---

## 2. Graphics you still need to PRODUCE (not draftable as text)

These are hard requirements before you can publish — gather them:
- **App icon**: 512×512 PNG (you have the launcher icon; export at this size).
- **Feature graphic**: 1024×500 PNG/JPG (the banner atop the listing).
- **Phone screenshots**: 2–8, min 1080px on the short side. Suggested set:
  1) the chat coach answering a real question, 2) medications + dose windows,
  3) an appointment with suggested visit questions, 4) scan-to-import review,
  5) the Care Circle. Capture on a real device (they must show the actual UI).
- (Optional) 7-inch and 10-inch tablet screenshots if you list tablet support.

---

## 3. Data safety form

Play requires this and checks it against behavior — keep it accurate.

**Does your app collect or share any of the required user data types?** → **Yes**

**Is all of the user data encrypted in transit?** → **Yes** (all traffic is
HTTPS/TLS to the Cloudflare backend).

**Do you provide a way for users to request that their data be deleted?** →
**Yes** — in-app: Settings → Delete account (cascades and removes their data
server-side), and by emailing jcsvonellc@gmail.com. (Provide the deletion URL/
instructions: the in-app path + the support email.)

### Data types — declare COLLECTED, processed on our servers, not sold

For every type below: **Collected = Yes**, **Shared = No** (see the sharing note),
**Processing = stored** (not ephemeral), **Purpose = App functionality** (plus
Account management where noted). Mark **Optional** unless noted.

| Play data type | Collected | Why / detail |
|---|---|---|
| Personal info → **Name** | Yes | From Google Sign-In, if the user allows it. Also Account management. |
| Personal info → **Email address** | Yes | From Google Sign-In. Also Account management. |
| Personal info → **User IDs** | Yes | The Google account identifier that keys the account. Account management + App functionality. **Required.** |
| Health & fitness → **Health info** | Yes | The care data the user chooses to enter: medications, conditions/diagnoses, health log, emergency card, journal. The core of the app. |
| Photos & videos → **Photos** | Yes | Prescription/appointment/insurance-card scans and journal photos. Read by the AI extractor, then stored. |
| Audio → **Voice or sound recordings** | Yes | Journal voice notes (stored). Voice dictation is transcribed via the device's speech recognizer. |
| Messages → **Other in-app messages** | Yes | Coach chat and community forum posts/comments. Chat text is processed by the AI coach. |
| App activity → **Other user-generated content** | Yes | Forum posts/comments, journal, notes. |
| App info & performance → **Crash logs** / **Diagnostics** | Yes (optional) | ONLY when the user taps "Report a problem" — never automatic. No third-party analytics or crash SDK is active in this build. |

**Not collected (be sure these stay OFF in the form):** Location, Financial info
(no payment data is handled by the app; Play Billing handles purchases if/when
enabled), Contacts, Calendar, Browsing history, Ads/marketing data. No data is
used for advertising, and there is **no** third-party analytics.

### The sharing note ⚠ (read before answering "Shared")

Play distinguishes **collected** (you handle it) from **shared** (you transfer
it to a third party for *their* use). Holdclose's backend runs on **Cloudflare**
(Worker, database, storage, and the AI coach/scan model all on Cloudflare's
network), and sign-in uses **Google**. These are **service providers /
processors acting on our behalf under contract**, which Play does NOT count as
"sharing." So answer **Shared = No** for every type, and rely on:
- Cloudflare as a data processor (their DPA), and
- Google Sign-In as an auth provider.

Only change this to "Shared = Yes" if you later add a third party that uses the
data for its own purposes (an ad network, an analytics vendor, etc.). You have
none today.

---

## 4. Content rating (IARC questionnaire)

Answer the questionnaire truthfully; IARC computes the rating. Key answers:
- **Category:** Reference, News, or Educational → **Utility / Productivity /
  Communication** (a caregiving tool). If "Medical" is offered, use it.
- Violence, sexual content, profanity (by the app), gambling, controlled
  substances: **None.** (The app helps track prescribed medications — that is
  medical reference, not "references to illegal drugs." Answer No to
  drug/alcohol/tobacco references.)
- **Does the app let users interact / communicate / share content?** → **Yes.**
  There is a community forum (post, comment, vote) and a shared Care Circle.
  Declare user-to-user communication and user-generated content.
- **Does it share the user's location with other users?** → **No.**
- **Is user-generated content moderated?** → describe your moderation: the app
  has in-app reporting of posts/comments (the `reports` flow) and community
  guidelines. ⚠ Be ready to state how reports are actioned.

Expected outcome: **Teen** (or Everyone), driven by the social/UGC features and
health content. Let IARC assign it.

---

## 5. Target audience & content

- **Target age group:** **18 and over.** Holdclose is for adult caregivers; it
  is not designed for or directed to children. Selecting 18+ keeps you out of
  the Families policy program (which you do not want here).
- **Appeal to children:** No.
- **Ads:** The app contains **no ads**. Declare "No, my app does not contain
  ads."

---

## 6. App access (CRITICAL — do not skip) ⚠

Every screen is behind Google Sign-In, so a Play reviewer **cannot get past the
sign-in screen** without help. In **App content → App access**, choose "All or
some functionality is restricted" and provide ONE of:
- **A test Google account** (email + password) the reviewer can sign in with,
  with any needed steps; OR
- **Instructions + a demo path**, if you ship one.

Without this, review will bounce. This is the most common cause of a first-
submission rejection for a login-gated app. Decide which test account you'll
hand the reviewers before you submit.

Related: the sign-in only works if the **Play app-signing SHA-1** is registered
on the Android OAuth client (Play re-signs your bundle with its own key). Get
that SHA-1 from Play Console → App integrity → App signing AFTER your first
upload, and add it as a third Android OAuth client — otherwise the reviewer's
sign-in fails even with valid credentials.

---

## 7. Other declarations

- **Government app:** No.
- **Financial features:** No (no lending, no payments handled by the app itself;
  a subscription via Play Billing may come later and is declared then).
- **Health apps:** If Play surfaces a Health Apps declaration for the Medical
  category, declare: personal wellbeing/care-organization tool; **not** a
  medical device; does **not** provide diagnosis, dosing, or treatment; not a
  HIPAA covered entity (matches the privacy policy's medical disclaimer).
- **Data deletion URL** (Play now asks for one): use the in-app path (Settings →
  Delete account) plus jcsvonellc@gmail.com, or add a short
  junocode.studio/holdclose/delete page if you want a public URL.

---

## 8. Release track

Start on **Internal testing** (up to 100 testers by email/list, no review wait)
to shake out the Android-on-device issues before a public review. Upload the AAB
from `tools/build_aab.sh`. Promote to Closed → Open/Production once it's solid
and the store listing + Data Safety + content rating above are all complete.
