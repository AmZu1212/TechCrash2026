# Flappy Bird Part 1

Challenge 9 Milestone 1: manual FPGA-controlled Flappy Bird.

## What It Does

- ESP32 renders a playable monochrome Flappy Bird-style game on the SSD1306 OLED.
- The gameplay HUD is intentionally minimal: a tiny `S:###` score strip plus a one-pixel separator.
- OLED proportions use a 5x4 bird, 8-pixel pipe width, and 17-to-12 pixel gap range across difficulty.
- FPGA reads `KEY[0]` as the flap/restart button.
- FPGA reads `SW[3:0]` as difficulty `0..15`.
- FPGA displays the current difficulty on `HEX1:HEX0` as `d<hex>`.
- FPGA sends flap and difficulty packets to ESP32 over UART.
- ESP32 applies flap commands to move the bird upward.
- ESP32 restarts the game when `KEY[0]` is pressed after game over.
- Higher difficulty increases pipe speed and reduces the pipe gap.

## UART Protocol

FPGA sends 4-byte binary packets at 9600 baud:

```text
0xA5 TYPE VALUE CHECKSUM
```

Packet types:

```text
TYPE 0x01: flap/restart event, VALUE = current difficulty
TYPE 0x02: difficulty update, VALUE = SW[3:0]
```

Checksum:

```text
CHECKSUM = 0xA5 ^ TYPE ^ VALUE
```

## Wiring

| Direction | FPGA | ESP32 |
|-----------|------|-------|
| FPGA -> ESP32 | ARDUINO_IO[1] | GPIO17 RX |
| Ground | Arduino GND | ESP32 GND |
| OLED SDA | - | GPIO21 |
| OLED SCL | - | GPIO22 |

ESP32 TX is not required for Part 1.

## Project Files

- `fpga/src/flappy_bird_part_1_top.sv` - FPGA button/difficulty controller and UART packet sender
- `fpga/src/uart_tx.sv` - 9600 baud 8N1 UART transmitter
- `fpga/src/seven_segment.sv` - active-low hex display decoder
- `fpga/flappy_bird_part_1.qsf` - DE10-Lite Quartus pin assignments
- `fpga/flappy_bird_part_1.sdc` - 50 MHz timing constraint
- `esp32/src/main.cpp` - OLED Flappy Bird game and UART packet parser
- `esp32/platformio.ini` - ESP32 PlatformIO project

## Build

### FPGA

```powershell
cd challenge_submissions/flappy_bird_part_1/fpga
& "C:\intelFPGA_lite\17.1\quartus\bin64\quartus_sh.exe" --flow compile flappy_bird_part_1
```

### ESP32

```powershell
cd challenge_submissions/flappy_bird_part_1/esp32
$env:USERPROFILE\.platformio\penv\Scripts\pio.exe run
```

## Expected Behavior

1. Program the FPGA and flash the ESP32.
2. Wire FPGA `ARDUINO_IO[1]` to ESP32 GPIO17 and connect common ground.
3. OLED shows the Flappy Bird game with only a tiny score HUD.
4. Press `KEY[0]` to flap.
5. If the bird crashes, press `KEY[0]` again to restart.
6. Change `SW[3:0]`; the FPGA display changes and the game becomes faster/tighter.
