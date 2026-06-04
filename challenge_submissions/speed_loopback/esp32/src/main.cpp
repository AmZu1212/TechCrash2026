// Speed Loopback -- ESP32 fast UART implementation
// Receives N random bytes from FPGA, sums them, sends back sum & 0xFF.
//
// Protocol is unchanged from the starter:
//   FPGA -> ESP32: 4-byte little-endian count, then N data bytes
//   ESP32 -> FPGA: 1-byte checksum

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "../../../../projects/common/esp32/pin_config.h"

static const uint32_t FAST_UART_BAUD = 921600;
static const uint32_t EXPECTED_N = 10000;
static const uint32_t HEADER_TIMEOUT_MS = 30000;
static const uint32_t DATA_TIMEOUT_MS = 2000;
static const size_t RX_BUFFER_BYTES = 16384;

Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);
HardwareSerial FpgaSerial(2);
bool oledOk = false;

void drawStatus(const char* line1, const char* line2 = nullptr, uint32_t value = 0) {
    if (!oledOk) return;

    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Speed Loopback");
    display.println("UART 921600");
    display.drawFastHLine(0, 20, 128, SSD1306_WHITE);
    display.setCursor(0, 28);
    display.println(line1);
    if (line2) {
        display.setCursor(0, 42);
        display.printf(line2, value);
    }
    display.display();
}

bool waitForBytes(size_t count, uint32_t timeoutMs) {
    uint32_t start = millis();
    while ((size_t)FpgaSerial.available() < count) {
        if (millis() - start > timeoutMs) {
            return false;
        }
        yield();
    }
    return true;
}

bool readHeader(uint32_t& n) {
    if (!waitForBytes(4, HEADER_TIMEOUT_MS)) {
        return false;
    }

    n = 0;
    n |= (uint32_t)(uint8_t)FpgaSerial.read();
    n |= (uint32_t)(uint8_t)FpgaSerial.read() << 8;
    n |= (uint32_t)(uint8_t)FpgaSerial.read() << 16;
    n |= (uint32_t)(uint8_t)FpgaSerial.read() << 24;
    return true;
}

bool receiveAndSum(uint32_t n, uint32_t& sum, uint32_t& received) {
    sum = 0;
    received = 0;

    uint32_t lastByteMs = millis();
    while (received < n) {
        int available = FpgaSerial.available();
        if (available <= 0) {
            if (millis() - lastByteMs > DATA_TIMEOUT_MS) {
                return false;
            }
            yield();
            continue;
        }

        while (available-- > 0 && received < n) {
            int b = FpgaSerial.read();
            if (b < 0) break;
            sum += (uint8_t)b;
            received++;
            lastByteMs = millis();
        }
    }

    return true;
}

void setup() {
    Serial.begin(115200);
    delay(300);
    Serial.println();
    Serial.println("--- Speed Loopback Fast UART ---");
    Serial.printf("UART2 baud: %lu\n", (unsigned long)FAST_UART_BAUD);

    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    oledOk = display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR);

    FpgaSerial.setRxBufferSize(RX_BUFFER_BYTES);
    FpgaSerial.begin(FAST_UART_BAUD, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);

    drawStatus("Waiting for FPGA...");
}

void loop() {
    uint32_t n = 0;
    if (!readHeader(n)) {
        return;
    }

    uint32_t startUs = micros();
    Serial.printf("Receiving %lu bytes...\n", (unsigned long)n);

    if (n != EXPECTED_N) {
        Serial.printf("Unexpected N=%lu, expected %lu\n",
                      (unsigned long)n, (unsigned long)EXPECTED_N);
        drawStatus("Bad header", "N=%lu", n);
        return;
    }

    uint32_t sum = 0;
    uint32_t received = 0;
    bool ok = receiveAndSum(n, sum, received);

    uint8_t checksum = (uint8_t)(sum & 0xFF);
    if (ok) {
        FpgaSerial.write(checksum);
        FpgaSerial.flush();
    }

    uint32_t elapsedUs = micros() - startUs;

    Serial.printf("Done ok=%d received=%lu sum=0x%08lX checksum=0x%02X elapsed=%lu us\n",
                  ok ? 1 : 0,
                  (unsigned long)received,
                  (unsigned long)sum,
                  checksum,
                  (unsigned long)elapsedUs);

    if (ok) {
        drawStatus("Complete", "ESP us:%lu", elapsedUs);
    } else {
        drawStatus("RX timeout", "Rcvd:%lu", received);
    }
}
