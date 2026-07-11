# Tech Debt Ledger

Every `// ponytail:` comment in the codebase is a deliberate shortcut with a known limit. At each phase exit, the orchestrator runs `grep -rn "ponytail:" --include="*.swift"` and harvests findings into this file so "later" doesn't become "never."

Format:
```
## TD{N} — {short title}
**Where:** file:line
**Shortcut:** what we did instead of the "proper" solution
**Known limit:** when this breaks (scale, latency, feature)
**Upgrade path:** what the full solution looks like
**Owner phase:** which phase should address it (or "post-MVP")
```

---

## TD1 — SpaceMarker has no accessibility label
**Where:** thrdspaces/thrdspaces/Features/Discover/DiscoverView.swift:150 (call site with `.onTapGesture`) and :174 (SpaceMarker body)
**Shortcut:** T1 relocated the mock DiscoverView verbatim per task constraints; the pre-existing mock never had accessibility on the map markers. `onTapGesture` confers no button trait or label, so VoiceOver can't discover or name the markers.
**Known limit:** violates the non-negotiable guard "Accessibility labels on every interactive element (App Store rejection risk)". Must not survive into any submitted build.
**Upgrade path:** in the T9 extraction, give SpaceMarker `.accessibilityLabel("\(space.name), \(space.category.rawValue)")` + `.accessibilityAddTraits(.isButton)` (or replace the tap gesture with a Button).
**Owner phase:** Phase 1, task T9 (added to T9 exit criteria).

## TD2 — Bengaluru default coordinate duplicated in DiscoverView
**Where:** thrdspaces/thrdspaces/Features/Discover/DiscoverView.swift:114 and :127
**Shortcut:** mock file hardcodes (12.9716, 77.5946) in both the camera position and the load() path, no shared constant.
**Known limit:** changing launch city needs two coordinated edits; miss one and the map pans to a different place than the data loads for.
**Upgrade path:** single `static let defaultCity` constant during the T9 extraction; Phase 2 replaces it with real user location.
**Owner phase:** Phase 1, task T9 (added to T9 exit criteria).

## TD3 — Four identical placeholder tab views
**Where:** thrdspaces/thrdspaces/Features/{Communities,Create,Messages,Profile}/*PlaceholderView.swift
**Shortcut:** T1 created four byte-identical-modulo-title placeholder views instead of one parameterized `PlaceholderView(title:)`.
**Known limit:** styling changes need 4 coordinated edits. Cosmetic only; per CLAUDE.md style rules this does not justify a fix task against working code.
**Upgrade path:** each placeholder is deleted wholesale when its real feature lands (Phases 2–4), so the debt self-liquidates; consolidate only if a fifth placeholder ever appears.
**Owner phase:** self-liquidating; no action.

## TD4 — Terracotta primary fails WCAG AA contrast with white text
**Where:** thrdspaces/thrdspaces/Core/DesignSystem/Theme.swift:34 (terracotta light ≈3.5:1 vs white; dark variant lower)
**Shortcut:** T2 seeded token values verbatim from the approved mock, as its task required.
**Known limit:** ThrdButton primary and selected chips render normal-size white text below the 4.5:1 AA threshold — an accessibility-audit finding waiting to happen (App Store 4.0 design/a11y risk area).
**Upgrade path:** darken terracotta light to ~(0.78, 0.38, 0.26) or bump button text to bold ≥18pt (large-text threshold is 3:1); verify both modes with a contrast checker.
**Owner phase:** Phase 1, T10 phase-exit accessibility pass (design decision, needs one user sign-off on the adjusted hue).
