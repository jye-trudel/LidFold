# LidFold

A tiny macOS menu-bar app that folds the desktop away as you close your MacBook's lid, in the
style of a folding phone:

- The desktop frosts over like glass, colors staying vivid.
- The far (top) edge sinks into shadow, and the screen dissolves to black as the lid shuts.
- The desktop shrinks into a rounded card on black and leans back, hinged at its bottom edge,
  like a pane of glass tipping away from you.

Opening the lid plays it in reverse. The effect follows the real lid angle continuously: stop
halfway and it stops halfway.

Native Swift, AppKit and Metal with no dependencies. Idle, it uses about 0.2% CPU and 10 MB of RAM.

## Build

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't needed.

```sh
./build.sh            # → dist/LidFold.app (release build, stripped, ad-hoc signed)
open dist/LidFold.app
```

A laptop icon appears in the menu bar with **Enabled**, **Launch at Login** and **Quit**.

## Signing and Screen Recording

The glass card needs real screen pixels, so LidFold asks once for **Screen Recording**
permission:

- It takes **one** still image per display when a close starts. That image stays in memory for
  the animation (and through sleep, for the un-blur on wake), then it is freed.
- It never records continuously, and nothing is saved or sent anywhere.
- If you deny the permission, LidFold uses the frosted-glass effect instead.

The menu item **Glass Card Effect** shows the state, and turns the effect on or off.

macOS ties that permission to the app's code signature. Create a stable local signing identity
once, so the permission survives rebuilds:

```sh
scripts/make-signing-identity.sh   # creates ~/Library/Application Support/LidFold/lidfold.keychain-db; your login keychain is not touched
./build.sh                         # now signs with "LidFold Local Signing"
```

Without it, builds are ad-hoc signed and you must grant the permission again after each rebuild.

## Install

```sh
pkill -x LidFold; rm -rf /Applications/LidFold.app
cp -R dist/LidFold.app /Applications/
open /Applications/LidFold.app
```

Turn on **Launch at Login** *after* moving the app to /Applications. It uses `SMAppService`,
which registers the app at its current path. If macOS asks for approval, allow LidFold under
System Settings → General → Login Items.

## Tuning

Every setting lives in the `local.lidfold` defaults domain. Changes take effect the next time
the lid moves, with no restart needed:

```sh
defaults write local.lidfold deadZone    -float 12   # degrees of closing from your resting angle before the effect starts
defaults read  local.lidfold restAngle               # the resting angle LidFold has learned (effect is mapped from here)
defaults write local.lidfold openAngle   -float 105  # fallback resting angle until one is learned
defaults write local.lidfold closedAngle -float 20   # at or below this: fully dissolved (default 20°)
defaults write local.lidfold wakeFadeMs  -float 900  # opening animation on wake when the lid is already open
defaults write local.lidfold wakeDelayMs -float 150  # wait after the display wakes before opening (backlight)
defaults write local.lidfold settleSeconds -float 1  # stillness before dropping back to idle polling
defaults write local.lidfold idleHz      -float 2    # idle poll rate, lid well above openAngle
defaults write local.lidfold nearIdleHz  -float 4    # idle poll rate within 25° of openAngle (catches a close early)
defaults write local.lidfold interpMs    -float 110  # glide time per sensor sample: lower = less lag, choppier
defaults write local.lidfold softenMs    -float 50   # spring rounding speed changes: higher = softer, more lag
defaults write local.lidfold predictMs   -float 60   # aim this far ahead of the lid (0 = off)
defaults write local.lidfold predictCap  -float 3    # max prediction in degrees = max overshoot when the lid stops
defaults write local.lidfold trace       -bool true  # log each lid movement to ~/Library/Logs/LidFold-trace.csv
defaults write local.lidfold allScreens  -bool true  # also cover external displays (default: built-in only)
defaults write local.lidfold style classic           # duo (default) | classic | eclipse (frosted styles)
defaults write local.lidfold frostRadius -float 36  # frost blur radius at full fold, points
defaults write local.lidfold snapshotScale -float 1  # snapshot resolution, pixels per point (1 = half Retina)
defaults write local.lidfold cardTilt    -float 30   # lean-back at full fold, degrees
defaults write local.lidfold cardScale   -float 0.88 # card size at full fold (1 = full screen)
defaults write local.lidfold cardCorner  -float 26   # card corner radius at full fold, points
defaults write local.lidfold cardPerspective -float 1300  # perspective distance (m34 = −1/this); lower = stronger
defaults write local.lidfold cardLift    -float 0.35 # how far the card floats off the bottom edge
defaults delete local.lidfold                        # reset everything
```

The effect is mapped from the angle your lid actually rests at, which LidFold learns: closing
starts `deadZone` degrees below it, and opening reaches full clarity back at it. If you move the
screen by up to 15° and leave it there, that becomes the new resting angle and any slight frost
fades away. Bigger stops, like halfway, hold their state. To see the current angle, run `Tools/lidprobe`.

To preview the look at a fixed fold amount (0…1) for 3 seconds:

```sh
dist/LidFold.app/Contents/MacOS/LidFold --preview 0.5
```

To play a full close and open (about 4.5 s) without touching the lid:

```sh
dist/LidFold.app/Contents/MacOS/LidFold --demo
```

The glass look is tuned in `DuoRenderer.uniforms(progress:)` and the `fold` kernel in
`Sources/LidFold/DuoRenderer.swift`:

- **ease-in:** e = progress^1.1, shared with the card tilt (visible from the first degrees through the end of an opening)
- **frost:** blur radius up to `frostRadius`, plus a slight saturation boost and light haze
- **shadow:** darkening toward the far (top) edge of the card
- **dissolve:** the final fade to black over the last 15%

The frosted styles are in `OverlayWindow.render(_:)` in `Sources/LidFold/FoldOverlay.swift`.

## Which Macs have the sensor?

The lid-angle sensor is a hidden HID device: Apple 05AC:8104, usage page 0x20 (Sensor), usage
0x8A (Orientation). It reports degrees in report ID 1, where 0 = closed and about 180 = flat.

- **Confirmed:** MacBook Pro 14″ M3 Pro (Mac15,6, macOS 26), the machine this was built on.
- **Community reports:** Apple-silicon MacBook Air and Pro models from the M2 generation onward
  generally expose it. M1 and Intel MacBooks generally do not (some 2019 16″ Intel units reportedly do).

Check your own Mac:

```sh
cd Tools && swiftc -O lidprobe.swift -o lidprobe && ./lidprobe
```

It prints the angle as you move the lid, plus how many input reports the sensor pushes per second.

**No sensor?** LidFold still runs, as a fallback. On sleep the screen goes dark, and on wake it
eases back in over 0.6 s. The menu shows "No lid sensor — sleep/wake fade only".

## How it stays light

| State | What runs |
|---|---|
| Lid still (idle) | No windows exist. The sensor's own pushed input reports, which arrive about 1/s through the run loop, act as a free movement detector, backed by a slow timer poll. |
| Lid moving | `CADisplayLink` at 120 Hz. The sensor is read at about 70 Hz, and progress drives the layers inside a `CATransaction` with actions disabled. |
| About 1 s still | The display link stops and the overlay windows are destroyed if clear. |
| Clamshell (lid shut, external display) | The built-in screen is gone, so polling stops completely and nothing covers your monitors. |

**Smoothness.** The sensor only produces a new value about every 100 ms, in jumps of up to 8°.
Following it directly gives a visible 10 Hz staircase. LidFold reconstructs the motion instead:

- Each new sample starts a constant-speed glide to it, lasting about 20% longer than the gap
  between samples (110 ms minimum), so steady motion never stalls.
- A critically damped spring rounds off the speed changes.
- It aims about 60 ms ahead along the lid's recent speed (capped at 3°), and drops that lead as
  soon as the lid stops. The effect runs about 50 ms behind the lid.
- Above `openAngle` nothing is visible, so glides never spend time travelling through that range.

**Push detection.** Whether the sensor pushes reports *while moving* is learned automatically:

- During each real movement of 15° or more, LidFold counts pushed reports.
- If they arrive at 8/s or more, it sets `pushOnChange = 1` and drops idle polling to a 5 s
  safety net. Idle CPU then falls from about 0.15% to about 0.03%.
- `defaults read local.lidfold pushOnChange` shows what it learned: -1 unknown, 0 no, 1 yes.

**Window level.** The overlay sits at `.screenSaver` (level 1000):

- That is above the menu bar (24), Dock (20) and pop-up menus (101), so the whole desktop folds.
- It is below the system shielding window, so it can never hide the lock screen or password prompt.
- `.canJoinAllSpaces` and `.fullScreenAuxiliary` put it on every Space, including over full-screen apps.
- `ignoresMouseEvents` makes it click-through.

**Frosted card.** On a close, ScreenCaptureKit grabs a single frame per display, with LidFold's
own windows and the cursor excluded. The frame goes to the GPU once, and a compute kernel builds
its mip chain. Each frame, a second compute kernel blurs it:

- 32 Gaussian-weighted taps in a disc pattern, rotated per pixel, read from the mip level that
  matches the radius. The frost is smooth and even, with no streaks or blocks, at any strength.
- A GPU frame takes about 0.4 ms (0.5 ms for the slowest 5%).

On memory: Metal reserves a fixed buffer of about 70 MB in any process the first time it does
GPU work, whatever the frame size. A fold therefore peaks around 120 MB. Everything (snapshot,
GPU objects, buffers) is released when the lid settles, and idle memory returns to about 10 MB.

**Lean-back card.** The frosted frame sits in one container layer that carries a
`CATransform3D`: perspective (m34), a rotation about X, and a scale. The anchor point is
bottom-centre, so it hinges on the bottom edge. The layers aren't geometry-flipped, so y = 0 is
the bottom of the screen. The code is in `Sources/LidFold/Card.swift`.

- Tilt, scale and corner radius follow the same ease-in (progress^1.1) as the frost.
- If the snapshot arrives after the close has started, the tilt eases in over 150 ms instead of
  popping.
- The black backdrop is the parent layer's background colour, not a sibling layer. Core
  Animation depth-tests 3D sibling layers, so a sibling backdrop would hide the card once it
  leans back.
- Each GPU frame is presented in the same Core Animation commit as the transform
  (`presentsWithTransaction`), so the image and the tilt never drift a frame apart.
- Measured: a frame takes about 0.5 ms (0.7 ms for the slowest 5%), about one frame per fold
  exceeds the 8.3 ms budget at 120 Hz, and memory returns to about 11 MB afterwards.
- The frosted fallback doesn't lean back. It blurs the live desktop in place and can't move it.

**Frosted fallback.** The frosted blur needs no Screen Recording permission. An `NSVisualEffectView` with
behind-window blending asks WindowServer to blur whatever is underneath. Its alpha is driven
from progress. The one trade-off is that it fades in at a fixed blur strength instead of ramping
the radius, which the darkening gradient largely hides. There is deliberately no scale or
perspective transform: without capturing the screen, shrinking the overlay would expose the
sharp desktop around its edges.

**Sleep and wake.**

- On `willSleep` / `screensDidSleep`, the overlay is forced to fully dissolved and flushed to
  the display before it turns off.
- On wake, the panel comes on already black. LidFold waits for the *display* to wake
  (`screensDidWake`, not just the system), plus `wakeDelayMs` for the backlight, so the opening
  is actually visible. A fallback starts it after 1.5 s if that notification never arrives.
- If the pre-sleep snapshot was dropped (displays reconfigure on wake), it re-captures the desktop
  first, waiting up to 0.5 s. Then it:
  - follows the angle if the lid is still opening;
  - plays a `wakeFadeMs` ease-in-out opening if the lid is already open: the card swings upright,
    grows and sharpens;
  - fades out anyway if the sensor can't be read within 2 s. The screen is never left covered.
- **Password on wake:** public window levels can't go above loginwindow, so the cover uses
  private SkyLight calls, after github.com/Lakr233/SkyLightWindow (MIT). LidFold creates one space
  with an absolute level of 400, just above the screen-lock level of 300, shows it, and moves the
  cover window into it. That window is shown first, then moved; moving a window that isn't on
  screen yet doesn't stick. The code is in `Sources/LidFold/SkyLight.swift`.
  - **The locked opening:** at a locked wake, LidFold takes one ScreenCaptureKit capture of the
    display, with its own cover excluded. That captures the live lock screen with the current
    time, and on this Mac it took 86 ms. The capture is at full Retina resolution, so the card's
    final frame is pixel-identical to the live lock screen (a half-resolution card made the hand-off
    visibly jump in sharpness). The capture becomes a glass card in the space and plays
    the reverse of the close: small, tilted back and frosted on black, then upright, full-screen
    and sharp. It then cross-fades into the real lock screen over 100 ms, and everything is removed.
  - **Closing from the lock screen:** a close that starts while locked builds the same glass card
    above the lock screen and captures the live lock screen at full resolution. Its first frame
    matches the real lock screen exactly; it then tilts back, frosts and dissolves to black as
    the lid closes. Reopening before sleep plays it back and cross-fades into the lock screen.
  - **Never the desktop:** the desktop snapshot is freed at sleep and whenever the Mac locks. The
    lock card only accepts an image captured while the session reports locked. If the capture
    fails or comes back black, the cover plays the frosted live blur instead. If you unlock
    mid-animation, the card is removed at once.
  - **Safety:** the cover is click-through and can't become key or main, so Touch ID and the
    password field work normally. If it's still up 2 s after the display wakes, it's removed.
  - **Graceful failure:** every SkyLight symbol is loaded with `dlsym` and checked. If any is
    missing in a future macOS, the lock-screen effect is skipped and nothing crashes.
  - **Tuning:** `defaults write local.lidfold lockSpaceLevel -int 400` sets the space level.
  - If the Mac wakes unlocked, the cover is removed and the glass card opens instead.

## License

MIT, see [LICENSE](LICENSE).

The lock-screen cover's SkyLight calls (`Sources/LidFold/SkyLight.swift`) follow the approach in
[Lakr233/SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) (MIT). SkyLight is a private
macOS framework: this part may stop working in a future macOS release, in which case LidFold
simply skips the lock-screen effect.
