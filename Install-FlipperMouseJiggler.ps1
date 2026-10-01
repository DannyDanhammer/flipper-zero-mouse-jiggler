# Install-FlipperMouseJiggler.ps1
#
# Builds and persistently installs a native Flipper Zero Mouse Jiggler.
#
# Fixes the prior HID issue by:
#   - switching to USB HID unconditionally (and checking the result)
#   - waiting for Windows to enumerate the HID interface
#   - showing HID status on-screen
#   - moving right/left continuously once connected
#   - stopping immediately with the Flipper BACK button
#
# Installs to:
#   /ext/apps/Tools/mouse_jiggler.fap
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\Install-FlipperMouseJiggler.ps1
#
# Optional:
#   .\Install-FlipperMouseJiggler.ps1 -Pixels 8 -DelayMs 200

param(
    [ValidateRange(1, 50)]
    [int]$Pixels = 40,

    [ValidateRange(50, 5000)]
    [int]$DelayMs = 500
)

$ErrorActionPreference = "Stop"
$BaudRate = 230400
$RemoteFap = "/ext/apps/Tools/mouse_jiggler.fap"
$ChunkSize = 256

function Fail([string]$Message) {
    Write-Host ""
    Write-Host "[!] $Message" -ForegroundColor Red
    exit 1
}

function Read-FlipperOutput {
    param(
        [System.IO.Ports.SerialPort]$Port,
        [int]$WaitMilliseconds = 350
    )

    Start-Sleep -Milliseconds $WaitMilliseconds
    $Output = ""

    while ($Port.BytesToRead -gt 0) {
        $Output += $Port.ReadExisting()
        Start-Sleep -Milliseconds 30
    }

    return $Output
}

function Invoke-FlipperCommand {
    param(
        [System.IO.Ports.SerialPort]$Port,
        [string]$Command,
        [int]$WaitMilliseconds = 350
    )

    $Port.DiscardInBuffer()
    $Port.Write("$Command`r")
    return Read-FlipperOutput -Port $Port -WaitMilliseconds $WaitMilliseconds
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " Flipper Zero Mouse Jiggler"
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Movement: +$Pixels / -$Pixels pixels"
Write-Host "Interval: $DelayMs ms"
Write-Host "Stop:     BACK button on Flipper"
Write-Host ""

$qFlipper = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match "^qFlipper" }

if ($qFlipper) {
    Fail "qFlipper is running. Close it before continuing."
}

Write-Host "[*] Detecting Flipper Zero..." -ForegroundColor Cyan

$Device = Get-CimInstance Win32_PnPEntity |
    Where-Object {
        $_.PNPDeviceID -match "(?i)VID_0483&PID_5740" -and
        $_.Name -match "\(COM\d+\)"
    } |
    Select-Object -First 1

if (-not $Device) {
    Fail "No Flipper Zero USB serial interface was found."
}

if ($Device.Name -notmatch "\((COM\d+)\)") {
    Fail "Flipper found, but COM port could not be determined."
}

$ComPort = $Matches[1]

Write-Host "[+] Device: $($Device.Name)" -ForegroundColor Green
Write-Host "[+] Port:   $ComPort" -ForegroundColor Green

# Read firmware version.
$Serial = New-Object System.IO.Ports.SerialPort
$Serial.PortName = $ComPort
$Serial.BaudRate = $BaudRate
$Serial.Parity = [System.IO.Ports.Parity]::None
$Serial.DataBits = 8
$Serial.StopBits = [System.IO.Ports.StopBits]::One
$Serial.Handshake = [System.IO.Ports.Handshake]::None
$Serial.ReadTimeout = 3000
$Serial.WriteTimeout = 10000
$Serial.DtrEnable = $true

$FirmwareVersion = $null

try {
    $Serial.Open()
    Start-Sleep -Milliseconds 800
    $Serial.Write("`r")
    Start-Sleep -Milliseconds 300
    $null = $Serial.ReadExisting()

    $Info = Invoke-FlipperCommand -Port $Serial -Command "info device" -WaitMilliseconds 1400

    if ($Info -match "firmware\.version\s*:\s*([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9._-]+)?)") {
        $FirmwareVersion = $Matches[1]
    }
}
finally {
    if ($Serial.IsOpen) { $Serial.Close() }
    $Serial.Dispose()
}

if (-not $FirmwareVersion) {
    Fail "Could not determine Flipper firmware version."
}

Write-Host "[+] Firmware: $FirmwareVersion" -ForegroundColor Green
Write-Host ""

# Check Python and uFBT.
Write-Host "[*] Checking Python..." -ForegroundColor Cyan

try {
    $PythonVersion = (& py -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>$null).Trim()
}
catch {
    Fail "Python 3 with the Windows py launcher is required."
}

if (-not $PythonVersion) {
    Fail "Python 3 with the Windows py launcher is required."
}

Write-Host "[+] Python: $PythonVersion" -ForegroundColor Green

Write-Host "[*] Installing/updating uFBT..." -ForegroundColor Cyan
& py -m pip install --upgrade ufbt

if ($LASTEXITCODE -ne 0) {
    Fail "uFBT installation failed."
}

$ScriptsDir = (& py -c "import sysconfig; print(sysconfig.get_path('scripts'))").Trim()
$UfbtExe = Join-Path $ScriptsDir "ufbt.exe"

if (-not (Test-Path $UfbtExe)) {
    $UfbtCmd = Get-Command ufbt -ErrorAction SilentlyContinue

    if ($UfbtCmd) {
        $UfbtExe = $UfbtCmd.Source
    } else {
        Fail "ufbt.exe could not be located."
    }
}

# Generate app.
$BuildDir = Join-Path $env:TEMP "FlipperMouseJiggler"

if (Test-Path $BuildDir) {
    Remove-Item $BuildDir -Recurse -Force
}

New-Item -ItemType Directory -Path $BuildDir | Out-Null

$Fam = @'
App(
    appid="mouse_jiggler",
    name="Mouse Jiggler",
    apptype=FlipperAppType.EXTERNAL,
    entry_point="mouse_jiggler_app",
    stack_size=2 * 1024,
    fap_category="Tools",
    fap_description="Continuous USB mouse jiggler. BACK stops.",
    fap_version="1.2",
)
'@

$CSource = @"
#include <furi.h>
#include <furi_hal.h>
#include <furi_hal_usb.h>
#include <furi_hal_usb_hid.h>

#include <gui/gui.h>
#include <gui/view_port.h>
#include <gui/canvas.h>
#include <input/input.h>

#define JIGGLE_PIXELS $Pixels
#define JIGGLE_DELAY_MS $DelayMs

typedef struct {
    FuriMessageQueue* queue;
    bool usb_switch_ok;
    bool connected;
    bool last_report_ok;
} MouseJigglerApp;

static void mouse_jiggler_draw(Canvas* canvas, void* context) {
    MouseJigglerApp* app = context;

    canvas_clear(canvas);
    canvas_set_font(canvas, FontPrimary);
    canvas_draw_str(canvas, 18, 13, "Mouse Jiggler");

    canvas_set_font(canvas, FontSecondary);

    if(!app->usb_switch_ok) {
        canvas_draw_str(canvas, 12, 30, "USB HID switch FAILED");
    } else if(app->connected) {
        canvas_draw_str(canvas, 17, 30, "USB HID connected");
        if(app->last_report_ok) {
            canvas_draw_str(canvas, 16, 44, "Mouse report: OK");
        } else {
            canvas_draw_str(canvas, 12, 44, "Mouse report: WAIT");
        }
    } else {
        canvas_draw_str(canvas, 14, 30, "Waiting for Windows");
        canvas_draw_str(canvas, 21, 44, "to attach HID...");
    }

    canvas_draw_str(canvas, 24, 60, "BACK = STOP");
}

static void mouse_jiggler_input(InputEvent* event, void* context) {
    MouseJigglerApp* app = context;

    if(
        (event->type == InputTypeShort || event->type == InputTypePress) &&
        event->key == InputKeyBack) {
        furi_message_queue_put(app->queue, event, 0);
    }
}

int32_t mouse_jiggler_app(void* p) {
    UNUSED(p);

    MouseJigglerApp app = {
        .queue = furi_message_queue_alloc(8, sizeof(InputEvent)),
        .usb_switch_ok = false,
        .connected = false,
        .last_report_ok = false,
    };

    ViewPort* view_port = view_port_alloc();
    view_port_draw_callback_set(view_port, mouse_jiggler_draw, &app);
    view_port_input_callback_set(view_port, mouse_jiggler_input, &app);

    Gui* gui = furi_record_open(RECORD_GUI);
    gui_add_view_port(gui, view_port, GuiLayerFullscreen);

    const FuriHalUsbInterface* previous_usb = furi_hal_usb_get_config();

    /*
     * Do not silently skip HID setup just because the USB subsystem reports
     * a locked state. Request HID explicitly and check whether it succeeds.
     */
    app.usb_switch_ok = furi_hal_usb_set_config(&usb_hid, NULL);
    view_port_update(view_port);

    /*
     * Give the host time to see the USB disconnect/reconnect and enumerate
     * the new HID interface.
     */
    if(app.usb_switch_ok) {
        for(uint8_t i = 0; i < 30; i++) {
            InputEvent event;

            if(furi_message_queue_get(app.queue, &event, 100) == FuriStatusOk) {
                if(event.key == InputKeyBack) {
                    goto cleanup;
                }
            }

            app.connected = furi_hal_hid_is_connected();
            view_port_update(view_port);

            if(app.connected) {
                break;
            }
        }
    }

    bool move_right = true;

    while(true) {
        InputEvent event;

        if(
            furi_message_queue_get(
                app.queue,
                &event,
                JIGGLE_DELAY_MS) == FuriStatusOk) {

            if(event.key == InputKeyBack) {
                break;
            }
        }

        bool now_connected = furi_hal_hid_is_connected();

        if(now_connected != app.connected) {
            app.connected = now_connected;
            view_port_update(view_port);
        }

        if(app.usb_switch_ok && app.connected) {
            bool sent = false;

            if(move_right) {
                sent = furi_hal_hid_mouse_move(JIGGLE_PIXELS, 0);
            } else {
                sent = furi_hal_hid_mouse_move(-JIGGLE_PIXELS, 0);
            }

            app.last_report_ok = sent;
            view_port_update(view_port);
            move_right = !move_right;
        }
    }

cleanup:

    if(previous_usb) {
        furi_hal_usb_set_config((FuriHalUsbInterface*)previous_usb, NULL);
    }

    gui_remove_view_port(gui, view_port);
    view_port_free(view_port);
    furi_record_close(RECORD_GUI);
    furi_message_queue_free(app.queue);

    return 0;
}
"@

Set-Content -Path (Join-Path $BuildDir "application.fam") -Value $Fam -Encoding ASCII
Set-Content -Path (Join-Path $BuildDir "mouse_jiggler.c") -Value $CSource -Encoding ASCII

Write-Host "[*] Updating SDK for firmware $FirmwareVersion..." -ForegroundColor Cyan

Push-Location $BuildDir

try {
    & $UfbtExe update "--branch=$FirmwareVersion"

    if ($LASTEXITCODE -ne 0) {
        Fail "Could not prepare uFBT SDK for firmware $FirmwareVersion."
    }

    Write-Host "[*] Building native Mouse Jiggler..." -ForegroundColor Cyan
    & $UfbtExe

    if ($LASTEXITCODE -ne 0) {
        Fail "Mouse Jiggler build failed."
    }
}
finally {
    Pop-Location
}

$Fap = Get-ChildItem -Path (Join-Path $BuildDir "dist") -Filter "mouse_jiggler.fap" -Recurse |
    Select-Object -First 1

if (-not $Fap) {
    Fail "Build succeeded but mouse_jiggler.fap was not found."
}

$FapBytes = [System.IO.File]::ReadAllBytes($Fap.FullName)
$LocalMd5 = (Get-FileHash -LiteralPath $Fap.FullName -Algorithm MD5).Hash.ToLowerInvariant()

Write-Host "[+] Built: $($Fap.FullName)" -ForegroundColor Green
Write-Host "[+] Size:  $($FapBytes.Length) bytes" -ForegroundColor Green
Write-Host ""

# Re-open COM and persist the FAP.
$Serial = New-Object System.IO.Ports.SerialPort
$Serial.PortName = $ComPort
$Serial.BaudRate = $BaudRate
$Serial.Parity = [System.IO.Ports.Parity]::None
$Serial.DataBits = 8
$Serial.StopBits = [System.IO.Ports.StopBits]::One
$Serial.Handshake = [System.IO.Ports.Handshake]::None
$Serial.ReadTimeout = 3000
$Serial.WriteTimeout = 10000
$Serial.DtrEnable = $true

try {
    Write-Host "[*] Installing FAP persistently..." -ForegroundColor Cyan

    $Serial.Open()
    Start-Sleep -Milliseconds 800
    $Serial.Write("`r")
    Start-Sleep -Milliseconds 300
    $null = $Serial.ReadExisting()

    # Remove old BadUSB variants.
    foreach ($Old in @(
        "/ext/badusb/Mouse_Jiggler.txt",
        "/ext/badusb/Mouse Jiggler.txt",
        "/ext/badusb/mouse_jiggler.txt"
    )) {
        $Stat = Invoke-FlipperCommand -Port $Serial -Command "storage stat `"$Old`"" -WaitMilliseconds 250

        if ($Stat -notmatch "(?i)(not found|does not exist|error)") {
            $null = Invoke-FlipperCommand -Port $Serial -Command "storage remove `"$Old`"" -WaitMilliseconds 350
        }
    }

    foreach ($Dir in @("/ext/apps", "/ext/apps/Tools")) {
        $Stat = Invoke-FlipperCommand -Port $Serial -Command "storage stat $Dir" -WaitMilliseconds 250

        if ($Stat -match "(?i)(not found|does not exist|error)") {
            $null = Invoke-FlipperCommand -Port $Serial -Command "storage mkdir $Dir" -WaitMilliseconds 350
        }
    }

    $OldStat = Invoke-FlipperCommand -Port $Serial -Command "storage stat $RemoteFap" -WaitMilliseconds 250

    if ($OldStat -notmatch "(?i)(not found|does not exist|error)") {
        $null = Invoke-FlipperCommand -Port $Serial -Command "storage remove $RemoteFap" -WaitMilliseconds 400
    }

    $Offset = 0
    $TotalChunks = [math]::Ceiling($FapBytes.Length / $ChunkSize)

    while ($Offset -lt $FapBytes.Length) {
        $ThisChunkSize = [math]::Min($ChunkSize, $FapBytes.Length - $Offset)

        $Chunk = New-Object byte[] $ThisChunkSize
        [Array]::Copy($FapBytes, $Offset, $Chunk, 0, $ThisChunkSize)

        $Serial.DiscardInBuffer()
        $Serial.Write("storage write_chunk $RemoteFap $ThisChunkSize`r")
        Start-Sleep -Milliseconds 120

        $Serial.BaseStream.Write($Chunk, 0, $Chunk.Length)
        $Serial.BaseStream.Flush()

        Start-Sleep -Milliseconds 140
        $Response = Read-FlipperOutput -Port $Serial -WaitMilliseconds 80

        if ($Response -match "(?i)(error|failed)") {
            throw "Flipper reported an upload error:`n$Response"
        }

        $Offset += $ThisChunkSize
        $Percent = [math]::Floor(($Offset / $FapBytes.Length) * 100)
        Write-Progress -Activity "Installing Mouse Jiggler" -PercentComplete $Percent -Status "$Offset / $($FapBytes.Length) bytes"
    }

    Write-Progress -Activity "Installing Mouse Jiggler" -Completed

    $RemoteMd5Output = Invoke-FlipperCommand -Port $Serial -Command "storage md5 $RemoteFap" -WaitMilliseconds 800

    if ($RemoteMd5Output -match "([A-Fa-f0-9]{32})") {
        $RemoteMd5 = $Matches[1].ToLowerInvariant()

        if ($RemoteMd5 -ne $LocalMd5) {
            throw "FAP verification failed. Local MD5 $LocalMd5 != remote MD5 $RemoteMd5"
        }

        Write-Host "[+] FAP verified by MD5." -ForegroundColor Green
    } else {
        Write-Host "[!] FAP uploaded, but remote MD5 output could not be parsed." -ForegroundColor Yellow
    }
}
finally {
    if ($Serial.IsOpen) { $Serial.Close() }
    $Serial.Dispose()
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host " INSTALL COMPLETE"
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Open on the Flipper:"
Write-Host "    Apps -> Tools -> Mouse Jiggler" -ForegroundColor Cyan
Write-Host ""
Write-Host "The screen should show one of:"
Write-Host "    USB HID connected      = Windows accepted the HID device"
Write-Host "    Waiting for Windows    = HID requested; host is enumerating"
Write-Host "    USB HID switch FAILED  = firmware refused the USB-mode change"
Write-Host ""
Write-Host "STOP:"
Write-Host "    Press BACK on the Flipper." -ForegroundColor Yellow
Write-Host ""
