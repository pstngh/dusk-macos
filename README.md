# dusk-macos

A small CLI for Apple Silicon Macs with external displays (SDR). It does two things:

- **No dithering.** It stops temporal dithering, both the GPU's and the monitor's own (FRC).
- **A warm screen at night.** A warm tint and dimming follow the sun in Montreal: a fade to Evening at sunset, to pure red before 9 PM, and back to Day by sunrise.

dusk is the successor of `nodither`; `dusk install` replaces it.

## No dithering

You need both of these:

1. **GPU dithering off.** macOS renders into a 10-bit framebuffer, and the display coprocessor (DCP) temporally dithers it down to the link's bit depth. dusk sets `enableDither = No` on each external display pipe.
2. **An 8-bit RGB link (full range).** On a 10-bit link, monitors whose panel is really 8-bit + FRC fake the extra 2 bits by flickering between neighbouring shades. That is temporal dithering too, done by the monitor. With an 8-bit link it has nothing to dither. This also replaces YCbCr / limited-range links with RGB full range.

The 8-bit link alone just moves the dithering from the monitor to the GPU. Turning GPU dithering off alone leaves the monitor's FRC in place. With both, the Mac rounds to 8 bits and the monitor displays them as-is. Smooth gradients can show slightly more banding; that is the expected trade-off.

## Warm tint and dimming

Three looks, with these defaults:

| | Warmth | Brightness |
|---|---|---|
| Day | 4000 K | 100% |
| Evening | 2700 K | 85% |
| Night | 0 K (pure red) | 70% |

The schedule, for Montreal (45.50° N, 73.57° W) in local time:

- **Day → Evening:** a 30-minute fade centred on sunset.
- **Evening → Night:** fully red at sunset + ¾ of the time left until 9 PM, so always before 9 PM, after a 30-minute fade. In summer the two fades overlap and merge into one.
- **Night → Evening:** a 30-minute fade when the last quarter of the time from sunset to sunrise starts, around 3–4 AM.
- **Evening → Day:** a 30-minute fade that ends at sunrise.

| | Sunset | Fully red | Red until | Sunrise |
|---|---|---|---|---|
| Jun 21 | 20:46 | 20:56 | 03:00 | 05:05 |
| Oct 11 | 18:17 | 20:19 | 03:53 | 07:05 |
| Dec 21 | 16:13 | 19:48 | 03:42 | 07:31 |

Fades follow the clock, so after sleep the screen goes straight to where the fade should be. A fade updates the screen each time a colour channel has moved 2 of its 256 levels, which is too small to see.

The menu bar icon (sun, sunset or moon) opens a menu with:

- a warmth and a brightness slider for each look, previewed live while you drag
- Reset to defaults, Pause for 1 hour, Night until sunrise
- Warm tint & dimming on/off, No dithering on/off
- tonight's sunset, red and sunrise times
- Hide icon (until the next login; dimming keeps working)

## Install

Prebuilt binary from the [latest release](https://github.com/pstngh/dusk-macos/releases/latest) (arm64, macOS 13 or later):

```bash
curl -L https://github.com/pstngh/dusk-macos/releases/latest/download/dusk-macos-arm64.tar.gz | tar xz
./dusk install
```

The binary is ad-hoc signed, not notarized. Downloads made with `curl` run as-is; if you download the archive in a browser, macOS blocks the binary until you run `xattr -d com.apple.quarantine dusk`.

Or build from source (needs the Xcode Command Line Tools):

```bash
git clone https://github.com/pstngh/dusk-macos
cd dusk-macos
swift build -c release
.build/release/dusk install
```

Either way, `install` copies the binary to `~/.local/bin/dusk` and loads three LaunchAgents from `~/Library/LaunchAgents`. No root needed.

| LaunchAgent | Runs | When |
|---|---|---|
| `local.dusk.display` | `dusk agent` | At login and whenever a monitor attaches; applies no dithering, then exits |
| `local.dusk.tint` | `dusk tick` | At login, on the hour 2–7 AM and 3–8 PM, after wake, and on setting changes; runs any fade that is due, then exits |
| `local.dusk.menu` | `dusk menu` | Always; holds the dimming and shows the menu bar icon (`install --no-menu` hides the icon) |

`install` also removes `nodither` (its LaunchAgent and `~/.local/bin/nodither`).

## Usage

| Command | |
|---|---|
| `dusk status` | Show `enableDither` and the link per external display, the three looks and tonight's times |
| `dusk set day\|evening\|night warmth <K>` | 0 (pure red) to 6500 (no tint) |
| `dusk set day\|evening\|night brightness <percent>` | 30 to 100 |
| `dusk apply` | Apply no dithering now and re-apply the tint |
| `dusk install [--no-menu]` | Install the binary and LaunchAgents |
| `dusk uninstall` | Remove them, and restore the default link, dithering and your previous Color Filters settings |

```
$ dusk status
DELL U4323QE
  enableDither  No
  link          8-bit RGB, full range
DELL G2524H
  enableDither  No
  link          8-bit RGB, full range
Tint
  day           4000 K, 100%
  evening       2700 K, 85%
  night         0 K (red), 70%
  sunset        18:17
  fully red by  20:19
  red until     03:53
  sunrise       07:05
  now           Day, Evening from 18:02
```

The log is at `~/Library/Logs/dusk.log`.

## How it works

### No dithering

- **Dithering:** `IORegistryEntrySetCFProperty(enableDither = false)` on every `IOMobileFramebufferAP` marked `external` (the parent class of `AppleCLCD2` and `IOMobileFramebufferShim`).
- **Link:** WindowServer's private SkyLight output-mode API. `SLSGetDisplayOutputModeLinkDescriptions` lists the links the current display mode supports, and `SLSConfigureDisplayOutputMode` selects an 8-bit SDR link: RGB full range when offered, otherwise RGB limited, then YCbCr 4:4:4, then 4:2:2. Any 8-bit link leaves the monitor nothing to dither; encoding and range only affect color accuracy. WindowServer saves the choice as `LinkDescription` in its display preferences and restores it when the monitor reconnects, so macOS keeps it on its own across monitor power cycles, sleep/wake and mode switches, with nothing running in between.
- **Status:** `enableDither` comes from the IORegistry (what `ioreg -lw0 | grep enableDither` shows). The link comes from the DCP itself via `IOAVVideoInterfaceGetLinkData`, so it reports what is actually on the cable. Monitors are matched across IOKit, the DCP and CoreGraphics by their EDID product ID and serial.
- **Reapplying:** `local.dusk.display` uses launchd's `com.apple.iokit.matching` event stream on `DCPAVServiceProxy` (`Location = External`), which the DCP publishes each time a monitor attaches, including after the Mac wakes from sleep. launchd starts `dusk agent`, which waits for WindowServer to bring the display online, applies, and exits.

### Tint

- **Color Filters.** The tint is macOS's own Accessibility Color Filters, set to Color Tint (category 1, filter type 16), through MediaAccessibility's private `MADisplayFilterPref…` functions. They write `com.apple.mediaaccessibility`, and universalaccessd applies the result as WindowServer's accessibility color matrix. macOS keeps it on its own across display mode switches (no flash) and reboots, so nothing has to run to keep the tint.
- **Colour.** A blackbody approximation white-balanced to 6500 K, blending smoothly to pure red below 2000 K. Color Tint's matrix is `diag((1 − i) + i × hue colour)`, so for a warm white (red = 1, green ≥ blue) intensity = 1 − blue and hue = 60° × (green − blue) / (1 − blue); 0 K is hue 0° at 100%, pure red. The colours are defined on encoded values and Color Filters work in linear light, so dusk converts them with a 2.2 power.
- **Writes.** Each fade step writes the hue and intensity with a single change notification, and nothing is written when the output wouldn't change. One step costs about 18 ms of CPU across the system, mostly universalaccessd, siriactionsd, BiomeAgent and distnoted reacting to the preference change, so a day's four fades (about 260 steps) cost about 4.6 s.
- **Schedule.** Sunrise and sunset use NOAA's equations (zenith 90.833°). `dusk tick` is stateless: it works out the look for now, and if a fade is running or starts before the next hourly check, it waits idle on a wall-clock timer (time asleep counts), steps through the fade and exits. launchd starts missed checks after wake and never runs two at once. When the displays are asleep or the screen is locked, it skips to the end of the fade.

### Dimming

Color Filters can't dim: macOS normalizes the matrix so the brightest channel stays at 100%, and the Reduce White Point setting only works on iOS. So dusk dims with a gamma formula (output = brightness × input) on each display. macOS drops a gamma table when the process that set it exits, and resets every display's table during a mode switch, so `dusk menu` stays running to hold it. `dusk tick` sends it the brightness through a Darwin notification. After a display change or wake, it checks the tables every 20 ms for 3 seconds and sets them again as soon as macOS has reset them, which takes about 25 ms, while the monitor is still blank from the switch. Otherwise it has no timers and doesn't poll.

## Overhead

Measured on a Mac mini M4 with macOS 26.6:

- **Resident:** only `dusk menu`, 12 MB (as `top` shows it), with no idle wakeups.
- **CPU:** about 5 s a day. 4.6 s of it is macOS applying the ~260 tint steps of the four fades; an hourly check with nothing to do takes ~30 ms.
- **Display mode switch:** the tint is unaffected; dimming is back about 25 ms after macOS resets it.

## Notes

- Uses private Apple APIs, so a macOS update can break it. If one disappears, that step is skipped and the run exits 1; turning off GPU dithering only needs public IOKit, so it still happens.
- Tested on a Mac mini M4 with macOS 26.6 and two Dell monitors (one on HDMI, one on USB-C). No dithering was tested through a monitor power cycle and a system sleep/wake, the tint and dimming through display mode switches. Other chips and macOS versions are untested.
- SDR only. HDR needs a 10-bit link.
- `enableDither` resets on reboot; `local.dusk.display` sets it again at login.
- Display mode changes don't undo no dithering. WindowServer applies the saved 8-bit RGB link to whatever mode is active, so a game that switches resolution or refresh rate keeps it, and GPU dithering stays off across the link retrain (tested 4K60 → 4K30 and 240 → 120 Hz, during the switch and after the game quits).
- Night Shift, color profile switches, gamma changes and Color Filters don't reset the link or `enableDither` (tested).
- dusk owns the Color Filters setting while installed. The weakest tint macOS applies is 25% intensity, about 5400 K, so settings between about 5400 K and 6500 K look like 5400 K. `uninstall` puts back the Color Filters settings you had before the first install.
- Don't run another app that tints or dims with gamma tables alongside dusk; they would overwrite each other's tables.
- Dimming ignores any calibration curve (`vcgt`) in the display's color profile while it is below 100%, like other gamma-table dimmers.
- `uninstall` switches each external monitor back to the link WindowServer picks by default and turns GPU dithering back on.

## License

MIT
