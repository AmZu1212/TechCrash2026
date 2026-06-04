# Speed Loopback Implementation Notes

## Do Not Modify

These are the challenge's fixed FPGA infrastructure and should stay behaviorally unchanged:

- `total_count = 10_000`
- LFSR seed, feedback polynomial, and byte sequence
- FPGA checksum accumulator
- FPGA millisecond timer
- FPGA pass/fail comparator
- Top-level transfer state sequence: idle, header, data, wait for checksum, done
- One checksum byte returned by ESP32 as `sum & 0xFF`

## Allowed Changes

The challenge explicitly allows changing the communication path:

- Replace or tune UART TX/RX modules
- Change UART baud rate
- Add more UART channels
- Use SPI or parallel GPIO
- Rewrite ESP32 firmware
- Use Arduino header or JP1 GPIO pins

## Current Strategy

Use the starter wiring and protocol, but raise the UART speed from `9600` to `921600` baud.

Expected raw transfer time:

```text
10,004 bytes * 10 bits / 921600 baud ~= 109 ms
```

This is about a 95x theoretical speedup over the 9600 baud starter, while keeping the wiring simple.
