// Challenge 2: Accelerometer 3D Cube -- ESP32 side
//
// Receives raw ADXL345 samples from the FPGA over UART2 and renders
// a wireframe cube on the SSD1306 OLED.
//
// UART frame from FPGA:
//   A5 5A SEQ X0 X1 Y0 Y1 Z0 Z1 SUM
// SUM is the low 8 bits of SEQ + X0 + X1 + Y0 + Y1 + Z0 + Z1.

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <math.h>
#include "../../../../projects/common/esp32/pin_config.h"

HardwareSerial FpgaSerial(2);
Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);

enum ParseState {
    WAIT_A5,
    WAIT_5A,
    READ_BODY
};

ParseState parseState = WAIT_A5;
uint8_t body[8];
uint8_t bodyIndex = 0;

int16_t rawX = 0;
int16_t rawY = 0;
int16_t rawZ = 0;
uint8_t lastSeq = 0;
bool haveFrame = false;
uint32_t frameCount = 0;
uint32_t badChecksumCount = 0;
uint32_t lastFrameMs = 0;

float pitchDeg = 0.0f;
float rollDeg = 0.0f;
float smoothPitchDeg = 0.0f;
float smoothRollDeg = 0.0f;

const uint32_t DISPLAY_INTERVAL_MS = 33;
const uint32_t FRAME_TIMEOUT_MS = 700;
uint32_t lastDisplayMs = 0;

struct Vec3 {
    float x;
    float y;
    float z;
};

struct Point2 {
    int16_t x;
    int16_t y;
};

const Vec3 cubeVerts[8] = {
    {-1, -1, -1}, { 1, -1, -1}, { 1,  1, -1}, {-1,  1, -1},
    {-1, -1,  1}, { 1, -1,  1}, { 1,  1,  1}, {-1,  1,  1}
};

const uint8_t cubeEdges[12][2] = {
    {0, 1}, {1, 2}, {2, 3}, {3, 0},
    {4, 5}, {5, 6}, {6, 7}, {7, 4},
    {0, 4}, {1, 5}, {2, 6}, {3, 7}
};

uint8_t checksumBody() {
    uint16_t sum = 0;
    for (uint8_t i = 0; i < 7; i++) {
        sum += body[i];
    }
    return (uint8_t)sum;
}

void acceptFrame() {
    uint8_t expected = checksumBody();
    if (expected != body[7]) {
        badChecksumCount++;
        return;
    }

    lastSeq = body[0];
    rawX = (int16_t)((uint16_t)body[1] | ((uint16_t)body[2] << 8));
    rawY = (int16_t)((uint16_t)body[3] | ((uint16_t)body[4] << 8));
    rawZ = (int16_t)((uint16_t)body[5] | ((uint16_t)body[6] << 8));

    float x = (float)rawX;
    float y = (float)rawY;
    float z = (float)rawZ;

    rollDeg = atan2f(y, z) * 180.0f / PI;
    pitchDeg = atan2f(-x, sqrtf(y * y + z * z)) * 180.0f / PI;

    if (!haveFrame) {
        smoothPitchDeg = pitchDeg;
        smoothRollDeg = rollDeg;
    } else {
        const float alpha = 0.18f;
        smoothPitchDeg += alpha * (pitchDeg - smoothPitchDeg);
        smoothRollDeg += alpha * (rollDeg - smoothRollDeg);
    }

    haveFrame = true;
    frameCount++;
    lastFrameMs = millis();
}

void parseByte(uint8_t b) {
    switch (parseState) {
        case WAIT_A5:
            if (b == 0xA5) {
                parseState = WAIT_5A;
            }
            break;

        case WAIT_5A:
            if (b == 0x5A) {
                bodyIndex = 0;
                parseState = READ_BODY;
            } else if (b != 0xA5) {
                parseState = WAIT_A5;
            }
            break;

        case READ_BODY:
            body[bodyIndex++] = b;
            if (bodyIndex == sizeof(body)) {
                acceptFrame();
                parseState = WAIT_A5;
            }
            break;
    }
}

Point2 projectVertex(Vec3 v, float pitchRad, float rollRad) {
    // Constant 90° yaw offset: pre-rotate around Y axis so the cube faces
    // a different direction. Y-rot 90°: x'=z, y'=y, z'=-x
    float vx = v.z;
    float vy = v.y;
    float vz = -v.x;

    float cp = cosf(pitchRad);
    float sp = sinf(pitchRad);
    float cr = cosf(rollRad);
    float sr = -sinf(rollRad);  // negated to flip roll direction

    // Rotate around X by pitch.
    float y1 = vy * cp - vz * sp;
    float z1 = vy * sp + vz * cp;
    float x1 = vx;

    // Rotate around Z by roll.
    float x2 = x1 * cr - y1 * sr;
    float y2 = x1 * sr + y1 * cr;
    float z2 = z1;

    // Top-down view: camera above on +Y axis looking down.
    // Depth axis = -y2, screen axes = x2 (horizontal) and z2 (vertical).
    const float cameraDistance = 4.0f;
    const float scale = 48.0f;
    float perspective = scale / (cameraDistance - y2);

    Point2 p;
    p.x = (int16_t)(64.0f + x2 * perspective);
    p.y = (int16_t)(36.0f + z2 * perspective);
    return p;
}

void drawWaiting() {
    display.clearDisplay();
    display.setTextColor(SSD1306_WHITE);
    display.setTextSize(1);
    display.setCursor(0, 0);
    display.println("Accel Cube");
    display.drawFastHLine(0, 10, 128, SSD1306_WHITE);
    display.setCursor(0, 25);
    display.println("Waiting for FPGA...");
    display.setCursor(0, 45);
    display.println("UART RX GPIO17");
    display.display();
}

void drawCube() {
    display.clearDisplay();
    display.setTextColor(SSD1306_WHITE);
    display.setTextSize(1);

    display.setCursor(0, 0);
    display.printf("P:%4.0f R:%4.0f", smoothPitchDeg, smoothRollDeg);

    // View from 90° left of FPGA: physical roll drives cube pitch,
    // physical pitch drives cube roll (negated so high pitch = roll low).
    float pitchRad =  smoothRollDeg  * PI / 180.0f;
    float rollRad  =  smoothPitchDeg * PI / 180.0f;
    Point2 projected[8];

    for (uint8_t i = 0; i < 8; i++) {
        projected[i] = projectVertex(cubeVerts[i], pitchRad, rollRad);
    }

    for (uint8_t i = 0; i < 12; i++) {
        Point2 a = projected[cubeEdges[i][0]];
        Point2 b = projected[cubeEdges[i][1]];
        display.drawLine(a.x, a.y, b.x, b.y, SSD1306_WHITE);
    }

    display.drawPixel(64, 36, SSD1306_WHITE);
    display.display();
}

void setup() {
    Serial.begin(115200);
    delay(300);
    Serial.println();
    Serial.println("--- Challenge 2: Accelerometer Cube ---");

    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        Serial.println("SSD1306 init failed");
        while (true) {
            delay(1000);
        }
    }

    FpgaSerial.begin(FPGA_BAUD, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);
    Serial.println("UART2 ready: RX GPIO17 <- FPGA ARDUINO_IO[1]");
    drawWaiting();
}

void loop() {
    while (FpgaSerial.available()) {
        parseByte((uint8_t)FpgaSerial.read());
    }

    uint32_t now = millis();
    if (now - lastDisplayMs >= DISPLAY_INTERVAL_MS) {
        lastDisplayMs = now;

        if (!haveFrame || (now - lastFrameMs > FRAME_TIMEOUT_MS)) {
            drawWaiting();
        } else {
            drawCube();
        }
    }

    static uint32_t lastSerialMs = 0;
    if (now - lastSerialMs >= 500) {
        lastSerialMs = now;
        Serial.printf("seq=%u frames=%lu bad=%lu x=%d y=%d z=%d pitch=%.1f roll=%.1f\n",
                      lastSeq,
                      (unsigned long)frameCount,
                      (unsigned long)badChecksumCount,
                      rawX, rawY, rawZ,
                      smoothPitchDeg, smoothRollDeg);
    }
}
