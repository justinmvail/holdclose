# Holdclose — UI/UX Review (Synthesis)

*Audience: family caregivers, 45–65, often non-technical, frequently stressed and interrupted. Evaluation lens: ACL Caregiver-AI Prize §3 — usability, forgiveness, transparency, human-in-the-loop, tested in realistic conditions. Findings below merge 77 raw observations from 8 reviewers, deduplicated and re-ranked by impact.*

---

## Executive summary

Holdclose has a **genuinely strong usability core** and a handful of **sharp, concrete edges** that undercut it. The chat coach is best-in-class on failure/interruption recovery, the scan→review→approve flow is a textbook human-in-the-loop pattern, empty states are instructive rather than dead-ends, and the primary navigation (four-tab bar + PathHeader breadcrumbs + large hub tiles) is calm and predictable. That foundation is real and should be showcased in the competition packet.

The problems cluster into four fixable groups:

1. **A documented WCAG-AA contrast failure that is systemic.** The theme ships two salmon tokens — `cta` (#C97458, 3.43:1, decorative) and `ctaFilled` (#B05C40, 4.72:1, AA-safe) — but nearly every filled primary button in the app (Send, Save, Confirm, Search, crisis-call, the center voice mic) uses the *failing* one. The medication screens were already migrated to `ctaFilled`; everything else was left behind. This is a one-token-per-site change and a citable, reproducible deduction. Verified in code.
2. **Rebrand leftovers that make the app read as "not for me" or send caregivers to places that don't exist.** The community guidelines still say "This board is for dementia caregiving questions" and point crisis-seekers to a "Crisis tab (the bell on the right)" that does not exist (the only bell is an admin-only moderation shield). Chat empty-states still speak in decoder-era "a behavior you haven't seen before / a phrase that keeps coming up" language. Settings still says "Read scripts aloud." The Emergency Card labels the person "Patient." All verified in code.
3. **Two dead-code / discoverability gaps on the highest-frequency and highest-stakes surfaces.** The documented Home quick-add FAB (`AddActionFab`) is fully built and golden-tested but **mounted on no screen** (verified: only self-references in `add_action_sheet.dart`), so once a caregiver has any schedule events the Home dashboard has zero labeled add affordance — only the ambiguous center mic. The Emergency Card is buried as tile #9 in the Care hub with no shortcut, and the entire Care Circle feature is hidden behind an off-by-default Settings toggle.
4. **A real forgiveness gap in the forms.** Local DB saves have no try/catch/finally, so a failed write (the team's own memory notes a recurring "database is locked" bug) spins the Save button forever and strands the caregiver's data with zero recovery — while the chat screen already proves the correct `finally` + retry pattern.

Fixing groups 1–3 is mostly copy and token swaps: low-effort, high-visibility, directly aimed at the ACL §3 rubric. Group 4 is a small but important robustness fix. Details and the top-10 execution list follow.

---

## Onboarding & first-run

**[HIGH] Sign-in offers no privacy reassurance at the moment trust matters most.**
*Screen: `sign_in_screen.dart` (body ~176-247); copy in `app_en.arb`.*
The sign-in screen is just the wordmark, the same tagline the carousel showed, two OAuth buttons, and a legalese consent line. A stressed caregiver is about to hand over their identity *and* then enter their loved one's name, age, diagnosis, and allergies (real PHI) — with nothing telling them why Google is needed, what happens to their account, or that the health data stays private. **Fix:** add one or two plain-language reassurance lines near the buttons — e.g. "Signing in keeps your notes safe and in sync across your devices. We never post anything or share your loved one's information." Keep the vendor invisible per the brand rule, but explain the *purpose* of sign-in. Cheap copy that lifts the conversion-critical first-trust moment. *(ACL §3: transparency / appropriate trust.)*

**[HIGH] "Skip" is a one-way trap out of the value proposition.**
*Screens: `welcome_carousel.dart` Skip (83-92) → `sign_in_screen.dart:166` (`automaticallyImplyLeading:false`); router redirect (852-854).*
Skip calls `onboardingCompletedProvider.complete()` and routes to sign-in, which has no back arrow. Because onboarding is now marked complete, the redirect never returns the user to the carousel — so a reflexive "Skip" in the first two seconds permanently deletes the *only* explanation of what Holdclose is. They land on a bare sign-in with zero context. **Fix (pick one):** don't mark onboarding complete on Skip (only on "Get started"/after sign-in), *or* add a back arrow / "What is Holdclose?" affordance on sign-in. The value prop must never be reachable exactly once. *(ACL §3: prevents user error, supports human judgment.)*

**[MEDIUM] "Sign-in isn't available in this build" is a true dead end with no recovery.**
*Screen: `sign_in_screen.dart:211-223` (`alphaUnavailableKey`).*
When alpha mode is on but no Google client id was baked in, the screen shows one calm sentence and nothing else — no retry, no contact, no next step (the code comment even calls it intentional). For a tester or judge who hits it, the app is bricked. **Fix:** add a "Try again"/reload affordance or a support/contact line. A calm dead end is still a dead end. *(ACL §3: prevents user error, tested in realistic conditions.)*

**[MEDIUM] Welcome carousel page 1 is near-empty and doesn't say what the app does.**
*Screen: `welcome_carousel.dart:32-36`; golden confirms vast dead margins.*
Page 1 is the "Hc" mark, "Holdclose", and one 12-word sentiment line that names no capability. Pages 2–3 carry the real value (pocket coach, journal), but a user who reads only screen 1 (or skips after it) sees a pleasant but empty promise, and the huge vertical whitespace reads as unfinished. **Fix:** add a concrete subtitle — e.g. "A calm place for medications, appointments, and a coach that actually knows your person." — and tighten the vertical rhythm. *(ACL §3: the opening screen is the value-prop test.)*

**[LOW] No cross-step progress indication in the 3-step flow.**
*Screens: carousel → sign-in → loved-one setup.* Sign-in and setup show no "Step 2 of 3" / "Last step" cue, so a tired caregiver doesn't know the finish line is near. **Fix:** add a lightweight "Almost done / Last step" cue or a 3-dot indicator across sign-in + setup. *(ACL §3: reduces onboarding anxiety.)*

**[LOW] Google button uses a hand-rolled gray "G" instead of the recognizable mark.**
*Screen: `sign_in_screen.dart:368-394`.* At the most trust-sensitive tap, a dim custom glyph reads as less legitimate — the opposite of what this screen needs (the Apple button uses the real glyph, so the contrast is visible). **Fix:** use Google's official "Sign in with Google" asset (their guidelines *permit* it for exactly this), which is more recognizable and removes the brand-rules worry the comment cites. *(ACL §3: transparency / satisfying.)*

**[LOW] Carousel feature emojis are read aloud as decorative noise.**
*Screen: `welcome_carousel.dart:203-218`.* Pages 2–3 render a bare emoji with no `ExcludeSemantics`, so VoiceOver/TalkBack announces "pill" / "speech balloon" before the real title/body. **Fix:** wrap the decorative glyph in `ExcludeSemantics`. *(ACL §3: accessibility on the first impression.)*

**[LOW] DOB placeholder "Not set" reads as a system slot, not an invitation.**
*Copy: `app_en.arb` (`lovedOneSetupDobNotSet`).* Minor tone mismatch against the otherwise-warm "optional" framing. **Fix:** "Tap to add" or "Optional."

---

## Navigation & wayfinding

**[HIGH] Home has no persistent "Add" button — the quick-add FAB is dead code. (Verified.)**
*Screens: `home_screen.dart` (Scaffold has no `floatingActionButton`); `add_action_sheet.dart:73` `AddActionFab` — grep confirms it is referenced only inside its own file.*
The well-built Journal / Med-dose / Appointment / Quick-note FAB exists and is golden-tested, and the `HomeScreen` docstring *claims* it sits in the scaffold's FAB slot — but it is mounted nowhere. Once the caregiver has any schedule events (so the empty-state CTAs vanish), Home offers **zero tap-to-add**; the only path is the ambiguous center mic or a three-tap dig into Care → Medications → +. Logging a dose is the single most frequent caregiver action and it has no home on the landing screen. **Fix:** mount `AddActionFab` in `HomeScreen.floatingActionButton` (it was designed for exactly this slot). A labeled "+" is the expected mobile pattern and a reliable non-voice path. *(ACL §3: efficiency — the most frequent task lacks a direct affordance.)*

**[HIGH] Emergency Card is buried as tile #9 with no Home or global shortcut.**
*Screens: `medical_hub_screen.dart:96-102` (9th of ~11 tiles); reachable otherwise only via the `/crisis` deep-link redirect.*
The one screen a caregiver needs instantly under stress (handing a phone to a paramedic) sits below the fold in a flat grid, visually identical to "Care summary" and "Routines." In an actual emergency: tap Care, scroll past 8 tiles, find the shield. **Fix:** promote it to the top row of the Care hub with a visually distinct treatment, and/or add a small persistent pill on Home. One deliberate tap from rest, not a scroll-hunt. *(ACL §3: tested in realistic conditions — the archetypal high-stress moment.)*

**[HIGH] Inviting family requires discovering a hidden Settings toggle.**
*Screens: `medical_hub_screen.dart:110` (Care Circle tile renders only when `teamCoordinationEnabled`); `settings_screen.dart:828-840` (toggle, off by default).*
Care coordination — invite family, share the calendar, hand off tasks — is a headline value prop, but the entire Care Circle entry point is invisible until the caregiver finds Settings → Care Circle and flips a switch. Someone thinking "I want my sister to help with Mom's meds" has no discoverable path. The nice "Coordinate care" empty-state CTA only appears if you already deep-linked into the hidden hub. **Fix:** always show the Care Circle tile; on first tap, present the existing "Caring with others?" onboarding CTA (which already flips the toggle in-place) instead of hiding the door. *(ACL §3: transparency/discoverability of a core feature.)*

**[MEDIUM] Care Circle and Medications go three levels deep — violates the app's own "max 2 levels" rule.**
*Screens: Care hub → Care Circle tile → 5-tile sub-grid (Tasks/Shifts/People/Activity/Expenses); Care → Medications → Windows.*
CLAUDE.md and the PathHeader spec both say max two levels below a tab, with deeper structure using in-page tabs. But Care Circle is a tile grid (L2) opening *another* tile grid (L3) — a grid-within-a-grid. A caregiver on three hours' sleep must remember Care › Care Circle › Tasks. **Fix:** collapse the Care Circle sub-hub into an in-page segmented control (Tasks | Shifts | People | Activity | Expenses) on one screen — the way Community already does sub-nav. Same treatment for Medications → Windows. *(ACL §3: wayfinding cost for a hurried audience.)*

**[MEDIUM] Care hub is a flat 10–11 tile scroll with no grouping — everything reads as equal weight.**
*Screen: `medical_hub_screen.dart:35-118`, one ungrouped `HubGrid`.*
Scan, Find a provider, Care summary, Medications, Schedule, Appointments, Health Log, Routines, Emergency Card, Journal, Care Circle all render identically. An everyday action (Medications) has the same prominence as a rare one (Insurance appeal) and a life-safety one (Emergency Card). A hurried caregiver scans all 11 every time. **Fix:** add 2–3 section headers ("Every day" / "Documents & providers" / "In an emergency") or promote the 3–4 daily tiles above a fold. Cuts visual search from 11 to ~4 at near-zero cost. *(ACL §3: efficiency.)*

**[MEDIUM] Center mic is the primary quick-action but is an unlabeled, undiscoverable icon.**
*Screen: `tab_scaffold.dart:282-446`.* The raised salmon mic can navigate, log a dose, add an appointment, *or* open chat (the coach decides) — but it's a bare glyph with only a semantics string, while all four tabs have words. A novice reads it as "record audio," not "the fastest way to log a dose." Its data-writing power is invisible from the resting UI. **Fix:** add a small persistent word label ("Speak" or "Ask") so it reads as a first-class action, plus a one-time coach-mark on first launch ("Tap and say what you need — log a dose, add a visit, or ask a question"). *(ACL §3: the most powerful, data-mutating affordance is the least self-explanatory.)*

**[MEDIUM] "Schedule" and "Appointments" are adjacent, overlapping tiles — and "Schedule" jumps into the Care Circle subtree.**
*Screen: `medical_hub_screen.dart:68-81`.* Sub-labels overlap ("this week" vs "calendar & visits"), and "Schedule" routes to `/team/calendar` — the shared Care Circle calendar — silently dropping the caregiver into the team subtree (papered over with a `?from=medical` breadcrumb). Two mental models fused onto one grid. **Fix:** merge into one destination ("Calendar & appointments") or make the labels explicit ("Upcoming visits" vs "Full calendar"); don't route a Care tile into `/team/*` without the caregiver knowing. *(ACL §3: prevents wrong-tap trial-and-error.)*

**[MEDIUM] "Care Circle" names both the hub and a child screen — breadcrumb reads "Care Circle › Care Circle."**
*Screens: `care_team_hub_screen.dart:103` (hub title) → "People" tile → `care_circle_screen.dart:116-120` (roster *also* titled "Care Circle").* The label tapped ("People") doesn't even match the title landed on ("Care Circle"), and the duplicate breaks the user's sense of where they are. **Fix:** rename the roster screen to "People"; keep "Care Circle" for the hub only. *(ACL §3: transparency / mental map.)*

**[MEDIUM] Care Circle connect strip is five equally-weighted jargon chips with no primary path.**
*Screen: `care_circle_screen.dart:150-190`.* The populated roster opens with five same-weight pills — "Set your username," "Show my invite code," "Scan a code to add," "Invite by link," "Add by username" — three jargon-forward, none primary. The *empty* state does this right (one clear "Invite someone"); the populated state loses that clarity exactly when a second person is being added. **Fix:** promote one filled "Invite someone" that opens a small chooser (share link / QR / by username); demote the rest to overflow. *(ACL §3: choice overload on the core sharing task.)*

**[LOW] Same action, two names: "Show my invite code" chip → "Show my QR" screen.**
*`care_circle_screen.dart:164` → `circle_qr_screen.dart:149`.* A hesitant caregiver wonders if they tapped the wrong thing. **Fix:** align both on "invite code" (friendlier than "QR" for this audience).

---

## The coach (chat)

**[HIGH] Every chat CTA uses the failing salmon token (`cta`, 3.43:1) instead of the AA-safe `ctaFilled`. (Verified.)**
*Screens: `chat_screen.dart` — send (1350), composer mic (1337), pending-action Confirm (1018), crisis-call (1133); `tab_scaffold.dart:420` center mic.*
The theme documents that `cta` (#C97458) measures 3.43:1 on white — fails WCAG-AA for text/icons — and `ctaFilled` (#B05C40, 4.72:1) was created *precisely* for white-on-filled-button. Yet the coach (the product's core wedge) puts white glyphs/text on the failing token everywhere. Confirmed in code: `backgroundColor: context.hc.cta` on Send and Confirm, and `context.hc.cta` on the crisis-call button. **Fix:** switch the filled backgrounds on Send, pending-action Confirm, crisis-call, and the center voice button to `context.hc.ctaFilled`. Keep `cta` for decorative/border use (idle mic icon, card borders) where it carries no white text. *(ACL §3: reproducible contrast failure on the app's primary actions.)*

**[HIGH] Chat empty-states still speak in the retired dementia/decoder voice. (Verified in guidelines; chat copy per reviewers.)**
*Screens: `conversation_list_screen.dart:277-287`; `chat_screen.dart:637-638`.* The first thing a new caregiver reads on the Chat tab is "When something's confusing — a behavior you haven't seen before, a phrase that keeps coming up — start a chat…" — the old Behavior-Decoder framing the pivot was meant to strip. A caregiver for a post-surgery parent or disabled sibling won't see themselves in "a phrase that keeps coming up." The in-thread hints lean dementia-ish too. **Fix:** rewrite to general-purpose, broadly-relatable moments ("a medication that's confusing, a hard day, a decision you're weighing, what to ask at the next appointment"); align both empty states on the same welcoming, non-dementia voice. *(ACL §3: the first-run copy decides "is this for me.")*

**[MEDIUM] Nothing signals coach answers are AI-generated or should be sanity-checked.**
*Screen: `chat_screen.dart:107-108` (disclaimer), 894 ("Coach said").* The only framing is the word "coach" and the medical-liability line. Nothing cues that replies are machine-generated and can be wrong, and there's no "double-check important details" nudge — a tired caregiver can over-trust a confidently-worded suggestion. **Fix:** broaden the disclaimer to something like "Your coach is AI-assisted and can be wrong — double-check anything important. Not medical advice; in an emergency, call 911." (still no vendor name), or add a subtle "AI-assisted" tag near the first assistant bubble. *(ACL §3: transparency + supports human judgment are explicitly scored and currently absent here.)*

**[MEDIUM] Composer mic is easy to confuse with Send — two same-size salmon-tinted circles side by side.**
*Screen: `chat_screen.dart:1312-1366`.* The row is [field][mic circle][send circle], identical size, ~8px apart; the idle mic's salmon icon competes with the salmon Send. One-handed, a caregiver aiming for Send can start a recording (or vice-versa) — and there's *already* a prominent center mic, so a second one adds "which mic does what" ambiguity. **Fix:** make the composer mic visually secondary (smaller, or an outline affordance inside the field's trailing edge) and add gap. *(ACL §3: prevents mistap between "start recording" and "send.")*

**[MEDIUM] No timestamps or turn separation — the thread is a wall of alternating bubbles.**
*Screen: `chat_screen.dart:755-777`.* Persistent per-loved-one chats are the point, but a caregiver returning days later has no idea when advice was given (which matters when the situation changed), and the conversation-list tile shows no relative time. **Fix:** add dim relative timestamps under each turn-cluster (or a date divider on day change) and a relative time on list tiles (`createdAt` is already loaded). *(ACL §3: re-orient in an old thread without re-reading.)*

**[MEDIUM] Retry is the only recovery, and the error can't tell "offline" from "coach down."**
*`chat_service.dart:83` + `chat_screen.dart:925-949`.* The failed-reply bubble always says "Couldn't reach the coach just now. Try again in a moment." — so an offline caregiver taps uselessly, not realizing they need Wi-Fi. **Fix:** when it's a connectivity error, say so ("You appear to be offline — check your connection and try again"), reusing the existing `NetworkErrorView` language. *(ACL §3: prevents wasted effort in the hospital-hallway / basement conditions the challenge cares about.)*

**[LOW] The pinned "…call 911" disclaimer eats permanent vertical space and can read as an alarm.**
*Screen: `chat_screen.dart:544-554`.* Required guardrail, but on a small phone with the keyboard up it crowds the composer and the clinical "911" can feel alarming in a calm-helper app; it also duplicates the crisis card. **Fix (polish):** keep it, but tighten it / soften the 911 clause, and ensure it doesn't push the composer up under the keyboard.

---

## Forms & error-prevention

**[HIGH] Local DB save has no error path — a failed write spins Save forever. (Verified: no try/catch/finally.)**
*Screens: `medication_form_screen.dart:409`; `appointment_form_screen.dart:554`.* Both set `_submitting = true` then `await repo.upsert(...)` with no try/catch or finally. If the drift write throws — and the team's own memory notes a recurring "database is locked" bug — `_submitting` never resets, the button stays dimmed/spinning forever, and the caregiver gets no snackbar and no error, stranded with a full form of just-entered data (a med list, agenda items, reminders). This is the least-forgiving failure mode in the app. The chat screen already proves the fix (its `finally` re-enables the composer on an errored stream). **Fix:** wrap the write in try/catch/finally — on catch reset `_submitting`, keep the form populated, show a recoverable "Couldn't save right now — try again." *(ACL §3: tested in realistic conditions on a loaded device; supports recovery.)*

**[HIGH] Form labels aren't wired to their fields for screen readers (systemic, ~34 fields).**
*Shared widget: `labelled_field.dart:16-29` (used by medication, appointment, health-log, care-plan-routine, insurance-appeal, find-provider, import-review).* The field name ("Name", "Dosage", "End date") is a sibling `Text` above a bare `TextFormField` whose `InputDecoration` carries only `hintText`. Once the caregiver types a value, the field has *no persistent accessible name* — the reader announces just the typed text, so an AT user can't tell the dosage field from the frequency field. This is the widest a11y gap because it repeats across every form. **Fix:** in the shared widget, move the label into `InputDecoration.labelText` (Material auto-associates and floats it) or wrap the child in `Semantics(label: label, textField: true)` — one change fixes ~34 sites. *(ACL §3: an AT user literally can't tell which medication field they're editing — inviting the exact dosing errors the app should prevent.)*

**[MEDIUM] Primary Save/Search CTAs across most Care forms use the failing `cta` background. (Verified.)**
*Screens: appointment form (Save, 889), health-log form (Save, 414), find-provider (Search), medication-import-review (Save), journal-wizard (Save), care-summary (Share), emergency-card-edit (Save) — vs the already-fixed `medication_form`/`medication_list` which correctly use `ctaFilled`.* Same 3.43:1 vs 4.72:1 issue as the chat CTAs: the one control a caregiver most needs to see (the big salmon Save bar in every form golden) is the one that fails contrast. **Fix:** swap `backgroundColor: context.hc.cta → context.hc.ctaFilled` (foreground white) on every filled primary button carrying white text — one token per site, making the suite consistent with the medication screens. *(ACL §3: documented AA failure on the primary action of most Care forms.)*

**[MEDIUM] Medication form is one 15+ field scroll with no grouping between everyday and prescription-label fields.**
*Screen: `medication_form_screen.dart:537-833`.* Only a small "Prescription details (optional)" heading separates the essentials from seven optional label-transcription fields; there's no collapse, so every by-hand add scrolls past Rx number and discard-after dates when in reality only Name + Dosage + Times are needed. Reads as "this is a lot of work." **Fix:** put the "Prescription details (optional)" block behind a collapsed `ExpansionTile`, or move it below the scheduling controls so Save comes right after the essentials. Shortens the perceived form to ~5 fields for the common case. *(ACL §3: efficiency / cognitive load.)*

**[MEDIUM] Health-log "at least one reading" and "both BP numbers" rules only surface *after* Save, in low-contrast salmon.**
*Screen: `health_log_entry_form.dart:218-294, 393-402.* No required markers; a caregiver can Save empty and only then get the rule (rendered in `cta` salmon, itself low-contrast). A save→error→hunt loop. **Fix:** state "Fill in at least one reading" under the vitals heading *before* submission, and render `_formError` in `context.hc.error` (the AA-safe red) not `cta`. Keep the excellent per-field range validators. *(ACL §3: state constraints before commit + legible error text.)*

**[MEDIUM] Medication card long-press-to-delete is undiscoverable and easy to trigger by accident.**
*Screen: `medication_list_screen.dart:280-282`.* The whole card is a `GestureDetector` (tap = edit, long-press = delete), duplicating the visible trash icon already at top-right. Long-press fires accidentally while scrolling with a full hand; tap-to-edit on the whole body is broad too. (It's only MEDIUM because both delete paths show a confirm + real Undo.) **Fix:** drop the redundant long-press delete (the trash icon already covers it with the same confirm+Undo). *(ACL §3: remove a hidden destructive gesture.)*

**[MEDIUM] Destructive-delete recoverability is inconsistent — meds get Undo, appointments/journal/tasks are gone for good.**
*Screens: medication delete (exemplary Undo) vs appointment (`appointment_detail_screen.dart:147-185`), journal (`journal_entry_screen.dart:116-151`), task (`tasks_screen.dart:474`) — all hard-delete, say "This can't be undone," no Undo, some with no success snackbar.* The medication soft-delete + re-upsert Undo is proven to work, but forgiveness is a coin-flip by object type. Journal entries especially warrant undo given the voice/photo effort. **Fix:** extend the med soft-delete + Undo pattern to appointment, journal, and task deletes; at minimum add a success snackbar. *(ACL §3: prevents user error, recoverability.)*

**[MEDIUM] No offline indicator — shared Care Circle edits queue silently with no "pending sync" signal.**
*App-wide (no `connectivity_plus`); `sync_service.dart:458-462`.* Local-first is the right architecture and the sync queue retries correctly — but Care Circle is a *shared* surface where co-caregivers coordinate. When one edits a shared task/shift offline, nothing signals the change hasn't reached the others, so they assume the handoff was seen. A coordination-safety gap. **Fix:** on shared Care Circle surfaces only, show a lightweight "offline — changes will sync when you reconnect" chip driven off queue depth/connectivity. Purely-local surfaces (journal, health log) don't need it. *(ACL §3: transparency + realistic conditions — waiting-room networks.)*

**[MEDIUM] Saving a med or appointment gives no success confirmation — the screen just pops.**
*Screens: `medication_form_screen.dart:458-463`; `appointment_form_screen.dart:574-579`.* Both just `context.pop()` on success — no toast — so a distracted caregiver has to re-scan the list to confirm the save landed. Contrast the delete flow ("Metformin removed.") and provider-save ("Saved Dr. X"). **Fix:** show a brief "Medication saved." / "Appointment saved." snackbar on the destination, matching existing patterns. *(ACL §3: transparent feedback, closes the loop.)*

**[LOW] Find-a-provider is one-directional — no saved list, no way to reach a saved provider, and results are an unpaginated scroll.**
*Screen: `find_provider_screen.dart:109-126, 313-318`.* Broad searches dump a very long list with no count; saving shows a snackbar + green check but no "X saved" summary and no jump to where saved providers live. **Fix:** show a result count ("12 clinicians found"), cap/paginate, and after a save offer "Saved — use in a new appointment?" to close the loop. *(ACL §3: turns a feature into a finished workflow.)*

**[LOW] A failed AI scan's "couldn't read" recovery is correct but under-centralized.**
*`medication_list_screen.dart:231-238` → `medication_import_review_screen.dart:207-208`.* On an empty draft the review screen's `initState` fires the "Couldn't read that photo — try in better light or enter by hand" hint, and it works today — but the list helper pushes silently, so the only feedback depends on that one initState. Fragile to future refactors. **Fix:** make the "couldn't read" hint part of the scan return contract (surface it where the empty draft is produced, as `scan_document_screen.dart:105` already does). *(ACL §3: human-in-the-loop.)*

---

## Accessibility (cross-cutting)

*Several accessibility items are ranked in their home sections above because they're the highest-impact instances of a category — the contrast-token failures (chat + Care forms) and the form-label wiring gap. The following are additional a11y-specific findings.*

**[HIGH] Home "mark done" checkbox has no Semantics and a sub-44px hit target.**
*Widget: `schedule_card.dart:583-608` (`_DoneCheckbox`), 452-476 (`_DoseStatusMark`).* The "mark appointment done" control is a bare `InkResponse` around a 22px icon (radius 20 → ~40px target, under the WCAG 2.5.5 44px floor) with **no Semantics** — a reader announces an unlabeled tappable with no name, role, or checked state, so an AT user can't tell it toggles an appointment complete. Dose-status marks convey "taken" via icon+color only. This is on the app's most-visited screen. **Fix:** wrap in `Semantics(button: true, checked: done, label: 'Mark done'/'Mark not done')` and bump to a 44×44 target; merge each dose row into one Semantics node stating name + "taken"/"not taken yet." *(ACL §3: the primary daily action is invisible and hard to hit for older/AT users.)*

**[MEDIUM] The 2.2× dynamic-type ceiling silently caps the largest OS accessibility sizes.**
*`app.dart` MediaQuery override (~230-250).* The app correctly *composes* the in-app multiplier with the live OS textScaler (good pattern), but clamps the combined factor to 2.2×. iOS "Larger Accessibility Sizes" and Android max reach ~3.1–3.5×, so a low-vision caregiver who maxed system text is silently held at 2.2× — overriding their deliberate OS choice. **Fix:** raise/remove the ceiling and let layouts reflow (tab labels already ellipsize, most screens are ListViews); if a hard cap must stay, set it near 3.0 and verify chat composer / med form / schedule card with a max-scale golden. *(ACL §3: an older low-vision caregiver's real device is often at max OS text size.)*

**[MEDIUM] Username validation error rendered in decorative salmon (3.43:1).**
*`username_screen.dart:221-224`.* The recovery message — the text a user *must* read to fix a mistake — is drawn in `context.hc.cta` at 16px on white, below the 4.5:1 AA floor, while the theme ships an AA-passing `error` token (#CF2E2E) that isn't used. **Fix:** render in `context.hc.error` and audit other validation strings for the same substitution. *(ACL §3: the recovery message is the least legible text on screen.)*

---

## Copy & voice

**[HIGH] Community guidelines are dementia-only and point crisis-seekers to a "Crisis tab" that doesn't exist. (Verified.)**
*Copy: `community_guidelines.dart:44` ("This board is for dementia caregiving questions…") and `:67` ("The Crisis tab (the bell on the right) has…"); surfaced in the first-post gate and full page.* Two stale statements in the locked guidelines a new poster is *forced* to read: (1) a dementia-only scope that tells a post-surgery/disability caregiver they're off-topic, contradicting the general-purpose product; (2) a crisis pointer to a tab that doesn't exist — the only header bell is an admin-only moderation shield. A caregiver in crisis, following the app's own instructions, hunts for a resource that isn't there. **Fix:** rewrite Scope to general caregiving (drop "dementia," diagnosis-agnostic example); fix the crisis section to name the real path (Community › Support), or add a persistent crisis affordance and point at it. These are "locked content" strings that slipped past the rebrand and need a spec edit. *(ACL §3: sending a caregiver in crisis to a phantom tab is the opposite of forgiving; the dementia scope makes the whole community read as not-for-me.)*

**[HIGH] Crisis / 988 resources are buried inside a collapsed card mislabeled "Respite."**
*`support_screen.dart:115-121` + `support_content.dart:130-136` (988 lives inside `respiteResources`).* The 988 Lifeline is reachable only via: Community → Support → find and tap the collapsed "Respite resources" card ("respite" means "a break," not "crisis") → then dial. A caregiver in acute distress at 2am will not parse "Respite resources" as "where the crisis line is." **Fix:** split crisis lines into their own clearly-labeled "In a crisis" card at the *top* of Support (expanded / non-collapsible), or add an always-reachable crisis link; then make the guidelines copy point there. *(ACL §3: tested in realistic conditions — a caregiver in distress; depth-of-burial harms the safety promise the app makes in its own guidelines.)*

**[MEDIUM] "Read scripts aloud" / "coaching scripts" — stale decoder-era vocabulary in Settings. (Verified.)**
*`settings_screen.dart:245,249,256,258`.* The coach produces conversational replies, not "scripts" — "scripts" is a leftover from the retired Behavior-Decoder era and is confusing ("what scripts? I never wrote one"). **Fix:** rename to "Read replies aloud" / "Speak the coach's replies"; subtitle "Plays the coach's replies through your phone voice." (the internal flag can keep its name). *(ACL §3: labels should match what the feature does.)*

**[MEDIUM] Raw "Patient" label rendered on the Emergency Card. (Verified.)**
*`emergency_card_screen.dart:211`.* The card's first section is labeled "Patient" — a user-facing string CLAUDE.md explicitly forbids (use "your loved one" / "your person"). It's especially jarring on a screen handed to a first responder about a loved one. **Fix:** drop the label (the name block is self-evident) or use "Your loved one." *(ACL §3 / brand voice: keep the tool humane and non-clinical.)*

**[MEDIUM] NPI jargon exposed on Find-a-provider.**
*`find_provider_screen.dart:302, 414, 240`.* "NPI" is surfaced as a result-card field label and in helper text ("the public NPI Registry"), and the filter segment is abbreviated "Orgs" — insider billing jargon that doesn't help a family caregiver decide who to call. **Fix:** drop the raw "NPI" field (or relabel "Provider ID," de-emphasized, last); reword helper text to "Results come from the official U.S. directory of licensed providers"; expand "Orgs" → "Clinics." *(ACL §3: strip domain jargon for a non-technical audience.)*

**[LOW] Inconsistent title-casing across Care hub tiles and sub-labels.**
*`medical_hub_screen.dart:42-107`.* "Health Log"/"Emergency Card" (Title Case) sit next to "Find a provider"/"Care summary" (sentence case); sub-labels use pharmacy shorthand ("Rx"). **Fix:** pick sentence case throughout ("Health log," "Emergency card," "Care circle") and spell out "Rx" → "Prescriptions." *(ACL §3: consistency signals a tested product.)*

**[LOW] Spanish onboarding is partially untranslated.**
*`app_localizations_es.dart:124,178,185` — loved-one-setup strings still English ("Let's set up your person," "Save and continue") while other keys are correctly Spanish.* A Spanish-locale caregiver hits English mid-flow during first-run setup — reads as unfinished at the worst moment. **Fix:** translate the remaining `lovedOneSetup*` and audit the full `es` file; prioritize setup since it's one of the first surfaces. *(ACL §3: bilingual caregivers are a core audience.)*

---

## Visual design

**[HIGH] Settings toggles show a bright RED "OFF" pill for benign, off-by-default options. (Verified.)**
*`holdclose_switch.dart:35` — `track = value ? hc.success : hc.error`.* The custom switch paints its track green when on and **red (`hc.error`) when off**, so Settings shows a column of red "OFF" pills next to entirely benign options (Read scripts aloud, Quiet hours, high-quality voice, Reset on launch). Red universally reads as error/danger — for a stressed caregiver scanning Settings, a wall of red signals "something is wrong" when nothing is, undermining trust in a health app. **Fix:** make "off" a neutral state — a muted navy/grey track (`primarySoft` or a neutral surface), reserving red exclusively for genuinely destructive states. Keep the ON/OFF text label. *(ACL §3: calm, not falsely alarming.)*

**[MEDIUM] Care hub icon chips use a rainbow of six palette roles with no semantic system.**
*`medical_hub_screen.dart:45-108`.* Each of ~11 tiles gets a different `chipColor` (navy/blue/accentDeep/salmon/green/text) with no grouping logic, reading as a noisy patchwork. The colors communicate nothing, and using brand salmon (the CTA color) as a decorative tint on "Schedule"/"Emergency Card" dilutes its signal value. **Fix:** navy icons on warm-white by default, reserving salmon for the one or two highest-intent actions (Scan / Emergency Card) — or color by a real semantic group. *(ACL §3: a calm, legible grid reduces scanning load.)*

**[MEDIUM] Settings slider and segmented controls render in default Material purple/lavender.**
*`theme.dart` defines no `SliderThemeData`/`SegmentedButtonThemeData` → speed slider (`settings_screen.dart:509`) and font-size/theme segmented buttons (571, 657) fall back to Material purple.* The golden shows a purple thumb and lavender segment — colors that appear nowhere else in the brand, on a trust surface. CLAUDE.md explicitly says "Don't ship default Material colors." **Fix:** add `SliderThemeData` (active track / thumb → `cta`/`primary`) and `SegmentedButtonThemeData` (selected `primary` / white) to `theme.dart`. *(ACL §3: consistency signals a finished, trustworthy tool.)*

---

## System states & feedback

*(The two most severe state findings — no save-error path, and no offline signal for shared edits — are ranked under **Forms & error-prevention** above. The rest:)*

**[MEDIUM] Emergency Card is missing blood type and buries allergies below conditions + the full med list.**
*`emergency_card_screen.dart:207-260` (section order); `emergency_card_edit_screen.dart:216-235` (verified: no blood-type field).* The card leads with Patient → Conditions → the full medication mirror → Allergies fourth. EMS triage on allergies and blood type *first*; a penicillin allergy shouldn't be scrollable below a long med list, and blood type isn't captured at all. **Fix:** add a blood-type field; re-order the read-only card so allergies + blood type render immediately under identity (above conditions and meds); consider a red-tinted allergy card so it visually jumps out. *(ACL §3: an ER-handoff card should front-load the life-safety fields.)*

**[LOW] List/form screens render a blank body during load (`SizedBox.shrink`) instead of a skeleton.**
*~20 screens (e.g. `medication_list_screen.dart:196`, `health_log_screen.dart:70`, `appointment_list_screen.dart:229`, `tasks_screen.dart:133`, `calendar_screen.dart:265`).* On a cold DB or slow first `activePatientId` resolution, the caregiver sees a header then blank space — indistinguishable from an empty state or a hung screen. The Home cards already do this right with `_Skeleton` shimmer bodies, so the good pattern exists. **Fix:** reuse the Home-card skeleton idiom for list bodies (or at least a centered spinner) so slow loads read as "loading," not "broken." *(ACL §3: show the system is working under realistic slow-device conditions.)*

---

## What's already working (keep + showcase)

These are genuine strengths — several are worth leading the competition packet with, because they hit ACL §3 dead-on.

- **The chat coach's failure/interruption recovery is best-in-class.** "Coach is thinking…" spinner for dead-air, word-by-word fade-in, an inline "Try again" that re-sends without retyping, a `finally` that always re-enables Send, and an app-lifecycle observer that **auto-recovers a reply interrupted by the phone locking mid-stream** (iOS suspends the socket). This is exactly the realistic-conditions robustness §3 rewards — and the reference pattern the forms should copy. *(Minor: surface a brief "Reconnecting…" cue on resume so the recovery isn't invisible.)*
- **The scan → review → approve flow is a textbook human-in-the-loop pattern.** "We read these from your photo — nothing is added until you tap Save," per-field amber "we weren't sure" flags that clear the instant you edit, and "scan another side" tops up only empty fields. **Lead the packet with this** (Caregiver-AI Principle 2). *(Minor: give the "uncertain" banner a stronger icon/heading so it's distinct from the informational banner.)*
- **The pending-action confirm card.** Destructive/mutating AI actions never auto-run — "Add the medication 'Donepezil' (10 mg)?" with a warm-amber border, "Confirm" vs "Keep it," writing only on explicit tap, voice mode included. The single strongest usability asset in the chat surface. *(Minor: distinct framing for Remove vs Add; echo "Done — added Donepezil" in the snackbar.)*
- **The crisis card is trusted, code-side, and fires even when the model fails.** Rendered from app data (988, Eldercare Locator) above any reply, warm non-judgmental copy, one-tap call — a genuine safety differentiator. *(Confirm its call buttons also use `ctaFilled`.)*
- **AI features are consistently framed as review-first drafts** ("a starting point — check every detail before you send it"; "you review before anything is saved"), with the vendor never named. *(Minor: add a "double-check this reflects current info" nudge to Care summary for parity.)*
- **Navigation backbone:** the four-tab bar (always exactly four word-labelled, non-collapsing tabs, re-tap-to-pop) and PathHeader (uniform back arrow ≥44px + tappable breadcrumbs on every feature page) are a textbook wayfinding win for a non-technical audience.
- **Hub tiles** are hard-locked to 2 columns, ≥96px tall, with plain-language sub-labels — good target ergonomics for 45–65 hands.
- **First-run guidance:** the empty ScheduleCard offers three ranked labeled CTAs instead of a blank screen; the loved-one setup form is minimal, warm, and clearly marks required vs optional with one-tap DOB clear and a retry-on-failure Save. *(Minor: add "Add an appointment" as a fourth Home CTA — the current empty state biases entirely toward medications.)*
- **Forms get the small correctnesses right:** correct keyboard types, physiologically-sane vitals ranges with plain-language messages, split date/time pickers, auto-title-casing ("donepezil" → "Donepezil").
- **Delete/undo forgiveness on medications** is a *real* recovery — soft-delete snapshots the live row and Undo re-upserts it (the fix is to extend this to appointments/journal/tasks, above).
- **Accessibility done right where it's done:** the tab items (`Semantics(button, selected, label)`), the voice mics (state-flipping labels that never name the vendor), and emergency-call/social-card buttons ("Call {name}", bundled post nodes) are the reference implementations the bare-icon tappables should follow.
- **Error & empty-state copy** is uniformly warm, specific, and actionable ("Couldn't read that photo. Try again in better light, or enter the details by hand."; "Server hiccup. We logged it — try again in a bit."), and the shared `NetworkErrorView` distinguishes offline from server error and never leaks a raw exception.
- **Community guidelines gate + tone** ("the agreement that lets caregivers tell each other the truth about hard days," "we'll never ask again") and the **task-claim just-in-time hint** ("You've claimed this — tap Complete when it's done.") are values-first, real-user-informed design — once the dementia scope + phantom-tab pointer are fixed, the guidelines become a standout.

---

## Top 10 highest-impact fixes (execute in order)

1. **Wire up (or delete) the Home quick-add FAB.** Mount `AddActionFab` in `HomeScreen.floatingActionButton` — it's already built, golden-tested, and the docstring already claims it's there. Restores a labeled + button for the app's most frequent action (log a dose). *(Verified dead code.)*
2. **Add a try/catch/finally to the med + appointment saves** (`medication_form_screen.dart:409`, `appointment_form_screen.dart:554`). Copy the chat screen's proven pattern so a DB-lock write failure re-enables Save, keeps the data, and shows a recoverable snackbar instead of spinning forever. *(Verified: no error path today.)*
3. **Fix the community guidelines** (`community_guidelines.dart:44,67`): drop the dementia-only scope for general caregiving, and replace the phantom "Crisis tab" pointer with the real path — plus split the 988 lines out of "Respite resources" into an "In a crisis" card at the top of Support. Safety + "is this for me." *(Verified.)*
4. **Migrate every filled CTA from `cta` to `ctaFilled`** — chat Send/Confirm/crisis-call + center mic, and the Save/Search bars on appointment, health-log, find-provider, import-review, journal-wizard, care-summary, emergency-card-edit forms. Fixes the documented WCAG-AA failure on the app's primary actions; one token per site. *(Verified.)*
5. **Make Settings "OFF" toggles neutral, not red** (`holdclose_switch.dart:35`): swap `hc.error` → a muted navy/grey track. Removes the wall-of-red "something's wrong" signal on benign options. *(Verified.)*
6. **Wire form field labels for screen readers** in the shared `LabelledField` widget — move the label into `InputDecoration.labelText` or `Semantics(textField: true)`. One change fixes ~34 fields so an AT user can tell dosage from frequency.
7. **Rewrite the chat empty-states** off the decoder-era "a behavior you haven't seen / a phrase that keeps coming up" onto general-purpose caregiving moments, so the coach reads as for-everyone at the entry point.
8. **Surface the Emergency Card and the Care Circle** — promote Emergency Card to the top row of the Care hub (add a blood-type field + move allergies up while you're there), and always show the Care Circle tile (first-tap onboarding CTA) instead of hiding it behind an off-by-default Settings toggle.
9. **Add a Semantics + 44px hit target to the Home "mark done" checkbox** (`schedule_card.dart:583-608`) and confirmation snackbars on successful med/appointment saves. The primary daily action becomes usable for AT users and every save closes its loop.
10. **Clean the remaining stale/clinical copy:** "Read scripts aloud" → "Read replies aloud" (Settings), "Patient" → "Your loved one" (Emergency Card), and strip "NPI" jargon from Find-a-provider. Low effort, directly on-voice, judge-visible.

*Groups 1–3 and 5, 7, 10 are largely copy + token swaps that ship in a day and are aimed squarely at the ACL §3 rubric (usability, forgiveness, transparency). Group 2, 6, 8, 9 are small robustness/a11y fixes with outsized effect on the most-used and highest-stakes surfaces.*
