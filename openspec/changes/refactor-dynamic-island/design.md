## Context

Today the Dynamic Island is built from two independent `NSPanel`s managed by `DynamicIslandController`:

- `panel` — a small pill/toast positioned *below* the menu bar. Its frame is computed by `islandFrame(for:on:)`, which subtracts the island height and a gap from `safeTopY` (the lower of `visibleFrame.maxY` and the safe-area top). So the island floats in the visible area, not at the notch.
- `menuPanel` — a separate panel created on click, positioned *below* the pill with an 8pt gap, hosting `MenuBarView(surfaceStyle: .dynamicIsland)`.

This produces the reported defects on real hardware:

1. **Wrong position** — the pill is parked under the menu bar instead of straddling the notch, so it reads as a floating widget, not a Dynamic Island.
2. **Camera occlusion** — `toast` content is a plain rounded rectangle centered on the screen midline; on notched machines part of it can fall under the camera housing, and the top-edge math fights the safe area.
3. **Disjointed expansion** — the toast and the menu are two windows that fade in/out independently. There is no continuous "grow from the notch" motion; the recommendation toast and the expanded menu feel unrelated.

`DynamicIslandView` only has `.idle` and `.toast` states; the menu lives entirely in the second panel. The detection helpers (`notchedBuiltInScreen`, `isBuiltIn`, `displayID`) are sound and worth keeping.

The fix is the well-understood notch-app pattern: one top-anchored panel whose visible black shape is drawn and animated in SwiftUI.

## Goals / Non-Goals

**Goals:**
- Anchor a single surface to the physical notch (top edge of the notched built-in screen, above the menu-bar window level).
- Drive notch width/height from the display (`auxiliaryTopLeftArea` / `auxiliaryTopRightArea` and `safeAreaInsets.top`), with a simulated fallback.
- Render collapsed pill, copy notification, and expanded clipboard menu as states of **one** morphing surface — no second window.
- Keep all content below the notch height and reserve the central notch column so nothing is occluded by the camera.
- Tune motion so collapse never overshoots to expose the cutout.
- Reuse `MenuBarView(surfaceStyle: .dynamicIsland)` verbatim as the expanded body.

**Non-Goals:**
- Changing clipboard capture, persistence, or the contents of `MenuBarView`.
- Multi-display "follow the active window" behavior, horizontal drag, or per-display preference (the current feature is single built-in-notch only; keep that scope).
- Reworking the Settings UI beyond what the new geometry requires.
- Any companion/IPC functionality.

## Decisions

### 1. One top-anchored panel instead of two below-notch panels

Replace `panel` + `menuPanel` with a single `NSPanel` pinned to the top of the notched screen:

- Frame: `x = centeredX(on notch)`, `y = screen.frame.maxY - panelHeight`, width up to a cap (e.g. `min(620, screenWidth - 40)`), height large enough for the tallest expanded state.
- `level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)` so it sits over the menu bar at the notch.
- `styleMask: [.borderless, .nonactivatingPanel]`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`.

The panel is a fixed, oversized transparent canvas. What the user *sees* is the SwiftUI black shape inside it. This is the single change that fixes placement and unifies the surfaces.

*Alternative considered:* keep two panels but reposition them at the notch. Rejected — independent fade in/out is the root cause of the "disjointed" complaint; a single morphing surface is required for continuity.

### 2. Notch shape drawn and morphed in SwiftUI

Introduce a `Shape` whose top edge spans `[rect.minX - wing, rect.maxX + wing]` at `y = rect.minY` (screen top), curves down via cubic-bezier shoulders into vertical sides, and closes with continuous-curvature (squircle-ish, `k ≈ 0.62`) bottom corners. Its `animatableData` carries `topExtension` and `bottomRadius`; a fixed `minHeight = notchHeight` clamps the body so spring overshoot can never lift the bottom edge above the notch.

State morph is achieved by animating, not by swapping views:
- collapsed: small width, `topExtension ≈ 3`, `bottomRadius ≈ 12`
- notification / expanded: larger width, `topExtension ≈ 14`, `bottomRadius ≈ 24`

*Alternative considered:* a `RoundedRectangle` capsule that resizes. Rejected — it can't render the "wings tucking into the menu bar beside the notch," which is what sells the notch illusion and keeps the camera column black.

### 3. State model: extend `DynamicIslandState` into a single morphing enum

Evolve the surface state to cover the full lifecycle on one surface:
- `.collapsed` (pill at the notch)
- `.notification(itemTypeIcon:, preview:)` (today's `.toast`, now rendered in the compact bar below the notch)
- `.expanded` (hosts `MenuBarView(surfaceStyle: .dynamicIsland)` below the notch band)

`DynamicIslandController.flash(...)` sets `.notification` then returns to `.collapsed` after the timer; the click handler sets `.expanded`. A single `withAnimation` drives all transitions, so the controller no longer creates/destroys a second window.

Content layout: a compact bar of fixed `notchHeight` with a left wing, a reserved central `Spacer(minLength: notchWidth)`, and a right wing; below it (only when expanded) a divider and the menu body. This guarantees content never enters the camera column.

### 4. Geometry helper

Add a small notch-geometry resolver (e.g. `NotchGeometry`) exposing `hasNotch(_:)`, `notchWidth(for:)`, `notchHeight(for:)`, and the preferred notched built-in screen — built on the existing `isBuiltIn` / `displayID` helpers plus `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` / `safeAreaInsets.top`. Keep the existing `hasNotchedDisplay` / eligibility surface so `ClipthApp` and `SettingsPanelView` keep compiling.

### 5. Motion constants

Centralize springs: open `spring(response: 0.42, dampingFraction: 0.82)` (slight bounce), close `spring(response: 0.38, dampingFraction: 1.0)` (critically damped — no rebound), notification pop `spring(response: 0.3, dampingFraction: 0.65)`, micro `easeOut(0.12)`. Respect Reduce Motion.

### 6. Hosting hardening

Use a `KeyablePanel` subclass (`canBecomeKey = true`) and an `NSHostingView` subclass that (a) calls `window?.makeKey()` on `mouseDown` and returns `true` from `acceptsFirstMouse`, and (b) defers `needsUpdateConstraints` / `needsLayout` to the next run-loop turn to avoid the AppKit re-entrancy crash when SwiftUI invalidates the graph mid display-cycle. Outside-click and Escape collapse to `.collapsed` via the existing monitor approach.

## Risks / Trade-offs

- **Spring overshoot reveals the cutout** → Fixed non-animated `minHeight = notchHeight` in the shape + critically-damped close spring; verified by collapsing repeatedly on a notched Mac.
- **Panel above menu-bar level covers menu-bar items near the notch** → The panel is only as wide as the surface and centered on the (empty) notch; menu-bar items live in the side auxiliary areas, so they stay clickable. Validate the collapsed width doesn't extend over real menu items.
- **First-click swallowed by non-activating panel** → `acceptsFirstMouse` + `makeKey()` on `mouseDown`; covered by the "first click is actionable" scenario.
- **Hosting re-entrancy crash** under rapid state changes → deferred constraint/layout updates in the hosting subclass.
- **Non-notched built-in display** (simulated notch) could look odd → keep current gating; only show where already permitted, and the simulated width is bounded.
- **Regression in "island replaces menu bar" eligibility** in `ClipthApp`/`SettingsPanelView` → preserve the public `hasNotchedDisplay`/`isEnabled` API shape so callers are unaffected.

## Migration Plan

1. Add `NotchGeometry` + shared notch animation/shape definitions (no behavior change yet).
2. Rewrite `DynamicIslandView` to the single morphing surface with `.collapsed` / `.notification` / `.expanded` states and the new shape; embed `MenuBarView(surfaceStyle: .dynamicIsland)` for expanded.
3. Rewrite `DynamicIslandController` to one top-anchored panel; map `flash(...)` → `.notification`, click → `.expanded`; remove `menuPanel` and its positioning/dismiss plumbing (fold dismiss handling into the single panel).
4. Keep `isEnabled`, `setEnabled`, `hasNotchedDisplay`, and `flash(itemIcon:preview:)` signatures stable so `ClipthApp`, `ClipboardViewModel`, and `SettingsPanelView` need no changes (or minimal ones).
5. Per project rule, build then launch the app on a notched Mac and verify each spec scenario.

**Rollback:** the change is contained to the two Dynamic Island files plus the new helpers; reverting the commit restores the dual-panel behavior with no data or settings migration.

## Open Questions

- Should the expanded menu auto-open on hover (like a true Dynamic Island) in addition to click, or remain click-only to match current behavior? Default: keep click-only to minimize behavior change; revisit if it feels inert.
- Collapsed pill width: match the physical notch width exactly, or a touch narrower (e.g. `notchWidth - 20`) so the wings read as distinct? Default: slightly narrower, tune visually on device.
