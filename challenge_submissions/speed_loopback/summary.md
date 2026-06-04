# Speed Loopback Fast UART

This submission keeps the starter protocol and fixed FPGA infrastructure, but raises the UART link from 9600 baud to 921600 baud.

## Strategy

- FPGA still generates exactly 10,000 bytes from the same LFSR sequence.
- FPGA still accumulates the same checksum and uses the same timer/pass/fail logic.
- FPGA still sends the 4-byte little-endian count header followed by the data bytes.
- ESP32 still returns one checksum byte: `sum & 0xFF`.
- UART baud is changed to `921600` on both FPGA TX/RX and ESP32 UART2.
- ESP32 does not update the OLED during the receive loop, avoiding display overhead during the timed transfer.

## Expected Speed

Raw UART time at 921600 baud:

```text
10,004 bytes * 10 bits / 921600 baud ~= 109 ms
```

This is about 95x faster than the 9600 baud starter before software overhead.

## Wiring

Same as the starter:

| Direction | FPGA | ESP32 |
|-----------|------|-------|
| FPGA -> ESP32 | ARDUINO_IO[1] | GPIO17 RX |
| ESP32 -> FPGA | ARDUINO_IO[0] | GPIO16 TX |
| Ground | Arduino GND | ESP32 GND |

## Build

### FPGA

```powershell
cd challenge_submissions/speed_loopback/fpga
& "C:\intelFPGA_lite\17.1\quartus\bin64\quartus_sh.exe" --flow compile speed_loopback_top
```

### ESP32

```powershell
cd challenge_submissions/speed_loopback/esp32
$env:USERPROFILE\.platformio\penv\Scripts\pio.exe run
```

## Expected Behavior

1. Program the FPGA and flash the ESP32.
2. Press `KEY[0]` on the FPGA to start.
3. FPGA sends 10,000 bytes to ESP32.
4. ESP32 computes the checksum and immediately sends it back.
5. FPGA stops the timer and displays elapsed milliseconds.
6. `LEDR[0]` means pass, `LEDR[1]` means fail.

If the result is unstable at 921600 baud, reduce `UART_BAUD` in `fpga/src/speed_loopback_top.sv` and `FAST_UART_BAUD` in `esp32/src/main.cpp` to `460800`.
