// Challenge 5: FPGA Volt-Meter -- ESP32 OLED Receiver
//
// Receives ASCII-text lines from the FPGA over UART2 (GPIO17 RX).
// Frame format (9600 8N1) -- same approach as alive_test demo:
//   "X.XX\n"  e.g. "0.40\n" = 0.40 V
//   X   = ones digit    '0'-'3'
//   '.'                 0x2E (never 0x0A -- no ambiguity with delimiter)
//   X   = tenths digit  '0'-'9'
//   X   = hundredths    '0'-'9'
//   '\n'                0x0A line delimiter
//
// Displays voltage on SSD1306 OLED as large "X.XX V" text.
// UART2 RX  = GPIO17  <- FPGA ARDUINO_IO[1] (TX)
// UART2 TX  = GPIO16  (not used by FPGA in this direction)

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

// ---- UART to FPGA ----
const int FPGA_RX_PIN  = 17;   // Receive from FPGA TX (ARDUINO_IO[1])
const int FPGA_TX_PIN  = 16;   // Not used
const int UART_BAUD    = 9600;
HardwareSerial FpgaSerial(2);  // UART2

// ---- OLED ----
const int OLED_WIDTH  = 128;
const int OLED_HEIGHT = 64;
const int OLED_ADDR   = 0x3C;
Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);

// ---- Line-receive buffer (alive_test style) ----
String fpgaLine = "";

// ---- Timeout to show "Waiting" if FPGA goes silent ----
const unsigned long FRAME_TIMEOUT_MS = 600;
unsigned long lastFrameMs = 0;
bool haveData = false;

// ---- Display helpers ----
void drawVoltage(uint8_t ones, uint8_t tenths, uint8_t hundredths) {
    display.clearDisplay();

    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.print("FPGA Voltmeter");

    display.setTextSize(3);
    display.setCursor(0, 16);
    display.print(ones);
    display.print('.');
    display.print(tenths);
    display.print(hundredths);
    display.print('V');

    display.display();
}

void drawWaiting() {
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("FPGA Voltmeter");
    display.setCursor(0, 24);
    display.println("Waiting for FPGA...");
    display.display();
}

void setup() {
    Serial.begin(115200);
    Serial.println("\n--- FPGA Volt-Meter ESP32 Receiver ---");

    // OLED init
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
        Serial.println("SSD1306 init failed");
        while (1);
    }
    display.clearDisplay();
    display.setTextSize(2);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("FPGA");
    display.println("Voltmeter");
    display.display();
    delay(800);

    // UART2: receive ASCII lines from FPGA
    FpgaSerial.begin(UART_BAUD, SERIAL_8N1, FPGA_RX_PIN, FPGA_TX_PIN);
    Serial.println("UART2 ready (GPIO17 RX), expecting ASCII \"X.XX\\n\"");

    drawWaiting();
}

void loop() {
    // ---- Accumulate characters until '\n' (alive_test pattern) ----
    while (FpgaSerial.available()) {
        char c = (char)FpgaSerial.read();

        Serial.printf("[FPGA] 0x%02X '%c'\n", (uint8_t)c,
                      (c >= 32 && c < 127) ? c : '.');

        if (c == '\n' || c == '\r') {
            // Line complete -- parse if it looks like "X.XX"
            if (fpgaLine.length() == 4
                    && fpgaLine[1] == '.') {

                char c0 = fpgaLine[0];
                char c2 = fpgaLine[2];
                char c3 = fpgaLine[3];

                // Validate: each char must be an ASCII digit
                if (c0 >= '0' && c0 <= '9'
                        && c2 >= '0' && c2 <= '9'
                        && c3 >= '0' && c3 <= '9') {

                    uint8_t ones        = (uint8_t)(c0 - '0');
                    uint8_t tenths      = (uint8_t)(c2 - '0');
                    uint8_t hundredths  = (uint8_t)(c3 - '0');

                    // Voltage must be in 0.00 - 3.29 V range
                    if (ones <= 3) {
                        lastFrameMs = millis();
                        haveData    = true;
                        drawVoltage(ones, tenths, hundredths);
                        Serial.printf("V: %u.%u%u\n",
                                      ones, tenths, hundredths);
                    } else {
                        Serial.printf("Out of range: %s\n",
                                      fpgaLine.c_str());
                    }
                } else {
                    Serial.printf("Non-digit chars: %s\n",
                                  fpgaLine.c_str());
                }
            } else if (fpgaLine.length() > 0) {
                Serial.printf("Bad line length/format: \"%s\"\n",
                              fpgaLine.c_str());
            }

            fpgaLine = "";   // Reset for next line

        } else if (fpgaLine.length() < 8) {
            // Accumulate (cap at 8 to guard against runaway)
            fpgaLine += c;
        }
    }

    // ---- Blank display if FPGA goes silent ----
    if (haveData && (millis() - lastFrameMs > FRAME_TIMEOUT_MS)) {
        haveData = false;
        drawWaiting();
    }
}
