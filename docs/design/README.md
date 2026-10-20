# Reference screens

These are the screens from the design canvas, all at 1920x1080. Build to them.

| File | Screen |
| --- | --- |
| `Main.dc.html` | Home. The same file also holds the sidebar, confirm, still-open, desktop and off states, picked by its `view` prop |
| `Menu.dc.html` | Sidebar open over Home |
| `Power.dc.html` | Power-off confirm |
| `Settings.dc.html` | Settings, Apps section |
| `StillOpen.dc.html` | Return to Bosca Mór, apps still open |

How to read them:

- The markup and its inline `style` attributes carry the layout and tokens.
- `{{name}}` holes are filled by `renderVals()` in the `<script type="text/x-dc">` block at the bottom. Computed styles (focused tile, ring, menu highlight) are built there as strings.
- `Menu`, `Power` and `StillOpen` just mount `Main` with a different `view`.
- These are design references, not code to port. Where a value here disagrees with SPEC.md, SPEC.md wins.
- The app icons are placeholder line glyphs, not the real logos.
