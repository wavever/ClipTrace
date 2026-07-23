## 1. Notch geometry & shared motion

- [x] 1.1 Add a `NotchGeometry` helper exposing `preferredScreen`, `hasNotch(_:)`, `notchWidth(for:)`, `notchHeight(for:)`, and `isBuiltIn(_:)` / `displayID` (moved out of `DynamicIslandController`).
- [x] 1.2 Compute `notchWidth` as `screen.frame.width - auxiliaryTopLeftArea.width - auxiliaryTopRightArea.width`, with a bounded simulated width fallback when auxiliary areas are absent.
- [x] 1.3 Compute `notchHeight` from `screen.safeAreaInsets.top`, falling back to menu-bar height when zero.
- [x] 1.4 Add a shared `NotchAnimation` enum (open / close / pop) honoring Reduce Motion, with close critically damped (dampingFraction 1.0).
- [x] 1.5 Preserve the public `DynamicIslandController.hasNotchedDisplay` (delegating to `NotchGeometry`) so `ClipthApp` and `SettingsPanelView` are unaffected.

## 2. Morphing notch surface (DynamicIslandView)

- [x] 2.1 Background is a single `UnevenRoundedRectangle` (square top flush to the screen edge merging into the notch, rounded bottom) driven by per-state width / height / bottom-radius — chosen over a bezier "wings" shape because the screen-centered, frame-clipped panel makes the flush top cleaner and more reliable. (Spec scenario updated to match.)
- [x] 2.2 Replace `DynamicIslandState` with `.collapsed`, `.notification(itemTypeIcon:, preview:)`, `.expanded`; map width/height/radius per state.
- [x] 2.3 Keep the entire notch-height band empty (`Color.clear`, tap target only) so the camera column is never occupied in any state; all content renders strictly below it.
- [x] 2.4 Render the `.notification` body below the band as an icon + "copied" + preview row styled for the black surface (white/accent), not a centered paper rectangle.
- [x] 2.5 Render `.expanded` content below the band: divider + `MenuBarView(surfaceStyle: .dynamicIsland)` built once with the existing environment/model wiring.
- [x] 2.6 Drive all state changes via an `IslandModel` `ObservableObject` so the controller's `withAnimation(NotchAnimation…)` morphs the single surface instead of swapping views.

## 3. Single top-anchored panel (DynamicIslandController)

- [x] 3.1 Add a `NotchPanel` (canBecomeKey) and a `NotchHostingView` subclass that calls `makeKey()` on `mouseDown`, returns `true` from `acceptsFirstMouse`, and defers `needsUpdateConstraints` / `needsLayout` to the next run-loop turn.
- [x] 3.2 Create one panel pinned to `y = screen.frame.maxY - panelHeight`, centered on the notch, at `CGWindowLevelForKey(.mainMenuWindow) + 2`, transparent, joining all spaces + full-screen aux.
- [x] 3.3 Remove `menuPanel`, `menuHostingController`, and `positionMenuPanel` / `menuPanelSize` / `showMenuPanel`; fold the expanded menu into the single surface.
- [x] 3.4 Map `flash(itemIcon:preview:)` to `.notification` (auto-return to `.collapsed` after 2s, skipped while expanded) and the band tap to toggle `.expanded`.
- [x] 3.5 Keep outside-click, Escape, and resign-key dismissal collapsing to `.collapsed`; monitors installed only while expanded.
- [x] 3.6 Re-anchor on `didChangeScreenParametersNotification`; hide when the built-in notch is unavailable; re-show when it returns.

## 4. Integration & verification

- [x] 4.1 `ClipboardViewModel` `flash(...)` call sites and `ClipthApp` enable/anchor wiring compile unchanged (stable `flash` / `setEnabled` / `isEnabled` / `hasNotchedDisplay` API) — confirmed by a clean Debug build.
- [x] 4.2 `SettingsPanelView` notch gating + "island replaces menu bar" eligibility compile against `NotchGeometry` via `hasNotchedDisplay` — confirmed by a clean Debug build.
- [x] 4.3 Build the app (BUILD SUCCEEDED), then launch it (per project rule).
- [ ] 4.4 Verify each spec scenario on device: notch-anchored placement, content clear of camera, notification→expanded morph continuity, collapse with no cutout exposure, first-click actionable, dismiss on outside/Escape, stable across spaces/full screen.
