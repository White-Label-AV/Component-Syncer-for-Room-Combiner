# Changelog

## 1.1.0.1 — 2026-08-18

Adopts the White Label AV brand header and fixes several problems that
made large designs unusable.

- Sync By Property is now a radio group, defaulting to String. Previously
  the four buttons were independent, so a change could be pushed as
  several properties at once.
- An unconfigured plugin reports Compromised rather than Fault, and no
  longer sets Initializing, which the Status Reporting standard reserves
  to the application.
- Synced Component Name boxes are larger and wrap after four rooms: the
  panel is 720px wide at any room count, against 9400px at 256 rooms.
- Propagation no longer recurses or echoes. Writing a synced value fired
  the target's own handler, which re-broadcast to the whole group. At 256
  rooms one fader move exhausted the Lua stack; once guarded it still cost
  ~66,000 control reads, because the Core dispatches those handlers
  asynchronously. Both are fixed - the same move now costs ~770 reads.
- Re-initialising and wall changes are debounced. Loading a 256-room
  design ran 256 full re-initialises back to back, which is what made the
  status flicker between Initializing and OK.
- Adds a Debug Print property; all diagnostic printing is gated behind it.

Also fixes undefined panel layering, a group box drawn with no stroke
colour, a misspelled ControlType key on NonVolatileMem, and an unstable
Synced Controls ordering that could toggle the wrong control.

Verified on Q-SYS Designer 9.13.1 against a 256-room Room Combiner and
256 gain components.

