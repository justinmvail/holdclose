# Gap Analysis — where the packet stands vs. Phase 1 requirements

Legend: ✅ done · ⚠️ drafted-but-needs-real-data · ❌ missing · 👤 only you can provide · 🤖 I can do

_Last refreshed 2026-07-08 after the overclaim-rewrite pass. See
`SUBMISSION_TODO.md` for the full remaining-placeholder inventory and the §5
dementia recommendation._

## Cover page
| Element | Status | Note |
|---|---|---|
| Team/org name | ✅ | JCSV One LLC / Juno Code Studio |
| Solution name | ✅ | Holdclose |
| Primary contact (name/email/phone) | ❌ 👤 | your real contact info (`00_cover_abstract.md`) |
| Citizen/PR status | ⚠️ 👤 | you attest (U.S. citizen) — placeholder in the cover |
| Team members | ✅ | solo (you) |
| Track 1 | ✅ | |
| Abstract (≤250w) | ✅ 🤖 | **NOW REAL** — `00_cover_abstract.md` created this session; 248-word abstract drafted from known facts (veteran + built-app + human-in-the-loop). Previously mismarked ✅ before the page existed. |

## §1 Understanding of Need & Solution Design
| Prompt | Status | Note |
|---|---|---|
| Specific challenge + significance | ✅ | veteran-caregiver framing |
| AI tool + how it helps | ✅ | data-grounded coach + suite |
| **Existing vs. new AI methods** | ✅ (upgraded) | now explicit: existing LLMs (model-agnostic) + the *new* data-grounding |
| AI dev stage (TRL 3+) | ✅ | built, tested app — exceeds TRL-3 |
| **End users shaped design** | ⚠️ 👤 | alpha feedback = seed; need tester count/quotes from the trial |
| **Promising data/research/prior work** | ✅ 🤖 | DONE — §1 Supporting Research now cites the CAN 2026 Tech Insights Survey (sponsor partner data), each stat mapped to a Holdclose feature |

## §2 Implementation Approach
| Prompt | Status | Note |
|---|---|---|
| Implementation/testing/eval for real-world viability | ✅ | |
| **Deployment readiness** | ✅ | built, tested app **sideloaded to physical iOS + Android devices today** + a live web presence (holdclose.care). Store release = a submission/approval step, not engineering. (Corrected: the earlier "Play Open Testing / TestFlight install links" claim was **false** — no store listings exist; the §2 narrative was reworded to match.) |
| User-centered design in impl/testing | ✅ | |
| Timeline + milestones | ✅ | |
| **Team roles + bio sketch** | ⚠️ 👤 | veteran/VBMS bio drafted; confirm specifics |
| Metrics + data-privacy procedures | ✅ | encryption brackets filled truthfully (TLS in transit; **local SQLite encrypted at rest via SQLCipher, key in the device keychain/keystore**; OS device encryption; OS backups off — Android `allowBackup=false`, iOS backup-excluded; server data on Cloudflare D1/R2). |
| Evaluation + continuous improvement | ✅ | |
| Safety + bias monitoring | ✅ | guardrails + human-in-the-loop confirm on every care-data change (chat + voice), uncertainty/weak-data flagging, and a **code-side (non-LLM) crisis watchdog** — all now TRUE after this session's fixes. Red-team + Data Output Logs still to run (see below). |

## §3 Usability & Integration
| Prompt | Status | Note |
|---|---|---|
| Prevents user error + supports judgment | ✅ | confirm cards now gate **every** care-data-changing AI action (chat + voice), not just 3 destructive ones — claim reworded to match |
| Transparency | ✅ | grounded, non-diagnostic, uncertainty flagged (now real) |
| Realistic usability testing | ⚠️ 👤 | alpha done; **document it** + run the July trial (the User-Centered gap, below) |
| Home/org integration | ✅ | care-summary PDF + NPI find-a-provider ship today (find-provider overhauled since Jul 2) |
| Interoperability (EMR/assistive) | ⚠️ | roadmap-honest (planned, not current); §3 now separates shipped-today vs planned |

## §4 Alignment with the 7 Caregiver AI Principles
| Status | Note |
|---|---|
| ✅ (rewritten) | now maps 1:1 to the exact 7 official principles |

## §5 Meritorious (optional)
| Status | Note |
|---|---|
| ⚠️ 👤 | dementia focus area claimed (+$50K); genuine roots but **under-evidenced** after the general-purpose pivot. **Decision needed** — keep only if ≥1 dementia caregiver is documented in testing OR dementia safety scenarios are in the Data Output Logs; otherwise drop. Full recommendation in `SUBMISSION_TODO.md`. |

## Product features shipped since July 2 (strengthen the "built, not concept" claim)
| Feature | Commit | Where it helps the packet |
|---|---|---|
| Structured **weight** field (form, summary, chat action) | `aa00aae` | §1/§3 health-log tracking depth |
| Patient **date of birth** (on emergency card + PDFs) | `92c7953` | §3 emergency-card / care-summary completeness |
| Care-circle **Share link** on the QR screen | `a3d45e0` | §3/§4 care-circle sharing |
| **Terms / Privacy** legal pages wired at sign-in (Worker-served) | `68ea224` | §2/§4 privacy posture, store-readiness |
| **Find-a-provider** overhaul (People/Orgs/All filter, full NPI fields) | `628195b`, `8e48d2b`, `072c652` | §3 provider-shareable / interoperability-adjacent |
| **This-session safety fixes** — every care-data change confirms (chat + voice), uncertainty/weak-data flagging, code-side crisis watchdog | (this session) | §1/§2/§3/§4 — turned the reworded claims TRUE |

## Appendices & separate docs
| Element | Status | Note |
|---|---|---|
| **Letters of support** | ❌ 👤 | 2–3 needed (also feeds Partnerships criterion) — outreach in progress |
| **Data Output Logs (optional TRL evidence)** | ❌ 🤖 | OPPORTUNITY: run the coach through the "Smart 40" + "Protocol 9-Delta" safety probe → strong TRL proof; guardrails should pass. I can generate. |

## Attestations
| Element | Status | Note |
|---|---|---|
| Liability = **$0** | ✅ 👤 | just attest — no insurance to buy |
| IP license to ACL | ✅ 👤 | agree (you keep all real IP) |
| Warranties (original/non-infringing) | ✅ 👤 | true (your own LLC project) |
| SAM.gov **UEI** | ⚠️ 👤 | encouraged to expedite payment; you have an LLC → get one |

## Cross-cutting judging weaknesses (the two to shore up)
| Criterion | Status | Fix |
|---|---|---|
| **User-Centered (caregiver input)** | ⚠️ 👤 | document alpha feedback + run 3–5 trial sessions |
| **Partnerships & Collaboration** | ❌ 👤 | 2–3 support letters (CAN, AAA, Alzheimer's chapter, a clinician) |

---

## THE SHORT LIST — what we're actually lacking (in priority order)
1. **👤 Documented caregiver feedback** (tester count + quotes + what changed) — your #1 gap; the trial provides it. `FEEDBACK_LOG.md` is still template-only.
2. **👤 2–3 letters of support** — covers the Partnerships criterion + appendix. Send `outreach_email.md`.
3. **👤 Send `acl_clarification_email.md`** — contractor-eligibility + $0-liability are existential; get the answer in writing before investing further.
4. **👤 Your contact info + confirm bio specifics + the grandfather/family-experience line** — fills the cover + §1/§2/§5 `[FOUNDER]` placeholders.
5. **👤 §5 dementia decision** — keep-with-evidence or drop (see `SUBMISSION_TODO.md`).
6. **🤖 (optional, high-value) Data Output Logs** — run the coach through the Smart-40 + Protocol-9-Delta safety probe; strong TRL evidence, and it exercises the new uncertainty/crisis guards.
7. **👤 SAM.gov UEI** — quick, expedites the payout.
8. **🤖 Final 508 assembly** into one PDF (cover + §1–§5 + appendix).

**Handled this session:** ~~supporting-research citations~~ ✅ (CAN 2026 survey),
**cover page + 248-word abstract** ✅ (`00_cover_abstract.md`), the **falsifiable
overclaims** (confirm-card / uncertainty-path / LLM-vendor) reworded to code
truth ✅, and the **encryption brackets** filled honestly ✅. What remains is
*evidence-gathering* (feedback, letters), *your specifics*, and the §5 decision —
not writing. Full placeholder inventory: `SUBMISSION_TODO.md`.
