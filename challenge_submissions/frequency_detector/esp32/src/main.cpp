// Challenge 6: Frequency Detector -- ESP32 side
//
// Reads potentiometer on PIN_ANALOG_IN (GPIO34).
// Maps ADC 0-4095 → 100-2000 Hz.
// Generates 256 signed 8-bit samples of a sine wave at 8000 Hz sample rate.
// Sends all 256 bytes over UART2 at 115200 baud to FPGA (ARDUINO_IO[0]).
// Displays the current frequency on the SSD1306 OLED.
//
// FPGA uses zero-crossing detection on the 256-sample window to recover freq.
// Frequency resolution ≈ 31 Hz  (= 8000 / 256)

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <math.h>
#include "../../../../projects/common/esp32/pin_config.h"

#define FREQ_BAUD    115200
#define SAMPLE_RATE  8000
#define NUM_SAMPLES  256
#define FREQ_MIN     100
#define FREQ_MAX     2000

HardwareSerial FpgaSerial(2);
Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);

static int8_t sineBuffer[NUM_SAMPLES];

void generateSine(float freqHz) {
    for (int i = 0; i < NUM_SAMPLES; i++) {
        sineBuffer[i] = (int8_t)(127.0f * sinf(2.0f * PI * freqHz * i / (float)SAMPLE_RATE));
    }
}

void setup() {
    Serial.begin(115200);
    delay(300);
    Serial.println("--- Challenge 6: Frequency Detector ---");

    analogSetAttenuation(ADC_11db);

    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        Serial.println("SSD1306 init failed");
        while (true) delay(1000);
    }
    display.clearDisplay();
    display.setTextSize(2);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Freq Det");
    display.setTextSize(1);
    display.println("Initializing...");
    display.display();

    FpgaSerial.begin(FREQ_BAUD, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);
    Serial.println("UART2 ready: TX GPIO16 -> FPGA ARDUINO_IO[0]");
    delay(200);
}

void loop() {
    // Read potentiometer (12-bit ADC, 0-4095)
    int raw = analogRead(PIN_ANALOG_IN);

    // Map to 100-2000 Hz
    float freq = FREQ_MIN + (raw * (float)(FREQ_MAX - FREQ_MIN)) / 4095.0f;
    int freqInt = (int)roundf(freq);

    // Generate and send 256 samples
    generateSine(freq);
    FpgaSerial.write((const uint8_t*)sineBuffer, NUM_SAMPLES);

    // Update OLED
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Frequency Detector");
    display.drawFastHLine(0, 10, 128, SSD1306_WHITE);
    display.setTextSize(3);
    display.setCursor(10, 18);
    display.print(freqInt);
    display.setTextSize(2);
    display.setCursor(10, 48);
    display.print("Hz");
    display.display();

    Serial.printf("ADC=%4d  freq=%4d Hz\n", raw, freqInt);
}

