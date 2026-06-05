# Part 1/2/3 Integration Notes

## Shared Game Contract

- `BIRD_X = 22`
- `BIRD_W = 5`
- `BIRD_H = 4`
- `PIPE_W = 8`
- `HUD_H = 9`
- gravity adds `0.22` velocity per frame
- flap impulse sets velocity to `-2.45`
- max falling velocity is `2.8`
- active gameplay HUD is `SCORE:###  Diff: ##` plus a one-pixel separator line
- difficulty `0..15` maps to:
  - gap size `max(13, 28 - difficulty)`
  - pipe speed `1.0 + difficulty * 0.16`

Part 2 and Part 3 now use the same bird rectangle collision and pipe-passing rule as Part 1. That means the neural network trains against the same game surface that manual control uses.

The original Flappy Bird proportions are roughly a 34x24 bird, 52-pixel pipe width, and about a 100-pixel gap on a 288x512 playfield. On the 128x64 OLED we cannot preserve the original portrait screen scale exactly, so these constants prioritize the local ratios: gap is about 4.25x bird height at easiest difficulty, pipe width is 1.6x bird width, and gap height is about 2.1x pipe width.

## Neural Network Contract

Each model is a 4-4-1 network:

```text
inputs:
0 bird top normalized to playfield height
1 bird vertical velocity / 4
2 distance from bird to next pipe right edge / screen width
3 bird center vertical offset from gap center / screen height
```

The ESP32 trains with float weights and `tanh` hidden activation. The FPGA receives signed 8-bit fixed-point weights and uses a hard-tanh hidden approximation. This is not bit-identical to ESP32 inference, but it preserves the same input order, weight order, sign, and decision threshold.

## Training Archive Choice

Because there is no known final generation count, the ESP32 stores the best 10 generation champions by rightward progress, not merely the last 10. When FPGA mode is selected, those archived champions race together on a held-out deterministic course. The winner of that race is uploaded to the FPGA.

## UART Contract

FPGA to ESP32:

```text
0xA5 TYPE VALUE CHECKSUM
```

ESP32 to FPGA:

```text
0x5A 0x11 0x00 25 CHECKSUM          load begin
0x5A 0x10 INDEX SIGNED_WEIGHT CHECKSUM
0x5A 0x20 SEQ IN0 IN1 IN2 IN3 CHECKSUM
```

The load-begin packet clears the FPGA loaded-weight counter before a new model upload. The FPGA reports inference responses as `{state_seq[6:0], flap}`.

## Remaining Hardware Checks

- Confirm ESP32 GPIO16 to FPGA `ARDUINO_IO[0]` and FPGA `ARDUINO_IO[1]` to ESP32 GPIO17 are crossed correctly.
- Confirm 9600 baud remains stable in both directions.
- Confirm FPGA mode switch `SW[8]` reaches ESP32 and triggers archive evaluation plus weight upload.
- Compare FPGA-controlled bird behavior against ESP32 float inference; differences are expected from fixed-point quantization and hard-tanh approximation, but it should still react to pipe/gap geometry.
