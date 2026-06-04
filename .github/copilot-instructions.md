# Copilot Instructions — CrashTech VLSI 2026

## Project Overview

This is a VLSI hackathon project using **DE10-Lite FPGA** (Intel MAX 10) and **ESP32 DevKit** communicating over UART.

## Key Conventions

### Python Environment

- The project Python venv is at `env/` (NOT `.venv/`).
- Activate: `env\Scripts\activate` (Windows).
- Python 3.11.9.

### FPGA ↔ ESP32 Communication

- **Default header is the Arduino header** on the DE10-Lite (`ARDUINO_IO[0..15]`).
  - FPGA RX from ESP32: `ARDUINO_IO[0]` (PIN_AB5).
  - FPGA TX to ESP32: `ARDUINO_IO[1]` (PIN_AB6).
  - ESP32 TX: GPIO 16, ESP32 RX: GPIO 17.
  - UART: 9600 baud, 8N1, 3.3V logic.
  - All unused `ARDUINO_IO` pins must be set to high-Z (`1'bz`).
- **JP1 (40-pin GPIO header) is allowed only where a specific challenge explicitly
  permits or requires it** (e.g. speed-loopback, PC retro game). Default to the
  Arduino header unless the challenge text says otherwise.

### Pin Definitions

- All ESP32 projects share `projects/common/esp32/pin_config.h`.
- Include it with the correct relative path from each project's `src/` folder.

### FPGA Toolchain

- Quartus Prime Lite 17.1 at `C:\intelFPGA_lite\17.1\`.
- Compile: `quartus_sh.exe --flow compile <project_name>`.
- Program: `quartus_pgm.exe -c "USB-Blaster [USB-0]" -m JTAG -o "P;output_files/<project>.sof"`.

### ESP32 Toolchain

- PlatformIO (VS Code extension or CLI).
- CLI path: `$env:USERPROFILE\.platformio\penv\Scripts\pio.exe`.
- Build: `pio run` from the project's `esp32/` folder.
- Upload: `pio run -t upload`.
- Monitor: `pio device monitor`.

### RTL Top Module Pattern

All FPGA projects use this port declaration:

```systemverilog
module project_top (
    input           MAX10_CLK1_50,
    input   [9:0]   SW,
    input   [1:0]   KEY,
    output  [9:0]   LEDR,
    output  [7:0]   HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout   [15:0]  ARDUINO_IO,
    inout           ARDUINO_RESET_N
);
```

### Project Structure

Each challenge/demo has parallel `esp32/` and `fpga/` folders:
- `esp32/platformio.ini` + `esp32/src/main.cpp`
- `fpga/<project>.qpf` + `fpga/<project>.qsf` + `fpga/src/<top>.sv`

### ESP32 Buzzer / Sound

- Passive buzzer on **GPIO19** (`PIN_BUZZER`), driven by Arduino `tone(pin, freq)` / `noTone(pin)`.
- Use a **non-blocking** playback pattern — never `delay()` inside `loop()`:
  ```cpp
  struct Note { uint16_t freq; uint16_t dur_ms; };  // freq=0 → rest
  // State: tuneActive, tuneNoteIdx, tuneNoteStart
  // startTune() — kick off; stopTune() — silence; updateTune() — call every loop()
  ```
- A `tunePlayed` flag (cleared when returning to idle screen) prevents the melody
  from restarting each time the FPGA sends a repeated result frame.
- **Melody source:** Note frequencies (Hz) follow standard 12-TET equal temperament
  (A4 = 440 Hz). Values are taken directly from the Arduino `pitches.h` frequency
  table (e.g. `NOTE_G5 = 784`, `NOTE_A5 = 880`, `NOTE_C6 = 1047`). To add a new
  tune, look up each note name in `pitches.h`, write it as a `Note` array entry,
  and include a short rest (`freq=0`) between notes for crisp articulation on a
  passive buzzer.

### ESP32 OLED 3D Cube Renderer

- SSD1306 128×64, I2C via Adafruit SSD1306 + GFX libs.
- Wireframe cube: 8 vertices × 12 edges, perspective divide with `scale / (cameraDistance ± depth)`.
- Camera perspective is chosen by which axis is used as depth in the projection:
  - **Front view**: depth = `z2`, screen = (`x2`, `y2`)
  - **Top-down view**: depth = `-y2`, screen = (`x2`, `z2`) ← accelerometer cube uses this
- Axis mapping between physical tilt and cube rotation is controlled in `drawCube()`:
  ```cpp
  float pitchRad = smoothRollDeg  * PI / 180.0f;  // physical roll → cube pitch
  float rollRad  = smoothPitchDeg * PI / 180.0f;  // physical pitch → cube roll
  ```
  Negate either to flip that direction. Swap to change which physical axis drives which rotation.
- A constant yaw offset (pre-rotation of vertices around Y before applying pitch/roll) controls which face is presented at rest.
- Pitch and roll are low-pass filtered (α = 0.18) for smooth rendering.
- **Yaw is not measurable** from a pure accelerometer — gravity vector is unchanged by rotation around the vertical axis. Requires magnetometer or gyroscope.

### ADXL345 Onboard Accelerometer (DE10-Lite)

- SPI mode 3 (CPOL=1, CPHA=1), 1 MHz, MSB first.
- Pins: SCLK=PIN_AB15, SDI=PIN_V11, SDO=PIN_V12, CS_N=PIN_AB16, INT1=PIN_Y14, INT2=PIN_Y13.
- DEVID register 0x00 should return 0xE5.
- Init sequence: READ_DEVID → DATA_FORMAT (0x31=0x08 full-res) → BW_RATE (0x2C=0x0A) → POWER_CTL (0x2D=0x08 measure).
- Axis read command: 0xF2 (read | multi-byte | reg 0x32), 7 bytes total (1 cmd + 6 data).
- INT2 asserted on startup is normal — the chip is powered even if SPI is not responding.
- SDO idles high due to DE10-Lite PCB pull-up (LEDR showing SDO=1 at idle is normal).
- The GSENSOR_* ports are **extra ports beyond the standard RTL template** and must be added to the top module declaration alongside the standard ports.

### FPGA Zero-Crossing Frequency Detection

- Formula: `freq = ZC × Fs / (2N)` where ZC = zero-crossings, Fs = sample rate, N = window size.
  - For 8000 Hz / 256 samples: `freq = ZC × 15.625 Hz` → implement as `zc * 125 / 8` (shift right 3).
  - Multiply first, then bit-select for the divide: `freq_hz = (zc * 125)[13:3]`.
- **Off-by-one is expected and acceptable:** byte 0 initialises `prev_sign` without counting a crossing → consistent −15.6 Hz bias, within ±35 Hz spec.
- Use `rx_byte[7]` (MSB = sign bit) for zero-crossing, not a threshold comparison — works for signed 8-bit samples.
- Frame sync: use a **gap timer** (e.g. 5 ms = 250,000 cycles at 50 MHz) to reset `byte_cnt` on stale partial frames.
- Debug mode: `SW[9]` toggles between displaying Hz and displaying raw ZC count on the 7-segs.

### FPGA Binary-to-BCD (Double-Dabble)

- Use the double-dabble (shift-and-add-3) algorithm for combinational binary → BCD conversion.
- For an N-bit input and D BCD digits: scratch register is `(4*D + N)` bits; iterate N times:
  - Before each left-shift: add 3 to any BCD nibble ≥ 5.
  - After N iterations the upper `4*D` bits hold the BCD digits (MSB = most significant digit).
- 11-bit input (0–2047) → 4 digits, scratch = 27 bits. Fits in MAX 10 combinational logic.
- Always instantiate as a separate module (`bin_to_bcd.sv`) so it can be reused for multiple values (e.g. frequency + debug ZC count).

### What NOT to Do

- Do NOT default to JP1 GPIO header pins. Use the Arduino header (`ARDUINO_IO[0..15]`)
  unless a specific challenge explicitly allows or requires JP1.
- Do NOT use `.venv/` for the Python environment. Use `env/`.
- Do NOT hardcode COM port numbers. PlatformIO auto-detects.
- Do NOT install ESP32 toolchain manually. PlatformIO handles it.

## Git Rules (HARD STOP)

- **NEVER `git push` without explicit permission from Avi.** This applies to every
  branch, every remote, every workspace. Local commits may be proposed when asked,
  but anything that touches a remote requires Avi to say "push" / "publish" /
  "ship" explicitly. Phrases like "go ahead", "do it", or "wanna try?" are NOT
  push permission.
- Same rule applies to `git push --force`, `git push --tags`, `gh pr create`,
  `gh pr merge`, and any script that internally pushes (e.g.
  `scripts/publish-challenges.ps1` in `-IntoMainRepo` or `-SeparateRepo` modes).
- Default behavior when work is ready: stage and commit locally if asked, then
  stop and report "commit ready, awaiting push permission".
- **NEVER commit or push anything from `challenges/` or `challenges_public/`.**
  Both folders are gitignored. If a future change accidentally un-ignores them,
  STOP and ask before any git operation.
