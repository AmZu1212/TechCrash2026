# FPGA Volt-Meter

The FPGA reads a potentiometer voltage using its internal MAX10 ADC and displays it on 7-segment displays and an LED bar graph. The voltage is also sent to the ESP32, which displays it on an OLED screen.

## How It Works

1. The MAX10 internal ADC (Channel 1 = Arduino header A0) runs in free-running mode, continuously converting the analog voltage on the potentiometer wiper
2. Each ADC result (12-bit, full-scale = 5.00 V VCCADC) is scaled to centvolts (0.01 V units): `v_cV = (raw × 500) >> 12`
3. The voltage is split into digits (ones, tenths, hundredths) and displayed on HEX2:HEX0 in X.XX format with the decimal point lit on HEX2
4. LEDR[9:0] shows a bar graph — LED[i] lights up when voltage ≥ (i+1) × 0.30 V, so all 10 LEDs light at 3.00 V
5. Every 100 ms, the FPGA transmits an ASCII line over UART (ARDUINO_IO[1], 9600 8N1):
   - Format: `"X.XX\n"` — e.g. `"1.23\n"` for 1.23 V
   - The newline (`\n`) acts as a self-synchronising frame delimiter
6. The ESP32 receives the ASCII line on UART2 (GPIO17 RX), parses it, and shows the voltage in large text on the OLED

## Wiring

| Component | Pin | Wire | DE10-Lite / ESP32 Pin | Function |
|-----------|-----|------|-----------------------|----------|
| Potentiometer | Wiper | → | Arduino A0 (ARDUINO_IO header) | Analog voltage input (0–3.3 V) |
| Potentiometer | +3.3V | — | DE10-Lite 3.3V | Power |
| Potentiometer | GND | — | Arduino GND | Ground |
| DE10-Lite | ARDUINO_IO[1] | → | ESP32 GPIO17 | UART TX (FPGA) → UART RX (ESP32) |
| ESP32 | GPIO21 (SDA) | → | OLED SDA | I2C data |
| ESP32 | GPIO22 (SCL) | → | OLED SCL | I2C clock |
| ESP32 | GND | — | Arduino GND | Common ground |

**Note:** Only 1 wire needed for UART (FPGA TX → ESP32 RX). The ESP32 does not transmit back to the FPGA. Add OLED wiring (SDA, SCL, 3.3V, GND) for the display. All signals are 3.3 V logic — no level shifter required.

## Reset

Flip `SW[9]` down (0) then back up (1) to reset the FPGA. All displays blank until the next ADC conversion completes (< 1 ms). Use the EN button on the ESP32 to reboot it if the OLED is blank after power-on.

## Project Files

- **fpga/src/digital_voltmeter_top.sv** — Top module: PLL, MAX10 ADC, voltage scaling, 7-segment driver, LED bar graph, UART TX FSM
- **fpga/src/uart_tx.sv** — Parameterised UART transmitter (50 MHz, 9600 baud, 8N1)
- **fpga/src/adc_pll.v** — ALTPLL wrapper (50 MHz → 50 MHz); required because the MAX10 ADC clock input must come from a PLL C-counter output
- **fpga/src/seven_segment.sv** — BCD to active-low 7-segment decoder with blank input
- **fpga/digital_voltmeter_top.qsf** — Quartus pin assignments for DE10-Lite
- **esp32/src/main.cpp** — UART2 ASCII-line receiver, OLED display (Adafruit SSD1306)
- **esp32/platformio.ini** — PlatformIO config (ESP32 DOIT DevKit V1, Arduino framework, Adafruit SSD1306 library)

## Build & Flash

### FPGA
```powershell
cd challenge_submissions/voltmeter_FPGA/fpga
quartus_sh.exe --flow compile digital_voltmeter_top
quartus_pgm.exe -c "USB-Blaster [USB-1]" -m JTAG -o "P;output_files/digital_voltmeter_top.sof"
```

### ESP32
```powershell
cd challenge_submissions/voltmeter_FPGA/esp32
pio run -t upload --upload-port COM5
pio device monitor --port COM5 --baud 115200
```

## Expected Behaviour

- After power-on, 7-segment displays show 0.00 V and no LEDs light until the potentiometer is turned
- Turning the potentiometer from GND to 3.3 V sweeps the display from 0.00 V to ~3.30 V
- The LED bar graph fills progressively: each LED lights at an additional 0.30 V
- The OLED shows the same voltage in large text, updated every 100 ms
- Serial monitor (115200 baud) on the ESP32 prints each received line, e.g. `V: 1.23`

## Troubleshooting

- **OLED blank / not starting:** Press the EN (Reset) button on the ESP32 — the board may have booted into download mode if the serial monitor opened during power-on.
- **7-segment displays blank:** Check `SW[9]` is up (1) to deassert reset. If stuck, toggle SW[9] down then up.
- **OLED shows "Waiting for FPGA…" indefinitely:** Verify the UART wire (FPGA ARDUINO_IO[1] → ESP32 GPIO17). Check the FPGA is programmed and running (LEDR or HEX should respond to the potentiometer). Open the ESP32 serial monitor and look for `[FPGA]` lines.
- **Wrong voltage reading:** Confirm the potentiometer wiper connects to Arduino A0 on the DE10-Lite header, not to an ESP32 pin. The ADC full-scale is 5 V (VCCADC on DE10-Lite), so readings above 3.3 V are clamped by the analog input protection diode.
- **Voltage frozen or not updating:** The ADC runs free-running (SOC tied HIGH) — if the reading is stuck, toggle SW[9] to reset the FPGA logic.
