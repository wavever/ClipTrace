## ADDED Requirements

### Requirement: Notch-anchored placement

The Dynamic Island surface SHALL be anchored to the top edge of the notched built-in display, centered horizontally on the physical notch, and rendered above the menu-bar window level. It SHALL NOT be offset downward into the visible frame below the menu bar.

#### Scenario: Pinned to the notch on a notched built-in display

- **WHEN** the feature is enabled and the built-in display has a notch
- **THEN** the surface's top edge aligns with the top edge of the screen (`screen.frame.maxY`)
- **AND** the surface is horizontally centered on the physical notch
- **AND** the surface renders above the menu bar so it visually merges with the notch

#### Scenario: Excluded on displays without a built-in notch

- **WHEN** no built-in display reports a notch
- **THEN** the surface is not shown on external or non-notched displays
- **AND** existing notch-eligibility gating (including the "island replaces menu bar" logic) is preserved

#### Scenario: Re-anchors on display configuration change

- **WHEN** screen parameters change (resolution, display attach/detach, becoming/ceasing to be notched)
- **THEN** the surface re-resolves the target screen and re-positions to the current notch
- **AND** it is hidden if the built-in notch is no longer available

### Requirement: Notch geometry derived from the display

The surface SHALL derive its notch geometry from the display: notch width from the menu-bar auxiliary areas flanking the cutout, and notch height from the screen's top safe-area inset. A simulated notch SHALL be used only where the feature is already permitted on a non-notched built-in display, so geometry is always well-defined.

#### Scenario: Real notch geometry

- **WHEN** the target display exposes left/right auxiliary top areas
- **THEN** notch width is computed as screen width minus the combined width of those two areas
- **AND** notch height is taken from the screen's top safe-area inset

#### Scenario: Simulated notch fallback

- **WHEN** the target display does not expose auxiliary top areas
- **THEN** a simulated notch width that scales with screen width (within sensible bounds) is used
- **AND** notch height falls back to the menu-bar height

### Requirement: Content stays clear of the camera area

Content SHALL never be laid out within the physical notch column. The central notch-width region SHALL be reserved as empty space, and all textual or icon content SHALL be positioned below the notch height.

#### Scenario: Compact state reserves the notch column

- **WHEN** the surface is collapsed or showing the copy notification in the compact bar
- **THEN** left- and right-side content is separated by a reserved central gap at least as wide as the notch
- **AND** no content overlaps the camera housing

#### Scenario: Expanded content sits below the notch

- **WHEN** the surface is expanded
- **THEN** the expanded clipboard content begins below the notch-height band
- **AND** the area directly under the camera remains visually part of the black notch shell

### Requirement: Single morphing surface

The collapsed pill, the copy notification, and the expanded clipboard menu SHALL be states of one continuous surface that morphs in place. The implementation SHALL NOT use separate windows/panels that independently appear and disappear for the notification versus the menu.

#### Scenario: Notification grows from the notch

- **WHEN** a new clipboard item is recorded and the surface is collapsed
- **THEN** the same surface expands into the copy notification without a second panel appearing
- **AND** it collapses back to the pill after the notification interval

#### Scenario: Expanded menu grows from the same surface

- **WHEN** the user activates the surface (e.g. click or hover to expand)
- **THEN** the expanded clipboard menu emerges from the same surface anchored at the notch
- **AND** transitioning from notification to expanded menu does not swap to a different window

#### Scenario: Background is a single notch shape

- **WHEN** any state is rendered
- **THEN** the background is one continuous black shape whose top edge is flush with the screen's top edge (square top corners merging into the physical notch) and whose body has rounded bottom corners
- **AND** state changes animate the shape's width, height, and bottom corner radius rather than replacing the surface

### Requirement: Expand and collapse motion integrity

State transitions SHALL be animated with spring motion tuned so the surface never overshoots in a way that exposes the camera cutout. The collapse animation SHALL be critically damped (no rebound), and the surface SHALL enforce a fixed minimum height equal to the notch height that is not subject to animation overshoot.

#### Scenario: Collapse does not expose the notch

- **WHEN** the surface collapses from expanded or notification back to the pill
- **THEN** the bottom edge settles without rebounding above the notch height
- **AND** the camera cutout is never revealed during the transition

#### Scenario: Open feels responsive with slight bounce

- **WHEN** the surface expands
- **THEN** it uses a lightly under-damped spring for a responsive, slightly bouncy feel
- **AND** width and corner-radius changes animate together so growth reads as one motion

### Requirement: Notch panel interaction and window behavior

The surface SHALL use a borderless, non-activating, transparent panel that can become key for interaction, accepts a first click without a prior focus step, and joins all spaces (including over full-screen apps). It SHALL avoid AppKit hosting re-entrancy when its SwiftUI content updates.

#### Scenario: First click is actionable

- **WHEN** the user clicks the surface while another app is focused
- **THEN** the click is delivered to the surface's controls without requiring a separate activating click

#### Scenario: Dismiss on outside interaction

- **WHEN** the surface is expanded and the user clicks outside it (or presses Escape)
- **THEN** the surface collapses back to the pill

#### Scenario: Stable across spaces and full screen

- **WHEN** the user switches spaces or enters a full-screen app
- **THEN** the surface remains reachable at the notch (subject to existing visibility settings)
- **AND** SwiftUI content updates do not trigger hosting-view constraint/layout re-entrancy crashes
