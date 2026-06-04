# Press Right

Stop a fast-running counter at exactly 1000 (10.00 s). The FPGA counts 0–9999 in real time; pressing KEY[0] freezes it and the ESP32 OLED shows whether you won.

## How It Works

1. On power-on the FPGA sits in IDLE — 7-segment displays are blank and the counter is at 0.
2. Press **KEY[0]** once to start the counter. It increments every 10 ms (0 → 9999 in ~100 s), displayed live on HEX3–HEX0.
3. Press **KEY[0]** again to freeze the counter. The FPGA:
   - Latches the counter value and transmits it as `"XXXX\n"` ASCII over UART every 100 ms.
   - Lights the LED bar graph to show how close you are to 1000.
4. The ESP32 receives the value and displays the result on the OLED:
   - **WIN!** if the count is 990–1010 (within ±10 of 1000). Plays a short victory jingle.
   - **MISS** otherwise, with the delta shown (e.g. `Off by +234`).
5. Press **KEY[0]** a third time (in STOPPED state) to reset back to IDLE.

### LED Bar Graph (LEDR[9:0])

Shows proximity to 1000 while stopped. Each LED represents ±20 counts:

| LEDs lit | Distance from 1000 |
|----------|--------------------|
| 10       | ≤ ±20              |
| 9        | ≤ ±40              |
| …        | …                  |
| 1        | ≤ ±200             |
| 0        | > ±200             |

## Wiring

| Component | Pin | Wire | DE10-Lite / ESP32 Pin | Function |
|-----------|-----|------|-----------------------|----------|
| DE10-Lite | ARDUINO_IO[1] (PIN_AB6) | → | ESP32 GPIO17 | UART TX (FPGA) → UART RX (ESP32) |
| Buzzer (+) | — | → | ESP32 GPIO19 | PWM tone output |
| Buzzer (−) | — | → | ESP32 GND | Ground |
| ESP32 | GPIO21 (SDA) | → | OLED SDA | I2C data |
| ESP32 | GPIO22 (SCL) | → | OLED SCL | I2C clock |
| ESP32 | 3.3V | → | OLED VCC | OLED power |
| ESP32 | GND | → | OLED GND | Common ground |

**Note:** Only 1 UART wire is needed (FPGA TX → ESP32 RX). The ESP32 does not transmit back to the FPGA. All signals are 3.3 V logic.

## Reset

Flip `SW[9]` down (0) then back up (1) to fully reset the FPGA state machine. The OLED will return to the "Waiting for FPGA…" screen automatically when UART frames stop arriving (2 s timeout).

## Project Files

- **fpga/src/press_right_top.sv** — Top module: game state machine (IDLE/RUNNING/STOPPED), 10 ms tick counter, 7-segment display driver, proximity LED bar, inline UART TX FSM
- **fpga/press_right.qsf** — Quartus pin assignments for DE10-Lite
- **fpga/press_right.qpf** — Quartus project file
- **esp32/src/main.cpp** — UART2 ASCII-line receiver, OLED result display, non-blocking victory jingle (passive buzzer on GPIO19)
- **esp32/platformio.ini** — PlatformIO config (ESP32 DOIT DevKit V1, Arduino framework, Adafruit SSD1306 library)

## Build & Flash

### FPGA
```powershell
cd challenge_submissions/press_right/fpga
quartus_sh.exe --flow compile press_right
quartus_pgm.exe -c "USB-Blaster [USB-1]" -m JTAG -o "P;output_files/press_right.sof"
```

### ESP32
```powershell
cd challenge_submissions/press_right/esp32
& "$env:USERPROFILE\.platformio\penv\Scripts\pio.exe" run -t upload --upload-port COM5
& "$env:USERPROFILE\.platformio\penv\Scripts\pio.exe" device monitor --port COM5 --baud 115200
```

## Expected Behaviour

- After power-on (SW[9] = 1), OLED shows `=== PRESS RIGHT ===` / "Stop it at 1000!". FPGA displays are blank.
- Pressing KEY[0] starts the counter; HEX3–HEX0 count up from 0000 live.
- Pressing KEY[0] again freezes the display and sends the value to the ESP32.
- WIN (990–1010): OLED shows the count + "WIN!" + "** You win! **" and plays the victory jingle once.
- MISS: OLED shows the count + "MISS" + "Off by ±N".
- LED bar fills toward 10 LEDs as you get closer to exactly 1000.
- Pressing KEY[0] a third time returns to IDLE; OLED returns to waiting screen after 2 s.

## Troubleshooting

- **OLED blank / not starting:** Press the EN (Reset) button on the ESP32 — the board may have booted into download mode.
- **OLED stuck on "Waiting for FPGA…":** Verify the UART wire (FPGA ARDUINO_IO[1] → ESP32 GPIO17). Check SW[9] is up (1). Open the serial monitor at 115200 baud; you should see `[FPGA]` lines when the counter is stopped.
- **Jingle plays wrong / no sound:** Confirm the passive buzzer is on ESP32 GPIO19. Active buzzers (with internal oscillator) ignore `tone()` frequency — use a passive one.
- **Counter not starting:** KEY[0] is active-low with a 20 ms debounce. Press and release firmly. SW[9] must be high (1) for the FPGA to be out of reset.
- **LED bar not responding:** Only lights in STOPPED state. Ensure you have pressed KEY[0] twice (start then stop).
