# Challenge: Accelerometer 3D Cube

Real-time 3D wireframe cube on an SSD1306 OLED, driven by the DE10-Lite's onboard ADXL345 accelerometer. The FPGA reads the sensor over SPI and streams raw X/Y/Z data to the ESP32 over UART. The ESP32 computes pitch/roll and renders a perspective-correct rotating cube at 30 Hz.

## How It Works

### FPGA Side
1. `adxl345_spi` state machine initialises the ADXL345 at startup (full-res, 100 Hz output rate, measure mode) using SPI mode 3 at 1 MHz.
2. After init, axes are read at 30 Hz. Raw signed 16-bit X/Y/Z values are passed to the UART TX framer.
3. `uart_tx` sends a 10-byte binary frame on `ARDUINO_IO[1]` at 9600 baud:

   ```
   A5  5A  SEQ  X0  X1  Y0  Y1  Z0  Z1  SUM
   ```
   - `SEQ` — rolling frame counter (8-bit, wraps at 255).
   - `X0/X1` — X raw little-endian (LSB first).
   - `Y0/Y1` — Y raw little-endian.
   - `Z0/Z1` — Z raw little-endian.
   - `SUM` — low 8 bits of `SEQ + X0 + X1 + Y0 + Y1 + Z0 + Z1`.

4. LEDR debug map (active while running, SW[9] & KEY[0] must both be high):

   | LED | Meaning |
   |-----|---------|
   | LEDR[0] | GSENSOR_SDO level (ON = high/idle) |
   | LEDR[1] | Sticky: SDO went low during CS assertion |
   | LEDR[2] | Sticky: CS_N ever went low |
   | LEDR[3] | Y tilt backward (raw < −80) |
   | LEDR[4] | Frame toggle — pulses every UART frame |
   | LEDR[5] | UART TX busy |
   | LEDR[6] | ADXL345 init complete |
   | LEDR[7] | DEVID verified (0xE5 received) |
   | LEDR[8] | CS_N active (instantaneous) |
   | LEDR[9] | rst_n (SW[9] & KEY[0]) |

5. HEX display:

   | Display | Meaning |
   |---------|---------|
   | HEX1:0 | ADXL345 DEVID (should show `E5` when healthy) |
   | HEX2 | UART frame counter (cycles 0–F) |
   | HEX3 | SPI state machine state (6 = ST_WAIT = sampling normally) |
   | HEX4 | GSENSOR_INT1 |
   | HEX5 | GSENSOR_INT2 |

### ESP32 Side
1. `HardwareSerial(2)` receives frames on GPIO17 (RX) from `ARDUINO_IO[1]`.
2. A 3-state byte parser (`WAIT_A5 → WAIT_5A → READ_BODY`) reassembles each frame and validates the checksum.
3. From the raw axes, pitch and roll angles are computed:
   ```cpp
   rollDeg  = atan2f(y, z)              * 180/PI;
   pitchDeg = atan2f(-x, sqrt(y²+z²))  * 180/PI;
   ```
   Both are low-pass filtered (α = 0.18) for smooth rendering.
4. **Axis mapping** (tuned to view from the left side of the FPGA, top-down camera):
   - Cube pitch ← physical roll
   - Cube roll  ← physical pitch
5. `projectVertex` applies the rotation then uses a simple perspective divide (camera at distance 4, scale 48). Camera is above (+Y), so depth axis is `−y2`; screen axes are `x2` (horizontal) and `z2` (vertical). A fixed 90° Y-axis pre-rotation orients the cube face correctly.
6. The OLED header line shows `P:nnn R:nnn` (raw sensor pitch/roll degrees). The cube fills the remainder of the 128×64 display at scale=48.

> **Note:** Yaw is not measured — the ADXL345 is a 3-axis accelerometer only. Yaw requires a magnetometer or gyroscope.

---

## Wiring

| Signal | FPGA pin | Arduino header | ESP32 |
|--------|----------|----------------|-------|
| UART TX (FPGA→ESP32) | PIN_AB6 | ARDUINO_IO[1] | GPIO17 (RX) |
| UART RX (ESP32→FPGA) | PIN_AB5 | ARDUINO_IO[0] | GPIO16 (TX) — unused |
| OLED SDA | — | — | PIN_OLED_SDA (see pin_config.h) |
| OLED SCL | — | — | PIN_OLED_SCL (see pin_config.h) |

ADXL345 onboard FPGA pins:

| Signal | FPGA Pin |
|--------|----------|
| GSENSOR_SCLK | PIN_AB15 |
| GSENSOR_SDI | PIN_V11 |
| GSENSOR_SDO | PIN_V12 |
| GSENSOR_CS_N | PIN_AB16 |
| GSENSOR_INT1 | PIN_Y14 |
| GSENSOR_INT2 | PIN_Y13 |

---

## Build & Flash

### FPGA
```powershell
cd challenge_submissions/accelerometer_cube/fpga
C:\intelFPGA_lite\17.1\quartus\bin64\quartus_sh.exe --flow compile accelerometer_cube_top
C:\intelFPGA_lite\17.1\quartus\bin64\quartus_pgm.exe -c "USB-Blaster [USB-1]" -m JTAG -o "P;output_files/accelerometer_cube_top.sof"
```

### ESP32
```powershell
cd challenge_submissions/accelerometer_cube/esp32
$PIO = "$env:USERPROFILE\.platformio\penv\Scripts\pio.exe"
. $PIO run -t upload --upload-port COM5
```

---

## Expected Behaviour

- OLED shows `P:nnn R:nnn` on the top line and a wireframe cube below.
- Tilting the FPGA board rotates the cube smoothly in real time.
- `LEDR[6]` (init done) and `LEDR[7]` (devid OK) should both be ON within ~1 s of reset.
- HEX3 should read `6` (ST_WAIT) during normal operation.
- HEX1:0 should read `E5`.

---

## Project Files

| File | Purpose |
|------|---------|
| `fpga/src/accelerometer_cube_top.sv` | Top module: UART framing, LEDs, HEX debug |
| `fpga/src/adxl345_spi.sv` | ADXL345 SPI init + 30 Hz axis reader |
| `fpga/src/uart_tx.sv` | Parameterised 9600 8N1 UART TX |
| `fpga/src/seven_segment.sv` | Active-low hex 7-segment decoder |
| `fpga/accelerometer_cube_top.qsf` | Quartus pin assignments |
| `esp32/src/main.cpp` | Frame parser, pitch/roll math, OLED cube renderer |
| `esp32/platformio.ini` | PlatformIO build config |

---

## Troubleshooting

| Symptom | Likely cause |
|---------|-------------|
| All LEDs off | SW[9] or KEY[0] is low — both must be high to release reset |
| LEDR[7] off, HEX1:0 = FF | ADXL345 not responding on SPI MISO — check LEDR[2] to verify CS_N toggles |
| LEDR[2] off | CS_N stuck high — check QSF pin assignment for GSENSOR_CS_N |
| Cube frozen, LEDR[4] not flashing | No valid UART frames reaching ESP32 — check ARDUINO_IO[1]/GPIO17 wiring |
| OLED shows "Waiting for FPGA..." | FPGA not sending frames — check board is programmed and reset released |
| Cube rotates in wrong direction | Adjust sign/swap of `pitchRad`/`rollRad` in `drawCube()` in `main.cpp` |
| OLED blank | Press ESP32 EN; confirm OLED I2C address is 0x3C |
