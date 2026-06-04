// Challenge 5: FPGA Volt-Meter -- ESP32 OLED Receiver
//
// Receives 5-byte binary frames from the FPGA over UART2 (GPIO17 RX).
// Frame format (9600 8N1):
//   Byte 0: Ones digit (BCD 0-3)
//   Byte 1: Tenths digit (BCD 0-9)
//   Byte 2: Hundredths digit (BCD 0-9)
//   Byte 3: LED bar bits [7:0]
//   Byte 4: LED bar bits [9:8]
//
// Displays voltage on SSD1306 OLED as large "X.XX V" text.
// UART2 RX  = GPIO17  <- FPGA ARDUINO_IO[1] (TX)
// UART2 TX  = GPIO16  (unused, pulled high internally)

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

// ---- UART to FPGA ----
const int FPGA_RX_PIN  = 17;   // Receive from FPGA TX (ARDUINO_IO[1])
const int FPGA_TX_PIN  = 16;   // Not used (FPGA does not receive here)
const int UART_BAUD    = 9600;
HardwareSerial FpgaSerial(2);  // UART2

// ---- OLED ----
const int OLED_WIDTH  = 128;
const int OLED_HEIGHT = 64;
const int OLED_ADDR   = 0x3C;
Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);

// ---- Frame state ----
uint8_t  frameBuf[5];
int      frameIdx = 0;

// Decoded values (updated each complete frame)
uint8_t  digOnes = 0, digTenths = 0, digHundredths = 0;
uint16_t ledBits = 0;

// ---- Timeout to blank display if no frame received ----
const unsigned long FRAME_TIMEOUT_MS = 500;
unsigned long lastFrameMs = 0;
bool haveData = false;

// ---- Display helper ----
void drawVoltage(uint8_t ones, uint8_t tenths, uint8_t hundredths) {
    display.clearDisplay();

    // Large voltage text
    display.setTextSize(3);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 12);
    display.print(ones);
    display.print('.');
    display.print(tenths);
    display.print(hundredths);
    display.print('V');

    // Small label at top
    display.setTextSize(1);
    display.setCursor(0, 0);
    display.print("FPGA Voltmeter");

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

    // UART2 from FPGA
    FpgaSerial.begin(UART_BAUD, SERIAL_8N1, FPGA_RX_PIN, FPGA_TX_PIN);
    Serial.println("UART2 ready (GPIO17 RX)");

    drawWaiting();
}

void loop() {
    // Consume all available UART bytes, building 5-byte frames
    while (FpgaSerial.available()) {
        uint8_t b = FpgaSerial.read();
        frameBuf[frameIdx++] = b;

        if (frameIdx == 5) {
            // Complete frame
            frameIdx = 0;

            uint8_t  ones        = frameBuf[0] & 0x0F;
            uint8_t  tenths      = frameBuf[1] & 0x0F;
            uint8_t  hundredths  = frameBuf[2] & 0x0F;
            uint16_t led         = (uint16_t)(frameBuf[3])
                                 | ((uint16_t)(frameBuf[4] & 0x03) << 8);

            // Validate: voltage must be 0.00 - 3.29 (ones 0-3)
            if (ones <= 3) {
                digOnes        = ones;
                digTenths      = tenths;
                digHundredths  = hundredths;
                ledBits        = led;
                lastFrameMs    = millis();
                haveData       = true;

                drawVoltage(digOnes, digTenths, digHundredths);

                Serial.printf("V: %u.%u%u  LED: 0x%03X\n",
                              digOnes, digTenths, digHundredths, ledBits);
            } else {
                // Out-of-range frame: re-sync by discarding
                Serial.printf("Bad frame: 0x%02X 0x%02X 0x%02X 0x%02X 0x%02X\n",
                              frameBuf[0], frameBuf[1], frameBuf[2],
                              frameBuf[3], frameBuf[4]);
            }
        }
    }

    // Blank display if no frame received recently
    if (haveData && (millis() - lastFrameMs > FRAME_TIMEOUT_MS)) {
        haveData = false;
        drawWaiting();
    }
}
