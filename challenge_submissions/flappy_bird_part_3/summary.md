# Flappy Bird Part 3

Challenge 9 Milestone 3: FPGA neural-network inference mode.

## What It Does

- ESP32 keeps the Part 2 neural-network training simulation.
- Training uses 64 birds, 4 inputs, 4 hidden neurons, and 1 output.
- The training physics match Part 1: 5x4 bird, 8-pixel pipes, same gravity, same flap impulse, same pipe scoring, same collision shape.
- ESP32 tracks the best trained brain found so far and archives the best 10 generation champions by progress.
- Each completed generation reports the picked champion's rightward progress and the delta from the previous generation.
- `SW[8]` on the FPGA selects mode:
  - `0`: ESP32 training mode
  - `1`: FPGA inference mode
- When FPGA inference mode starts, ESP32 first saves the current generation's best bird, then runs the archived champions on a held-out deterministic course and picks the winner.
- ESP32 then uploads that selected brain to the FPGA as signed fixed-point weights.
- OLED shows monochrome loading/status screens while archive evaluation and FPGA weight upload are running.
- ESP32 then sends the live game state to the FPGA each frame.
- FPGA runs the 4-4-1 neural network in fixed-point logic and returns flap/no-flap.
- OLED shows either training status or the single FPGA-controlled bird with a `SCORE:###  Diff: ##` score strip and a one-pixel separator.
- `SW[3:0]` still controls difficulty.
- In training mode, `KEY[0]` saves the current generation's best bird and advances to the next generation.
- In FPGA inference mode, `KEY[0]` resets/reloads the current inference run.
- FPGA displays difficulty on `HEX1:HEX0` as `d<hex>`, mode on `HEX2`, and loaded-weight status on `HEX3` (`F` means all 25 weights loaded).

## UART Protocol

FPGA to ESP32 packets are 4 bytes:

```text
0xA5 TYPE VALUE CHECKSUM
```

Types:

```text
0x01 reset command, VALUE = current difficulty
0x02 difficulty update, VALUE = SW[3:0]
0x03 mode update, VALUE bit0 = SW[8]
0x04 inference response, VALUE = {state_seq[6:0], flap}
```

ESP32 to FPGA packets:

```text
Weight packet: 0x5A 0x10 INDEX SIGNED_Q4_4_WEIGHT CHECKSUM
Load begin:    0x5A 0x11 0x00 25 CHECKSUM
State packet:  0x5A 0x20 SEQ IN0 IN1 IN2 IN3 CHECKSUM
```

The FPGA stores 25 weights:

```text
0..15  input-to-hidden weights
16..19 hidden biases
20..23 hidden-to-output weights
24     output bias
```

Checksum is XOR of all previous bytes in the packet.

## Wiring

| Direction | FPGA | ESP32 |
|-----------|------|-------|
| ESP32 -> FPGA | ARDUINO_IO[0] | GPIO16 TX |
| FPGA -> ESP32 | ARDUINO_IO[1] | GPIO17 RX |
| Ground | Arduino GND | ESP32 GND |
| OLED SDA | - | GPIO21 |
| OLED SCL | - | GPIO22 |

## Project Files

- `fpga/src/flappy_bird_part_3_top.sv` - FPGA mode/difficulty controller, UART protocol, and fixed-point NN inference
- `fpga/src/uart_tx.sv` - 9600 baud 8N1 UART transmitter
- `fpga/src/uart_rx.sv` - 9600 baud 8N1 UART receiver
- `fpga/src/seven_segment.sv` - active-low hex display decoder
- `fpga/flappy_bird_part_3.qsf` - DE10-Lite Quartus pin assignments
- `fpga/flappy_bird_part_3.sdc` - 50 MHz timing constraint
- `esp32/src/main.cpp` - ESP32 trainer, OLED renderer, weight uploader, and FPGA inference loop
- `esp32/platformio.ini` - ESP32 PlatformIO project

## Build

### FPGA

```powershell
cd challenge_submissions/flappy_bird_part_3/fpga
& "C:\intelFPGA_lite\17.1\quartus\bin64\quartus_sh.exe" --flow compile flappy_bird_part_3
```

### ESP32

```powershell
cd challenge_submissions/flappy_bird_part_3/esp32
$env:USERPROFILE\.platformio\penv\Scripts\pio.exe run
```

## Expected Behavior

1. Program the FPGA and flash the ESP32.
2. Wire both UART directions and common ground.
3. Leave `SW[8] = 0`; OLED shows ESP32 training mode.
4. After training improves, set `SW[8] = 1`.
5. ESP32 evaluates the archived top champions on a held-out course.
6. ESP32 uploads the selected winner's weights to FPGA.
7. OLED switches to a single bird controlled by FPGA inference responses.
8. Change `SW[3:0]` to alter obstacle difficulty.
9. In training mode, press `KEY[0]` to save a strong current bird and advance generations.
10. In FPGA inference mode, press `KEY[0]` to reset/reload the run.
