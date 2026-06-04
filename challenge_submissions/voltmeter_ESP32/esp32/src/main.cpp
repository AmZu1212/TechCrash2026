// Digital Volt-meter -- ESP32 ADC + OLED + FPGA Display
// Reads potentiometer on GPIO34 (ADC), displays on OLED and sends to FPGA
// UART2 TX = GPIO16 -> FPGA ARDUINO_IO[0]
// Baud: 9600, 8N1
//
// Protocol: 5-byte binary frame every 100ms
//   Byte 0: Ones digit (BCD 0-3)
//   Byte 1: Tenths digit (BCD 0-9)
//   Byte 2: Hundredths digit (BCD 0-9)
//   Byte 3: LED bar bits [7:0]
//   Byte 4: LED bar bits [9:8] (only 2 bits used)

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

// ---- Pin Configuration ----
const int ANALOG_PIN = 34;        // Potentiometer ADC input
const int UART_TX_PIN = 16;       // UART2 TX to FPGA
const int UART_RX_PIN = 17;       // UART2 RX (not used)
const int UART_BAUD = 9600;

// ---- OLED Configuration ----
const int OLED_WIDTH = 128;
const int OLED_HEIGHT = 64;
const int OLED_ADDR = 0x3C;
Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);

// ---- UART to FPGA ----
HardwareSerial FpgaSerial(2);  // UART2

// ---- Timing ----
const unsigned long SEND_INTERVAL_MS = 100;  // Send every 100ms
unsigned long lastSend = 0;

void setup() {
    // Debug serial (USB)
    Serial.begin(115200);
    Serial.println("\n--- Digital Volt-meter ESP32 ---");

    // Configure ADC
    analogSetAttenuation(ADC_11db);  // 0-3.3V range with 11dB attenuation
    pinMode(ANALOG_PIN, INPUT);

    // Initialize OLED
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
        Serial.println("SSD1306 allocation failed");
        while (1);
    }
    display.clearDisplay();
    display.setTextSize(2);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Volt-meter");
    display.setTextSize(1);
    display.println("Initializing...");
    display.display();
    delay(500);

    // Initialize UART2 to FPGA
    FpgaSerial.begin(UART_BAUD, SERIAL_8N1, UART_RX_PIN, UART_TX_PIN);
    Serial.println("UART2 initialized");
}

void loop() {
    unsigned long now = millis();
    if (now - lastSend < SEND_INTERVAL_MS) return;
    lastSend = now;

    // Read ADC (12-bit: 0-4095)
    int raw = analogRead(ANALOG_PIN);
    
    // Convert to voltage: (raw / 4095) * 3.3V
    float voltage = (raw / 4095.0) * 3.3;

    // Extract digits for display (X.XX format)
    int ones = (int)voltage;                     // 0-3
    int tenths = (int)((voltage - ones) * 10);   // 0-9
    int hundredths = (int)((voltage - ones) * 100) % 10;  // 0-9

    // Calculate LED bar: 0.3V per LED, 10 LEDs max
    // LED[i] lights up when voltage >= (i+1) * 0.3V
    // i.e., LED[0] @ 0.3V, LED[1] @ 0.6V, ..., LED[9] @ 3.0V
    uint16_t led_bar = 0;
    for (int i = 0; i < 10; i++) {
        if (voltage >= (i + 1) * 0.3) {
            led_bar |= (1 << i);
        }
    }

    // Build 5-byte binary frame
    uint8_t frame[5];
    frame[0] = ones;              // Byte 0: ones digit
    frame[1] = tenths;            // Byte 1: tenths digit
    frame[2] = hundredths;        // Byte 2: hundredths digit
    frame[3] = (uint8_t)(led_bar & 0xFF);   // Byte 3: LED[7:0]
    frame[4] = (uint8_t)((led_bar >> 8) & 0x03);  // Byte 4: LED[9:8]

    // Send to FPGA
    FpgaSerial.write(frame, 5);

    // Debug serial
    Serial.print("RAW: ");
    Serial.print(raw);
    Serial.print(" -> V: ");
    Serial.print(voltage, 2);
    Serial.print(" (");
    Serial.print(ones);
    Serial.print(".");
    Serial.print(tenths);
    Serial.print(hundredths);
    Serial.print(") LED_bar: 0x");
    Serial.println(led_bar, HEX);

    // Display on OLED (large voltage in center)
    display.clearDisplay();
    display.setTextSize(2);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(10, 20);
    display.print(voltage, 2);  // 2 decimal places
    display.print("V");

    // Show raw ADC below
    display.setTextSize(1);
    display.setCursor(0, 50);
    display.print("ADC: ");
    display.println(raw);

    display.display();
}
