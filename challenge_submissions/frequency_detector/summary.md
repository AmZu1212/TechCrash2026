# Challenge 6: Frequency Detector

**Points:** 100 (all-or-nothing)  
**Category:** Combined (FPGA + ESP32)

---

## Overview

The ESP32 reads a potentiometer, generates a sine wave at the corresponding frequency, and streams the raw samples over UART to the FPGA. The FPGA recovers the frequency using zero-crossing detection and displays it on the 7-segment displays.

---

## How It Works

### ESP32 (`esp32/src/main.cpp`)

1. Reads `PIN_ANALOG_IN` (GPIO34, 12-bit ADC).
2. Maps ADC range 0–4095 linearly to **100–2000 Hz**.
3. Generates 256 signed 8-bit samples:
   ```
   sample[i] = 127 * sin(2π * freq * i / 8000)
   ```
4. Sends all 256 bytes as a raw burst over UART2 at **115200 baud** to the FPGA (`PIN_FPGA_TX = GPIO16 → ARDUINO_IO[0]`).
5. OLED (SSD1306, 128×64) shows "Frequency Detector" header and the current frequency in large text.

### FPGA (`fpga/src/frequency_detector_top.sv`)

1. Receives 256-byte frames on `ARDUINO_IO[0]` via parameterized `uart_rx` module (115200 baud).
2. Counts **zero-crossings** (sign-bit changes between consecutive samples).
3. Computes frequency from the zero-crossing count.
4. Displays result on HEX3..0 with leading-zero blanking.

---

## Zero-Crossing Math

$$f = ZC \times \frac{F_s}{2N} = ZC \times \frac{8000}{2 \times 256} = ZC \times 15.625 \text{ Hz}$$

where:
- $ZC$ = number of sign-bit changes across the 256-byte window
- $F_s$ = 8000 Hz (sample rate)
- $N$ = 256 (window size)

The FPGA avoids floating-point by computing:

```systemverilog
wire [15:0] freq_calc = {8'd0, zc_latched} * 16'd125;
wire [10:0] freq_hz   = freq_calc[13:3];  // divide by 8 via bit-select
```

This gives `zc * 125 / 8 = zc * 15.625`.

**Maximum values:** ZC = 128 → freq = 2000 Hz (fits in 11 bits).

**Off-by-one:** Byte 0 is used only to initialize `prev_sign` — no crossing is counted for it. This causes a consistent −15.6 Hz bias (≈ 1 ZC short), which is well within the ±35 Hz accuracy requirement.

**Observed measurements:**

| Generated freq | Expected ZC | Measured ZC | Recovered freq | Error |
|---------------|-------------|-------------|----------------|-------|
| 300 Hz | 19.2 | ~18 | 281 Hz | −19 Hz |
| 1000 Hz | 64.0 | ~63 | 984 Hz | −16 Hz |
| 2000 Hz | 128.0 | ~127 | 1984 Hz | −16 Hz |

Frequency resolution per zero-crossing bin: **31.25 Hz**  
Accuracy spec: ±35 Hz — **passes** across the full range.

---

## Frame Synchronization

The ESP32 sends each 256-byte burst as a tight back-to-back block. The FPGA uses a gap timer to detect inter-frame pauses:

- Gap timeout: **5 ms** (250,000 cycles at 50 MHz)
- If no byte arrives for 5 ms while mid-frame, `byte_cnt` resets to 0 and waits for the next frame start.
- This prevents stale partial frames from corrupting the count after any UART glitch or reset.

---

## Controls & Display

| Control | Function |
|---------|----------|
| `KEY[0]` | Active-low reset |
| `SW[9]` | Debug mode (0 = freq Hz, 1 = raw ZC count) |
| `HEX3..0` | Detected frequency in Hz (e.g. `1085`) with leading-zero blanking |
| `HEX4`, `HEX5` | Blank (driven `8'hFF`) |
| `LEDR[9:0]` | Frequency bar graph |

**LED bar thresholds** (each LED adds ≈ 190 Hz):

| LED | Threshold |
|-----|-----------|
| LEDR[0] | ≥ 190 Hz |
| LEDR[1] | ≥ 380 Hz |
| LEDR[2] | ≥ 570 Hz |
| LEDR[3] | ≥ 760 Hz |
| LEDR[4] | ≥ 950 Hz |
| LEDR[5] | ≥ 1140 Hz |
| LEDR[6] | ≥ 1330 Hz |
| LEDR[7] | ≥ 1520 Hz |
| LEDR[8] | ≥ 1710 Hz |
| LEDR[9] | ≥ 1900 Hz |

---

## Source Files

| File | Purpose |
|------|---------|
| `esp32/src/main.cpp` | Potentiometer read, sine generation, UART burst, OLED display |
| `fpga/src/frequency_detector_top.sv` | Top module: UART RX, ZC detection, frequency calc, display |
| `fpga/src/uart_rx.sv` | Parameterized 8N1 UART receiver (reused from voltmeter) |
| `fpga/src/seven_segment.sv` | BCD → active-low 7-segment with blank (reused from voltmeter) |
| `fpga/src/bin_to_bcd.sv` | 11-bit binary → 4-digit BCD (double-dabble algorithm) |

---

## Build & Flash

### FPGA

```powershell
cd challenge_submissions/frequency_detector/fpga
C:\intelFPGA_lite\17.1\quartus\bin64\quartus_sh.exe --flow compile frequency_detector_top
C:\intelFPGA_lite\17.1\quartus\bin64\quartus_pgm.exe -c "USB-Blaster [USB-1]" -m JTAG -o "P;output_files/frequency_detector_top.sof"
```

### ESP32

```powershell
cd challenge_submissions/frequency_detector/esp32
$PIO = "$env:USERPROFILE\.platformio\penv\Scripts\pio.exe"
& $PIO run -t upload --upload-port COM5
& $PIO device monitor --port COM5 --baud 115200
```
