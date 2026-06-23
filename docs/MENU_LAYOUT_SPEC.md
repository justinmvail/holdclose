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
  - **Medical** and **Care Team** → open to a **tile hub** (a grid of large labeled tiles).
- Tapping the **already-active** tab returns the user to that section's landing/hub.
- **Maximum two levels deep:** Section → (tile hub) → feature page. Anything that would be a third level uses in-page tabs or a segmented control instead of another grid of tiles.
- **No hamburger / hidden menu anywhere.** Account, settings, and help sit behind a profile icon on the Home screen, not in the bottom bar.

## Path header (on feature pages below a hub)

- The top of each feature page shows the path, e.g. `Home › Medical` followed by the page title (e.g. "Medications").
- Path segments are **tappable** — tapping a parent navigates up to it.
- Include an explicit, **word-labeled Back control** (e.g. "‹ Back to Home"). Do not rely on swipe gestures or the OS back button alone.
- Landing screens (Home, Chat, Community, and the Medical / Care Team hubs themselves) show just the section title — no breadcrumb or Back, since they are top level.

## Bottom tab bar details

- Five equal-width tabs. Each tab is **icon + word label**, both always visible.
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

### 2. Medical — tile hub
A two-column grid of large tiles, each = icon + label + short sub-label. Tiles:
- **Medications** — doses & reminders
- **Medication Schedule** — daily timeline
- **Appointments** — calendar & visits
- **Health Log** — symptoms & vitals
- **Care Plan** — routine & stages
- **Cards & Documents** — emergency card, POA, IDs
- **Journal** — care notes

Aim for 4–6 tiles per hub; this hub is at the upper limit. Medications + Medication Schedule may be merged into a single tile with an in-page toggle if a trim is wanted. (Journal is placed here per the product's current model; it may instead live under Community → Support if it's primarily for caregiver reflection.)

### 3. Care Team — tile hub
Two-column tiles (the multi-caregiver orchestration layer):
- **Calendar** — shared schedule
- **Tasks** — assign & claim
- **Shifts** — coverage & gaps
- **Care Circle** — caregiver roster, roles & permissions, invites
- **Activity** — feed & handoffs
- **Expenses** — shared costs

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
