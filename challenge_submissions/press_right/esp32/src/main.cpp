// Challenge 4: Press Right -- ESP32 OLED + Buzzer
//
// Receives "XXXX\n" ASCII lines from the FPGA (UART2 GPIO17 RX, 9600 8N1).
// XXXX = 4-digit decimal counter value (0000 – 9999).
// Goal: stop exactly at 1000 (= 10.00 s).  Win window: 990 – 1010.
//
// On WIN  (990–1010):  OLED shows count + "WIN!", plays victory tune.
// On MISS (<990/>1010): OLED shows count + "MISS" + delta.
//
// If no frame arrives for FRAME_TIMEOUT_MS, returns to "Waiting" screen
// and stops the buzzer.  This is triggered when KEY[0] restarts the FPGA.
//
// UART2 RX = GPIO17  ← FPGA ARDUINO_IO[1] (TX)
// UART2 TX = GPIO16  (unused)
// Buzzer   = PIN_BUZZER (GPIO19) via tone()/noTone()
// OLED     = SSD1306 128×64, I2C SDA=GPIO21 SCL=GPIO22

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

// ---- UART to FPGA ----
#define FPGA_RX_PIN  17
#define FPGA_TX_PIN  16
#define FPGA_BAUD    9600
HardwareSerial FpgaSerial(2);

// ---- OLED ----
#define OLED_WIDTH  128
#define OLED_HEIGHT  64
#define OLED_ADDR   0x3C
Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);

// ---- Buzzer ----
#define PIN_BUZZER  19

// ================================================================
//  Victory tune (non-blocking playback)
//  Replace the notes array with your actual melody before the contest.
//  freq = 0 → rest (silence).  dur_ms = note duration in milliseconds.
// ================================================================
struct Note {
    uint16_t freq;    // Hz  (0 = rest)
    uint16_t dur_ms;  // duration in ms
};

// ---- Victory fanfare, ~1.2s, three quick stabs then rising finish ----
// Short rests between notes give crisp articulation on a passive buzzer.
const Note VICTORY_MELODY[] = {
    {784,  80},  // G5 stab 1
    {  0,  30},
    {784,  80},  // G5 stab 2
    {  0,  30},
    {784,  80},  // G5 stab 3
    {  0,  50},
    {659, 100},  // E5 \ rising
    {784, 100},  // G5  |
    {880, 100},  // A5  |
    {988, 100},  // B5  |
    {1047,350},  // C6 hold
};
const int MELODY_LEN = (int)(sizeof(VICTORY_MELODY) / sizeof(VICTORY_MELODY[0]));

// Tune playback state
static bool     tuneActive    = false;
static bool     tunePlayed    = false;  // set once per result; cleared by drawWaiting()
static int      tuneNoteIdx   = 0;
static uint32_t tuneNoteStart = 0;

void startTune() {
    if (MELODY_LEN == 0) return;
    tuneActive    = true;
    tunePlayed    = true;
    tuneNoteIdx   = 0;
    tuneNoteStart = millis();
    if (VICTORY_MELODY[0].freq > 0)
        tone(PIN_BUZZER, VICTORY_MELODY[0].freq);
    else
        noTone(PIN_BUZZER);
}

void stopTune() {
    tuneActive = false;
    noTone(PIN_BUZZER);
}

// Call every loop() iteration — advances to the next note when due.
void updateTune() {
    if (!tuneActive || MELODY_LEN == 0) return;
    if ((millis() - tuneNoteStart) < VICTORY_MELODY[tuneNoteIdx].dur_ms)
        return;

    tuneNoteIdx++;
    if (tuneNoteIdx >= MELODY_LEN) {
        stopTune();
        return;
    }
    tuneNoteStart = millis();
    if (VICTORY_MELODY[tuneNoteIdx].freq > 0)
        tone(PIN_BUZZER, VICTORY_MELODY[tuneNoteIdx].freq);
    else
        noTone(PIN_BUZZER);
}

// ================================================================
//  OLED helpers
// ================================================================
void drawWaiting() {
    stopTune();
    tunePlayed = false;   // allow tune to play again next result
    display.clearDisplay();
    display.setTextColor(SSD1306_WHITE);

    display.setTextSize(1);
    display.setCursor(0, 0);
    display.println("  === PRESS RIGHT ===");

    display.setTextSize(1);
    display.setCursor(0, 20);
    display.println("Press KEY[0] on FPGA");
    display.setCursor(0, 32);
    display.println("to start the counter.");
    display.setCursor(0, 44);
    display.println("Stop it at 1000!");

    display.display();
}

void drawResult(uint16_t count, bool win, int16_t delta) {
    display.clearDisplay();
    display.setTextColor(SSD1306_WHITE);
    char buf[20];  // large enough for "Off by +9000" + null

    // Title (size 1, centered): "= PRESS RIGHT =" = 15 chars * 6 = 90px -> x=19
    display.setTextSize(1);
    display.setCursor(19, 0);
    display.print("= PRESS RIGHT =");

    // Count (size 2, centered based on actual digit count)
    display.setTextSize(2);
    snprintf(buf, sizeof(buf), "%u", count);
    int clen = (int)strlen(buf);
    display.setCursor((128 - clen * 12) / 2, 12);
    display.print(buf);

    // Result label (size 2, centered)
    display.setTextSize(2);
    if (win) {
        // "WIN!" = 4 chars * 12 = 48px -> x=40
        display.setCursor(40, 32);
        display.print("WIN!");
        // Sub-text (size 1, centered): "** You win! **" = 14 chars * 6 = 84px -> x=22
        display.setTextSize(1);
        display.setCursor(22, 52);
        display.print("** You win! **");
    } else {
        // "MISS" = 4 chars * 12 = 48px -> x=40
        display.setCursor(40, 32);
        display.print("MISS");
        // "Off by +/-XXXX" centered (size 1)
        display.setTextSize(1);
        if (delta > 0)
            snprintf(buf, sizeof(buf), "Off by +%d", (int)delta);
        else
            snprintf(buf, sizeof(buf), "Off by %d",  (int)delta);
        int bw = (int)strlen(buf) * 6;
        display.setCursor((128 - bw) / 2, 52);
        display.print(buf);
    }

    display.display();
}

// ================================================================
//  Line receive state (alive_test pattern)
// ================================================================
String fpgaLine = "";

// Timeout: if no frame received for this long, return to waiting screen.
// This fires when the FPGA game is reset (KEY[0] in STOPPED state).
const unsigned long FRAME_TIMEOUT_MS = 2000;
unsigned long lastFrameMs = 0;
bool haveResult = false;

// ================================================================
//  setup / loop
// ================================================================
void setup() {
    Serial.begin(115200);
    Serial.println("\n--- Press Right ESP32 ---");

    pinMode(PIN_BUZZER, OUTPUT);
    noTone(PIN_BUZZER);

    // OLED
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
        Serial.println("SSD1306 init failed");
        while (1);
    }
    display.clearDisplay();
    display.setTextSize(2);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("PRESS");
    display.println("RIGHT!");
    display.display();
    delay(800);

    // UART2 from FPGA
    FpgaSerial.begin(FPGA_BAUD, SERIAL_8N1, FPGA_RX_PIN, FPGA_TX_PIN);
    Serial.println("UART2 ready (GPIO17 RX)");

    drawWaiting();
}

void loop() {
    // ---- Non-blocking tune playback ----
    updateTune();

    // ---- Receive ASCII lines from FPGA (alive_test pattern) ----
    while (FpgaSerial.available()) {
        char c = (char)FpgaSerial.read();
        Serial.printf("[FPGA] 0x%02X '%c'\n", (uint8_t)c,
                      (c >= 32 && c < 127) ? c : '.');

        if (c == '\n' || c == '\r') {
            // Line complete: expect exactly 4 ASCII digits e.g. "1023"
            if (fpgaLine.length() == 4) {
                bool allDigits = true;
                for (int i = 0; i < 4; i++) {
                    if (fpgaLine[i] < '0' || fpgaLine[i] > '9') {
                        allDigits = false;
                        break;
                    }
                }
                if (allDigits) {
                    uint16_t count = (uint16_t)fpgaLine.toInt();
                    int16_t  delta = (int16_t)count - 1000;
                    bool     win   = (count >= 990 && count <= 1010);

                    lastFrameMs = millis();
                    haveResult  = true;

                    drawResult(count, win, delta);
                    Serial.printf("Count: %u  Delta: %d  %s\n",
                                  count, delta, win ? "WIN" : "MISS");

                    if (win && !tuneActive && !tunePlayed)
                        startTune();
                    else if (!win)
                        stopTune();
                }
            } else if (fpgaLine.length() > 0) {
                Serial.printf("Bad line: \"%s\"\n", fpgaLine.c_str());
            }

            fpgaLine = "";

        } else if (fpgaLine.length() < 8) {
            fpgaLine += c;
        }
    }

    // ---- Timeout: FPGA stopped sending → game was reset ----
    if (haveResult && (millis() - lastFrameMs > FRAME_TIMEOUT_MS)) {
        haveResult = false;
        drawWaiting();
    }
}
