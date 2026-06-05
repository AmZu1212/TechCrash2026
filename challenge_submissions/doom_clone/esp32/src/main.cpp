// Challenge 8: DOOM Clone -- ESP32 Serial Bridge
//
// Receives 6-byte control packets from the FPGA on UART2 (GPIO17 RX, 115200 baud)
// and forwards validated packets to the PC over USB serial (115200 baud).
//
// Packet format: A5 5A SW_LO SW_HI KEYS CKSUM
//   SW_LO = SW[7:0]
//   SW_HI = {6'b0, SW[9:8]}
//   KEYS  = {6'b0, KEY1, KEY0}   (1 = pressed)
//   CKSUM = (SW_LO + SW_HI + KEYS) & 0xFF
//
// Bad-checksum packets are silently dropped.
// The PC game reads these same 6 bytes verbatim from the COM port.
//
// UART2 RX = GPIO17  <- FPGA ARDUINO_IO[1]
// UART2 TX = GPIO16  (unused)
// USB      = GPIO1/3 -> PC COM port

#include <Arduino.h>

#define FPGA_RX_PIN  17
#define FPGA_TX_PIN  16
#define FPGA_BAUD    115200

HardwareSerial FpgaSerial(2);

static const uint8_t SYNC0 = 0xA5;
static const uint8_t SYNC1 = 0x5A;
static const uint8_t PKT_LEN = 6;

enum ParseState { WAIT_A5, WAIT_5A, READ_BODY };
ParseState state = WAIT_A5;
uint8_t body[4];
uint8_t bodyIdx = 0;

void setup() {
    Serial.begin(115200);
    FpgaSerial.begin(FPGA_BAUD, SERIAL_8N1, FPGA_RX_PIN, FPGA_TX_PIN);
}

void loop() {
    while (FpgaSerial.available()) {
        uint8_t b = (uint8_t)FpgaSerial.read();

        switch (state) {
            case WAIT_A5:
                if (b == SYNC0) state = WAIT_5A;
                break;

            case WAIT_5A:
                if (b == SYNC1) { bodyIdx = 0; state = READ_BODY; }
                else if (b == SYNC0) state = WAIT_5A;
                else state = WAIT_A5;
                break;

            case READ_BODY:
                body[bodyIdx++] = b;
                if (bodyIdx == 4) {
                    state = WAIT_A5;
                    uint8_t sw_lo = body[0];
                    uint8_t sw_hi = body[1];
                    uint8_t keys  = body[2];
                    uint8_t cksum = body[3];
                    uint8_t expected = (sw_lo + sw_hi + keys) & 0xFF;
                    if (cksum == expected) {
                        // Forward the full packet (header + body) to PC
                        uint8_t pkt[6] = {SYNC0, SYNC1, sw_lo, sw_hi, keys, cksum};
                        Serial.write(pkt, 6);
                    }
                }
                break;
        }
    }
}
