# Digital Volt-meter

ESP32 reads a potentiometer voltage and displays it on an OLED screen. The voltage is also sent to the FPGA, which displays it on 7-segment displays and shows a proportional LED bar graph.

## How It Works

1. ESP32 continuously reads the potentiometer on GPIO34 (ADC) and converts the 12-bit raw value to voltage (0-3.3V)
2. Voltage is displayed on the OLED screen in large text (e.g., "1.65V")
3. Every 100ms, ESP32 sends a 5-byte binary frame over UART2 (GPIO16) containing:
   - Byte 0: Ones digit (BCD, 0-3)
   - Byte 1: Tenths digit (BCD, 0-9)
   - Byte 2: Hundredths digit (BCD, 0-9)
   - Byte 3: LED bar bits [7:0]
   - Byte 4: LED bar bits [9:8] (2 bits used)
4. FPGA receives the serial stream on GPIO[0] at 9600 baud
5. When all 5 bytes are collected, they are latched to the output registers
6. The digit values are sent to 7-segment decoders on HEX2:HEX0 (X.YZ format)
7. The LED bar bits (10-bit value) are output directly to LEDR[9:0]
8. LED thresholds: 0.3V per LED, so LED[i] lights at voltage ≥ (i+1) × 0.3V

## Wiring

| Component | Pin | Wire | DE10-Lite/ESP32 Pin | Function |
|-----------|-----|------|---------------------|----------|
| Potentiometer | Wiper | → | ESP32 GPIO34 | Analog voltage input |
| Potentiometer | +3.3V | — | ESP32 3.3V | Power |
| Potentiometer | GND | — | ESP32 GND | Ground |
| ESP32 | GPIO16 | → | Arduino IO0 (GPIO[0]) | UART TX → RX |
| ESP32 | SDA (GPIO21) | → | OLED SDA | I2C Clock (if using OLED) |
| ESP32 | SCL (GPIO22) | → | OLED SCL | I2C Data (if using OLED) |
| ESP32 | GND | — | Arduino GND | Common ground |

**Note:** 3 wires minimum (POT wiper + GND, UART TX). Add OLED connections if using the I2C display (4 more wires: SDA, SCL, +3.3V, GND). All boards run at 3.3V logic, no level shifter required.

## Reset

Flip `SW[9]` down (0) then up (1) to reset the FPGA parser. All displays will blank until the next valid voltage frame arrives.

## Project Files

- **esp32/src/main.cpp** — ADC reader + OLED display, calculates digits and LED bar, sends 5-byte binary frame over UART2 every 100ms
- **fpga/src/digital_voltmeter_top.sv** — Top module: UART RX, 5-byte frame accumulator, 7-segment driver, LED bar output
- **fpga/src/uart_rx.sv** — Parameterized UART receiver (50 MHz, 9600 baud, 8N1)
- **fpga/src/seven_segment.sv** — BCD to active-low 7-segment decoder with blank input
- **esp32/platformio.ini** — PlatformIO config (ESP32, Arduino framework, Adafruit SSD1306 library)
- **fpga/digital_voltmeter_top.qsf** — Quartus pin assignments for DE10-Lite

## Build & Flash

### FPGA
```bash
cd challenge_submissions/digital_voltmeter/fpga
quartus_sh --flow compile digital_voltmeter_top
quartus_pgm -c "USB-Blaster [USB-1]" -m JTAG -o "P;output_files/digital_voltmeter_top.sof"
```

### ESP32
```bash
cd challenge_submissions/digital_voltmeter/esp32
pio run -t upload
pio device monitor
```

## Expected Behavior

- After power-on, 7-segment displays are blank (waiting for first valid frame)
- Potentiometer at GND shows ~0.00V on OLED and displays, 0 LEDs lit
- Potentiometer at 3.3V shows ~3.30V on OLED and displays, all 10 LEDs lit
- OLED shows voltage updated continuously as you adjust the potentiometer
- 7-segment displays and LED bar graph update every 100ms with new frame arrival
- ESP32 serial monitor (115200 baud) shows raw ADC, voltage, and LED bar state

## Customization Ideas

- Change `SEND_INTERVAL_MS` in main.cpp to send faster or slower
- Adjust LED threshold increments (currently 0.3V per LED)
- Add a second ADC input on another GPIO for dual voltage readout
- Use HEX5:HEX4 for millivolts or a separate sensor input
- Add analog smoothing (moving average) in ESP32 to reduce noise

## Troubleshooting

- **OLED not showing:** Check I2C address (default 0x3C). Use I2C scanner to find the actual address.
- **Displays blank:** Verify UART wiring (ESP32 GPIO16 → FPGA Arduino IO0). Check SW[9] is high (1).
- **LED bar not responding:** Ensure ESP32 LED calculation is correct (check serial monitor output). Verify all 5 bytes are received by FPGA.
- **Potentiometer reads 0 or 4095 always:** Verify ADC is in input-only mode (GPIO34) and not used for WiFi I/O.
- **Frames arriving but displays not updating:** Check byte_cnt state machine in FPGA (may be stuck). Verify frame_valid signal goes high after 5 bytes.
