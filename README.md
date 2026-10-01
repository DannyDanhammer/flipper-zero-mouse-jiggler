# Flipper Zero Mouse Jiggler

A native Flipper Zero USB HID mouse jiggler for Windows hosts.

The app continuously moves the pointer right and left while it is running. It is intentionally simple, visible, and easy to stop.

## Features

- Native Flipper Zero `.fap` application
- Uses the Flipper USB HID mouse interface
- Continuously alternates right/left movement
- Default movement: 40 pixels every 500 ms
- On-device status:
  - `USB HID connected`
  - `Mouse report: OK`
  - `Mouse report: WAIT`
  - `USB HID switch FAILED`
- Press the physical **BACK** button on the Flipper to stop immediately
- Restores the prior USB configuration when the app exits
- Installer auto-detects the Flipper by USB VID/PID
- Installer reads the device firmware version and uses a matching uFBT SDK
- Installer persists the app to `/ext/apps/Tools/mouse_jiggler.fap`

## Requirements

### Windows PC

- Windows PowerShell 5.1 or PowerShell 7+
- Python 3 with the Windows `py` launcher
- Internet access the first time uFBT/SDK components are downloaded
- Git is only required if you are contributing to the repository

### Flipper Zero

- Official Flipper Zero firmware
- microSD card installed
- USB data cable
- qFlipper closed while the installer is using the serial interface

The installer identifies the normal Flipper USB interface by:

- VID: `0483`
- PID: `5740`

## Quick Start

Connect the Flipper Zero over USB and close qFlipper.

From PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-FlipperMouseJiggler.ps1
```

The installer will:

1. Find the connected Flipper Zero.
2. Read its firmware version.
3. Install/update uFBT.
4. Build the native FAP against the corresponding SDK.
5. Remove legacy `Mouse_Jiggler.txt` BadUSB payloads if found.
6. Install the native app into `/ext/apps/Tools/mouse_jiggler.fap`.
7. Verify the upload.

After installation, open:

`Apps -> Tools -> Mouse Jiggler`

## Stopping the Jiggler

Press the physical **BACK** button on the Flipper.

The app exits and restores the USB mode that was active before the jiggler started.

## Configuration

The installer accepts two optional parameters:

```powershell
.\Install-FlipperMouseJiggler.ps1 -Pixels 20 -DelayMs 750
```

`Pixels` controls movement distance.

`DelayMs` controls the time between HID reports.

Defaults:

```text
Pixels  = 40
DelayMs = 500
```

## Troubleshooting

### qFlipper is open

Close qFlipper before running the installer. qFlipper can keep the Flipper's USB serial interface open.

### No Flipper Zero is found

Confirm Windows sees a device with VID `0483` and PID `5740`:

```powershell
Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -match 'VID_0483&PID_5740' } | Select-Object Name,PNPDeviceID
```

A normal result looks similar to:

```text
USB Serial Device (COM6)
USB\VID_0483&PID_5740&MI_00\...
```

### App says `USB HID connected` but the mouse does not move

Check the next status line.

`Mouse report: OK` means the Flipper HID API accepted the report.

`Mouse report: WAIT` means reports are not yet being accepted.

Try a different USB data cable or USB port if the host behaves unexpectedly.

### App does not appear under Apps -> Tools

Back out to the main Flipper menu and re-enter Apps so the application list refreshes.

The installed FAP should be located at:

```text
/ext/apps/Tools/mouse_jiggler.fap
```

## Manual Build

The native source is under `src/`.

With uFBT installed:

```powershell
cd .\src
ufbt
```

The resulting `.fap` is normally placed under the uFBT build output.

## Repository Layout

```text
.
|-- Install-FlipperMouseJiggler.ps1
|-- README.md
|-- LICENSE
|-- SECURITY.md
|-- .gitignore
`-- src
    |-- application.fam
    `-- mouse_jiggler.c
```

## Security / Intended Use

This project emits ordinary USB HID mouse movement only. It does not type commands, execute payloads on the host, collect data, or establish persistence on the computer.

Use it only on computers and environments you are authorized to interact with.

## License

MIT
