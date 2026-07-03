# Caregiver App — Layout Specification

> **Note (2026-06-22 pivot):** the app is rebranding **Careblazers →
> Holdclose** and going **general-purpose caregiving** (not dementia-only).
> The IA below (4-tab bar, hubs, path header) is still accurate; just read
> "Careblazers" as "Holdclose," and note the Behavior Decoder is being
> removed, so any decoder-related destination is gone. See
> [`CLAUDE.md`](../CLAUDE.md) → **Direction**.

## Scope and intent

This document describes the **information architecture and screen layout only**. The accompanying HTML file (`menu_layout.html`) is a structural reference — it shows hierarchy, screen composition, and navigation, not final visual design.

**Important — colors and fonts:** The palette (navy / coral / teal / amber) and fonts (Fraunces, Figtree) in the HTML are placeholders used purely to make the structure readable. **Do not adopt them.** Reuse the color patterns and typography that already exist in the app. Keep the app's established design tokens. The only visual constraints that carry over from this spec are accessibility-driven: large tap targets, large readable text, high contrast, and word labels alongside icons — implemented in the app's existing colors, not these.

## Audience constraint (drives every layout decision)

The users are caregivers, including older spouses (65+). Layout priorities, in order: nothing hidden, large tap targets with generous spacing, word labels paired with icons (never icon-only), shallow depth, and clear "where am I / how do I get back" cues.

## Global navigation model

- A **persistent bottom tab bar** is visible on every screen. Four tabs (IA refactor 2026-06-06), always shown, never collapsed into a menu.
- Tabs, left to right: **Home, Care, Chat, Community**. "Medical" was renamed **Care**; the former "Team" tab folded into Care as a gated **Care Circle** hub (Tasks, Shifts, People, Activity, Expenses). Route paths stay `/medical` + `/team/*` internally.
- The active tab is clearly highlighted.
- Each tab has three possible landing behaviors:
  - **Home** → a dashboard.
  - **Chat** and **Community** → open directly to their content (a message list / a social feed).
  - **Care** → opens to a **tile hub** (a grid of large labeled tiles). Care is the only tab that lands on a tile hub; the former "Team" tab is now a **sub-hub** reached from a Care tile (see below), not a top-level tab.
- Tapping the **already-active** tab returns the user to that section's landing/hub.
- **Maximum two levels deep:** Section → (tile hub) → feature page. Anything that would be a third level uses in-page tabs or a segmented control instead of another grid of tiles.
- **No hamburger / hidden menu anywhere.** Account, settings, and help sit behind a profile icon on the Home screen, not in the bottom bar.

## Path header (on feature pages below a hub)

- The top of each feature page shows the path, e.g. `Home › Medical` followed by the page title (e.g. "Medications").
- Path segments are **tappable** — tapping a parent navigates up to it.
- Include an explicit, **word-labeled Back control** (e.g. "‹ Back to Home"). Do not rely on swipe gestures or the OS back button alone.
- Landing screens (Home, Chat, Community, and the Care hub itself) show just the section title — no breadcrumb or Back, since they are top level. The Care Circle sub-hub is one level below Care, so it carries a `Care › Care Circle` crumb.

## Bottom tab bar details

- **Exactly four tabs** — Home, Care, Chat, Community — never five, never collapsed or conditionally hidden. Each tab is **icon + word label**, both always visible.
- The bar has five *slots*: the four tabs spread two-left / two-right around a raised salmon **voice (mic) button** that sits inline in the center slot. The mic is an **action, not a navigation destination** — it carries no branch, so the four-tab invariant holds. (Layout: `[Home] [Care] (mic) [Chat] [Community]`.)
- Bottom placement (thumb reach). Large hit areas, clear active state, generous spacing so adjacent tabs aren't mis-tapped.

## Screen-by-screen layout

### 1. Home — "Today" dashboard
A vertical scroll of cards, not a tile grid. Top to bottom:
1. Greeting / header.
2. **Pinned Emergency Card** — a prominent, full-width button at the top. One tap opens the emergency/medical card. It is pinned here (in addition to living in Medical) so it's reachable instantly in a crisis.
3. **Medications Today** card — today's doses with status (taken / due).
4. **Next Appointment** card.
5. **Recent Activity** card — latest care-circle events.
6. A floating **"+ Add"** action button for quick logging (should support voice input).
- An AI "catch me up" summary of recent activity can also live on this screen.

### 2. Care — tile hub
A two-column grid of large tiles, each = icon + label + short sub-label. This is the tab formerly called "Medical" (route path stays `/medical` internally). Tiles, in the order they render (source: `lib/screens/medical/medical_hub_screen.dart`):
- **Scan a document** — Rx, appointment, insurance card → `/scan`
- **Find a provider** — search clinicians (NPI) → `/find-provider`
- **Care summary** — share with a clinician → `/care-summary`
- **Medications** — doses & reminders → `/medications`
- **Schedule** — today, tomorrow, this week → `/team/calendar?from=medical`
- **Appointments** — calendar & visits → `/appointments`
- **Health Log** — symptoms & vitals → `/medical/health-log`
- **Routines** — scheduled care tasks → `/medical/routines`
- **Emergency Card** — info for first responders → `/medical/cards/emergency`
- **Journal** — care notes → `/journal`
- **Care Circle** *(conditional)* — helpers, shifts & tasks → `/team`

The three lead tiles — **Scan a document**, **Find a provider**, and **Care summary** — are the newer intake/coordination features. Note the renames: the old **Care Plan** tile is now **Routines**, and the old **Cards & Documents** tile is now **Emergency Card**. The old "Medication Schedule" tile is folded into **Schedule**.

**Care Circle is gated:** the trailing Care Circle tile appears only when the `teamCoordinationEnabled` setting is on — a solo caregiver never sees it. Tapping it opens the Care Circle sub-hub (§3).

This hub deliberately carries **~10–11 tiles**, more than the earlier "4–6 per hub" guideline suggested. The count is accepted here because Care is the app's densest section and each tile is a distinct, self-contained destination; the earlier cap no longer applies to this hub. (Journal is placed here per the product's current model; it may instead live under Community → Support if it's primarily for caregiver reflection.)

The **insurance-appeal helper** (`/insurance-appeal`) is *not* a Care-hub tile. It is reached from the Emergency Card's Insurance block via a "Draft an appeal letter" action (see §2a), keeping it in context next to the carrier/policy details it needs.

#### 2a. Emergency Card entry points
The Emergency Card (`/medical/cards/emergency`) is a feature page under Care. Its Insurance block offers two in-context actions: **Call insurer** (tap-to-call) and **Draft an appeal letter**, the latter opening the AI insurance-appeal helper at `/insurance-appeal` (pre-seeded with the carrier). The Emergency Card is also pinned on Home for one-tap crisis access.

### 3. Care Circle — a sub-hub under Care (not a tab)
The former "Team" tab folded into Care. Its `/team/*` routes now live inside the Care shell branch, and it is reached as a **sub-hub** by tapping the conditional **Care Circle** tile in the Care hub (gated on `teamCoordinationEnabled`). It is one level below the Care landing, so it shows a `Care › Care Circle` breadcrumb. Two-column tiles (the multi-caregiver orchestration layer), source `lib/screens/team/care_team_hub_screen.dart`:
- **Tasks** — to-dos & assignments → `/team/tasks`
- **Shifts** — who's on when → `/team/shifts`
- **People** — who is helping → `/team/circle`
- **Activity** — recent updates → `/team/activity`
- **Expenses** — costs & receipts → `/team/expenses`

(The shared **Calendar** the old Team hub carried now surfaces as the **Schedule** tile in the Care hub itself, at `/team/calendar?from=medical`.)

### 4. Chat — direct landing
Opens straight to a list of conversations: the care-circle group, individual members, and provider threads. Standard message-list layout (avatar + name + message preview + timestamp).

### 5. Community — direct landing (social feed)
Lands on the **Feed**. A **segmented control / sub-nav at the top** offers three views: **Feed · Learn · Support**. This in-tab sub-nav is intentional — it lets a sixth destination's worth of content live here without adding a sixth tab (which would shrink targets below what the audience needs).
- **Feed** — the social experience: posts with avatar, name, timestamp, body text, optional image, and **word-labeled actions (Like · Comment · Share)**. Includes official Holdclose posts and caregiver posts; supports grouping by topic / care situation.
- **Learn** — the app's content library (curated caregiving videos) and "what do I do when…" playbooks.
- **Support** — caregiver wellbeing (burnout self-check, respite), expert Q&A, and crisis resources.

## Behavior rules (summary)

- No hidden navigation; bottom bar always visible.
- Two levels deep, maximum.
- Icon **and** word label on every navigational element.
- Redundant location cues: the bottom bar shows the current section; the header shows the current page.
- Every section behaves the same way (consistent, predictable interaction).
- Tapping the active tab returns to its hub/landing.

## Reminder on visuals

Repeat, because it's the easiest thing to get wrong: the HTML's specific colors and fonts are not the design. Build these layouts using the app's existing color patterns and type system. Preserve the accessibility properties (size, contrast, spacing, word labels), but express them in the established palette.
