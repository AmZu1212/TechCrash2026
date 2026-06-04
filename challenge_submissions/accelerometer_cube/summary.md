# Accelerometer 3D Cube

The FPGA reads the DE10-Lite onboard ADXL345 accelerometer over SPI, streams raw X/Y/Z acceleration bytes to the ESP32 over UART, and the ESP32 renders a tilt-controlled wireframe cube on the OLED.

## How It Works

1. The FPGA initializes the onboard ADXL345:
   - Reads `DEVID` register `0x00` and expects `0xE5`
   - Sets `DATA_FORMAT` register `0x31` to full-resolution mode
   - Sets `BW_RATE` register `0x2C` to 100 Hz output data rate
   - Sets `POWER_CTL` register `0x2D` to measurement mode
2. The FPGA reads six raw bytes from `DATAX0..DATAZ1` about 30 times per second.
3. Each sample is sent to the ESP32 as a 10-byte binary UART frame:
   - `A5 5A SEQ X0 X1 Y0 Y1 Z0 Z1 SUM`
   - `SUM = SEQ + X0 + X1 + Y0 + Y1 + Z0 + Z1` modulo 256
4. The ESP32 receives and validates frames, converts the raw bytes to signed `int16_t` X/Y/Z values, then computes pitch and roll.
5. The ESP32 smooths pitch/roll and draws a projected wireframe cube on the SSD1306 OLED.
6. FPGA LEDs show tilt direction and debug status.

## Wiring

| Component | Pin | Wire | DE10-Lite / ESP32 Pin | Function |
|-----------|-----|------|------------------------|----------|
| DE10-Lite | ARDUINO_IO[1] | -> | ESP32 GPIO17 | FPGA UART TX -> ESP32 UART RX |
| ESP32 | GPIO21 | -> | OLED SDA | I2C data |
| ESP32 | GPIO22 | -> | OLED SCL | I2C clock |
| ESP32 | 3.3V | -> | OLED VCC | OLED power |
| ESP32 | GND | -> | OLED GND | OLED ground |
| ESP32 | GND | <-> | DE10-Lite Arduino GND | Common ground |

No external wires are needed for the accelerometer. The ADXL345 is onboard the DE10-Lite and connected directly to FPGA pins:

| Signal | FPGA Pin |
|--------|----------|
| GSENSOR_SCLK | PIN_AB15 |
| GSENSOR_SDI | PIN_V11 |
| GSENSOR_SDO | PIN_V12 |
| GSENSOR_CS_N | PIN_AB16 |
| GSENSOR_INT1 | PIN_Y14 |
| GSENSOR_INT2 | PIN_Y13 |

## FPGA LED Meaning

| LED | Meaning |
|-----|---------|
| LEDR[0] | Tilt left |
| LEDR[1] | Tilt right |
| LEDR[2] | Tilt forward |
| LEDR[3] | Tilt back |
| LEDR[4] | Toggles on each sampled frame |
| LEDR[5] | UART transmitter busy |
| LEDR[6] | ADXL345 init sequence completed |
| LEDR[7] | ADXL345 device ID matched `0xE5` |
| LEDR[8] | ADXL345 SPI chip-select active |
| LEDR[9] | FPGA reset released |

HEX1:HEX0 show the ADXL345 device ID. A healthy board should show `E5`.

## Project Files

- `fpga/src/accelerometer_cube_top.sv` - top module, UART framing, LEDs, debug displays
- `fpga/src/adxl345_spi.sv` - ADXL345 SPI initialization and raw sample reader
- `fpga/src/uart_tx.sv` - 9600 baud 8N1 UART transmitter
- `fpga/src/seven_segment.sv` - active-low hex seven-segment decoder
- `fpga/accelerometer_cube_top.qsf` - Quartus pin assignments
- `esp32/src/main.cpp` - UART frame parser, pitch/roll math, OLED wireframe cube renderer
- `esp32/platformio.ini` - PlatformIO ESP32 build config

## Build

### FPGA

```powershell
cd challenge_submissions/accelerometer_cube/fpga
& "C:\intelFPGA_lite\17.1\quartus\bin64\quartus_sh.exe" --flow compile accelerometer_cube_top
```

### ESP32

```powershell
cd challenge_submissions/accelerometer_cube/esp32
$env:USERPROFILE\.platformio\penv\Scripts\pio.exe run
```

## Expected Behavior

- With `SW[9]` up and `KEY[0]` not pressed, the FPGA starts reading the accelerometer.
- `LEDR[6]` turns on after the ADXL345 init sequence.
- `LEDR[7]` turns on if the FPGA read `DEVID = 0xE5`.
- `HEX1:HEX0` show `E5`.
- The ESP32 OLED shows a wireframe cube.
- Tilting the DE10-Lite changes the cube rotation live.
- LEDR[0..3] indicate left/right/forward/back tilt.

## Troubleshooting

- If the OLED says `Waiting for FPGA...`, check the UART wire from FPGA `ARDUINO_IO[1]` to ESP32 GPIO17 and confirm both boards share ground.
- If `LEDR[6]` is on but `LEDR[7]` is off, the FPGA is running but did not read ADXL345 device ID `0xE5`; check the bitstream and accelerometer pin assignments.
- If the cube moves but feels reversed, swap sign conventions in the ESP32 pitch/roll calculation or the FPGA LED direction labels.
- If the display is blank, press ESP32 EN/reset and confirm the OLED address is `0x3C`.
