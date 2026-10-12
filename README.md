# Pinna

A tiny macOS menu bar app: take a screenshot, and it floats on top of everything and is already on your clipboard.

## Build

```sh
./build.sh                         # → build/Pinna.app
cp -R build/Pinna.app /Applications/
```

Requires macOS 14+ and Xcode (or the Swift toolchain).

## Use

Press **⇧⌘2** (or click the pin icon in the menu bar → Capture & Pin).

- Drag to select an area, or press **Space** to pick a window. **Esc** cancels.
- The screenshot is copied to the clipboard and pinned on screen, where you selected it.

A pin stays on the desktop it was taken on, and floats above other windows until you turn off the switch in its top-right corner.

On a pinned screenshot:

| Action | |
|---|---|
| Move | Drag the screenshot or its title bar |
| Resize | Drag an edge or corner (keeps proportions) |
| Zoom | Scroll wheel / pinch, or ⌘= ⌘- ⌘0 |
| Fit to screen | Green button |
| Minimize | Yellow button |
| Keep on top | Switch in the top-right corner |
| Copy again | ⌘C |
| Save as PNG | ⌘S |
| Close | Red button, Esc, ⌘W, or double-click |
| More | Right-click |

Close every pin at once from the menu bar icon.

## Permissions

The first capture asks for **Screen Recording** permission. Turn Pinna on in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen Pinna.

`build.sh` signs ad-hoc by default, so macOS treats each rebuild as a new app and asks again. To avoid that, sign with your own certificate: `SIGN_IDENTITY="Apple Development: …" ./build.sh`.
