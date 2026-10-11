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

Fades follow the clock, so after sleep the screen goes straight to where the fade should be. A fade updates the screen each time a colour channel moves one of its 256 levels, and ends exactly on the next look.

The menu bar icon (sun, sunset or moon) opens a menu with:

- a warmth and a brightness slider for each look, previewed live while you drag
- Reset to defaults, Pause for 1 hour, Night until sunrise
- Warm tint & dimming on/off, No dithering on/off
- tonight's sunset, red and sunrise times

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

Either way, `install` copies the binary to `~/.local/bin/dusk` and loads two LaunchAgents from `~/Library/LaunchAgents`. No root needed.

| LaunchAgent | Runs | When |
|---|---|---|
| `local.dusk.display` | `dusk agent` | At login and whenever a monitor attaches; applies no dithering, then exits |
| `local.dusk.tint` | `dusk tint` | Always; shows the tint and dimming, and the menu bar icon |

`install` also removes `nodither` (its LaunchAgent and `~/.local/bin/nodither`).

## Usage

| Command | |
|---|---|
| `dusk status` | Show `enableDither` and the link per external display, the three looks and tonight's times |
| `dusk set day\|evening\|night warmth <K>` | 0 (pure red) to 6500 (no tint) |
| `dusk set day\|evening\|night brightness <percent>` | 30 to 100 |
| `dusk set tint on\|off` | Turn the warm tint and dimming on or off |
| `dusk set dither on\|off` | `off` (the default) applies no dithering; `on` gives macOS back its default link and dithering |
| `dusk set icon on\|off` | Show or hide the menu bar icon |
| `dusk pause [minutes]` | No tint or dimming for a while (60 minutes by default), then a fade back |
| `dusk night` | Night until sunrise |
| `dusk resume` | End a pause or night |
| `dusk reset` | Back to the default looks |
| `dusk apply` | Apply no dithering and the tint again now, e.g. after another app reset the colours |
| `dusk install` | Install the binary and LaunchAgents |
| `dusk uninstall` | Remove them, and restore the default link and dithering |

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

### Tint and dimming

- **Gamma.** Both are one gamma formula per display (`CGSetDisplayTransferByFormula`): each channel's encoded value is multiplied by the warmth colour times the brightness. macOS drops a gamma table when the process that set it exits, so `dusk tint` stays running.
- **Colour.** A blackbody approximation white-balanced to 6500 K, blending smoothly to pure red below 2000 K, so 0 K is pure red.
- **Schedule.** Sunrise and sunset use NOAA's equations (zenith 90.833°). `dusk tint` shows the look for now and sleeps on a wall-clock timer until the 8-bit output next changes, so time asleep counts and the screen is right on wake. Fades move each channel in a straight line between the two looks.
- **Resets.** macOS resets every display's gamma table during a mode switch and when another app that set its own table quits, and can on monitor attach or wake. After any display change or wake, `dusk tint` checks the tables every 20 ms for 3 seconds and sets them again as soon as they were reset; that takes about 25 ms, while the monitor is still blank from the switch. After an app switch or quit it checks three times over 3 seconds. Otherwise it has no timers and doesn't poll.

## Overhead

Measured on a Mac mini M4 with macOS 26.6:

- **Resident:** only `dusk tint`, 11 MB (as `top` shows it), with no idle wakeups.
- **CPU:** well under a second a day: about 0.07 s per fade (four a day, about 900 one-level steps in all) and 0.1 s at login.
- **Settings changes:** applied in about 30 ms.
- **Display mode switch:** the tint and dimming are back about 25 ms after macOS resets them.

## Notes

- Uses private Apple APIs, so a macOS update can break it. If one disappears, that step is skipped and the run exits 1; turning off GPU dithering only needs public IOKit, so it still happens.
- Tested on a Mac mini M4 with macOS 26.6 and two Dell monitors (one on HDMI, one on USB-C). No dithering was tested through a monitor power cycle and a system sleep/wake; the gamma reset handling through display mode switches and an app quitting. Other chips and macOS versions are untested.
- SDR only. HDR needs a 10-bit link.
- `enableDither` resets on reboot; `local.dusk.display` sets it again at login.
- Display mode changes don't undo no dithering. WindowServer applies the saved 8-bit RGB link to whatever mode is active, so a game that switches resolution or refresh rate keeps it, and GPU dithering stays off across the link retrain (tested 4K60 → 4K30 and 240 → 120 Hz, during the switch and after the game quits).
- Night Shift, color profile switches, gamma changes and Color Filters don't reset the link or `enableDither` (tested).
- Don't run another app that tints or dims with gamma tables alongside dusk; they would overwrite each other's tables. If a command-line tool resets the gamma tables, `dusk apply` sets them again.
- While a tint or dimming is on, the display's calibration curve (`vcgt` in its color profile), if it has one, is replaced, like with other gamma-table apps.
- `uninstall` switches each external monitor back to the link WindowServer picks by default and turns GPU dithering back on.

## License

MIT
