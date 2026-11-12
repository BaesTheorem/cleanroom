# Design

Chosen 2026-11-12. Direction: **Readout**. The app reads as a lab instrument: a
black panel, monospace readouts, and one status light.

Reference: [CIPHER, on-chain wallet terminal](https://dribbble.com/shots/27449286-CIPHER-on-chain-wallet-terminal)
by Raja on Dribbble. Taken from it: the black ground, capital monospace legends
over values, hairline panels, corner brackets, and tick-mark bars.

## Type

- **JetBrains Mono** for legends, readouts, file names, field names and buttons.
  Legends are capitals at 10.5 pt with 1.4 pt tracking.
- **Inter** for sentences.

## Color

Five tokens, in `ios/Shared/Sources/Theme.swift`:

| Token | Value | Use |
| --- | --- | --- |
| `void` | `#000000` | the ground |
| `panel` | `#0B0C0D` | thumbnail wells |
| `rule` | `#2A2D31` | hairlines, unlit ticks |
| `ink` | `#F2F3F5` | text, primary buttons |
| `signal` | `#45E08A` | verified clean |

`dim` and `faint` are `ink` at 58% and 34% opacity. They are derived values and
not a sixth and seventh color.

`signal` has one meaning: the file passed its checks. It appears on the status
light, the word CLEAN, a passed check, a full progress bar, and the button that
shares verified files. Nothing else is green.

A kind of leak (LOCATION, IDENTITY, DEVICE) is an inverse label, ink ground
with black text. A failure is the same inverse label. There is no red.

## Layout

- Spacing on an 8-point scale (4 for the tightest pairs).
- Border radius 0, everywhere.
- No gradients and no shadows.
- Lines are 1 point.
- Touch targets are at least 44 points. Full-width buttons are 48.
- Dark only. The app does not have a light appearance.

## Icons

There is no icon font. Marks are type: `[ INFO ]`, `[ CLOSE ]`, `[X]`, `+`, and
the arrow that JetBrains Mono draws for `->`. The app icon is four corner
brackets and the status light, drawn by `tools/make-icon.swift`.
