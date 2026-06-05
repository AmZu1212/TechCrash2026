# Flappy Bird Part 2

Challenge 9 Milestone 2: ESP32 neural-network training for Flappy Bird.

## What It Does

- ESP32 trains a neural Flappy Bird population and shows throttled monochrome status on the SSD1306 OLED.
- Each generation uses a population of 64 birds, safely above the 30-bird requirement.
- Each bird owns a small neural network with 4 inputs, 4 hidden neurons, and 1 output.
- Inputs are bird height, bird velocity, distance to the next pipe, and vertical distance to the gap.
- Output decides whether that bird flaps on the current frame.
- The training physics match Part 1: 5x4 bird, 8-pixel pipes, same gravity, same flap impulse, same pipe scoring, same collision shape.
- Every generation uses the same deterministic obstacle course so birds are compared fairly.
- Fitness rewards rightward progress, passed pipes, and staying near the pipe gap.
- The top birds survive into the next generation and the rest are mutated from those elites.
- The best champion from each generation records its progress score and delta from the previous generation.
- The best 10 generation champions are archived by progress for later held-out evaluation in Part 3.
- OLED updates are throttled to avoid making display refresh the training bottleneck.
- OLED displays generation, alive count, difficulty, last champion progress, progress delta, pipe score, and archive count.
- The actual gameplay HUD contract for Parts 1 and 3 stays minimal: only score plus a one-pixel separator.
- FPGA reads `SW[3:0]` as difficulty and sends it to ESP32 over UART.
- FPGA reads `KEY[0]` as a training reset command.
- FPGA displays the selected difficulty on `HEX1:HEX0` as `d<hex>`.

## UART Protocol

FPGA sends 4-byte binary packets at 9600 baud:

```text
0xA5 TYPE VALUE CHECKSUM
```

Packet types:

```text
TYPE 0x01: reset training, VALUE = current difficulty
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

ESP32 TX is not required for Part 2.

## Project Files

- `fpga/src/flappy_bird_part_2_top.sv` - FPGA difficulty/reset controller and UART packet sender
- `fpga/src/uart_tx.sv` - 9600 baud 8N1 UART transmitter
- `fpga/src/seven_segment.sv` - active-low hex display decoder
- `fpga/flappy_bird_part_2.qsf` - DE10-Lite Quartus pin assignments
- `fpga/flappy_bird_part_2.sdc` - 50 MHz timing constraint
- `esp32/src/main.cpp` - OLED neural training simulation and UART packet parser
- `esp32/platformio.ini` - ESP32 PlatformIO project

## Build

### FPGA

```powershell
cd challenge_submissions/flappy_bird_part_2/fpga
& "C:\intelFPGA_lite\17.1\quartus\bin64\quartus_sh.exe" --flow compile flappy_bird_part_2
```

### ESP32

```powershell
cd challenge_submissions/flappy_bird_part_2/esp32
$env:USERPROFILE\.platformio\penv\Scripts\pio.exe run
```

## Expected Behavior

1. Program the FPGA and flash the ESP32.
2. Wire FPGA `ARDUINO_IO[1]` to ESP32 GPIO17 and connect common ground.
3. OLED shows throttled training stats instead of spending frame time on detailed drawing.
4. Birds improve through generations by keeping the best networks and mutating them.
5. Serial output reports the picked champion's progress and its delta from the previous generation.
6. Change `SW[3:0]`; the FPGA display changes and training restarts for the new difficulty.
7. Press `KEY[0]` to reset training with the current difficulty.
