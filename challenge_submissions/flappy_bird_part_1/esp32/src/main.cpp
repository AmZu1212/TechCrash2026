// Challenge 9 Milestone 1: Manual FPGA-controlled Flappy Bird.
//
// FPGA sends 4-byte UART packets:
//   0xA5, TYPE, VALUE, CHECKSUM
//   TYPE 0x01 = flap/restart
//   TYPE 0x02 = difficulty update, VALUE = 0..15
//   CHECKSUM = 0xA5 ^ TYPE ^ VALUE

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "../../../../projects/common/esp32/pin_config.h"

static const uint8_t PKT_SYNC = 0xA5;
static const uint8_t PKT_FLAP = 0x01;
static const uint8_t PKT_DIFF = 0x02;

static const uint32_t GAME_FRAME_MS = 33;
static const int16_t SCREEN_W = OLED_WIDTH;
static const int16_t SCREEN_H = OLED_HEIGHT;
static const int16_t HUD_H = 9;
static const int16_t BIRD_X = 22;
static const int16_t BIRD_W = 5;
static const int16_t BIRD_H = 4;
static const int16_t PIPE_W = 8;

HardwareSerial FpgaSerial(2);
Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);
bool oledOk = false;

enum ParseState {
    WAIT_SYNC,
    READ_TYPE,
    READ_VALUE,
    READ_CHECKSUM
};

ParseState parseState = WAIT_SYNC;
uint8_t pktType = 0;
uint8_t pktValue = 0;
uint8_t difficulty = 0;
uint32_t packetCount = 0;
uint32_t badPacketCount = 0;

bool flapEvent = false;
bool gameOver = true;
float birdY = 30.0f;
float birdVel = 0.0f;
float pipeX = SCREEN_W;
int16_t gapY = 28;
uint16_t score = 0;
uint32_t lastFrameMs = 0;
uint32_t rngState = 0x12345678;

uint32_t nextRandom() {
    rngState = rngState * 1664525UL + 1013904223UL;
    return rngState;
}

int16_t gapSizeForDifficulty() {
    int16_t gap = 28 - (int16_t)difficulty;
    if (gap < 13) gap = 13;
    return gap;
}

float pipeSpeedForDifficulty() {
    return 1.0f + (float)difficulty * 0.16f;
}

void resetPipe() {
    int16_t gap = gapSizeForDifficulty();
    int16_t minY = HUD_H + 4 + gap / 2;
    int16_t maxY = SCREEN_H - 4 - gap / 2;
    if (maxY < minY) maxY = minY;
    gapY = minY + (int16_t)(nextRandom() % (uint32_t)(maxY - minY + 1));
    pipeX = SCREEN_W + 4;
}

void resetGame() {
    gameOver = false;
    birdY = 30.0f;
    birdVel = -2.2f;
    score = 0;
    rngState = 0x12345678 ^ ((uint32_t)difficulty << 8);
    resetPipe();
}

void handlePacket(uint8_t type, uint8_t value) {
    value &= 0x0F;
    packetCount++;

    if (type == PKT_FLAP) {
        difficulty = value;
        flapEvent = true;
    } else if (type == PKT_DIFF) {
        difficulty = value;
    }
}

void parseByte(uint8_t b) {
    switch (parseState) {
        case WAIT_SYNC:
            if (b == PKT_SYNC) parseState = READ_TYPE;
            break;

        case READ_TYPE:
            pktType = b;
            parseState = READ_VALUE;
            break;

        case READ_VALUE:
            pktValue = b;
            parseState = READ_CHECKSUM;
            break;

        case READ_CHECKSUM: {
            uint8_t expected = PKT_SYNC ^ pktType ^ pktValue;
            if (b == expected) {
                handlePacket(pktType, pktValue);
            } else {
                badPacketCount++;
            }
            parseState = WAIT_SYNC;
            break;
        }
    }
}

void readFpgaPackets() {
    while (FpgaSerial.available()) {
        parseByte((uint8_t)FpgaSerial.read());
    }
}

bool collision() {
    int16_t birdTop = (int16_t)birdY;
    int16_t birdBottom = birdTop + BIRD_H;

    if (birdTop < HUD_H || birdBottom >= SCREEN_H) {
        return true;
    }

    int16_t birdRight = BIRD_X + BIRD_W;
    bool xOverlap = (birdRight >= (int16_t)pipeX) &&
                    (BIRD_X <= (int16_t)pipeX + PIPE_W);
    if (!xOverlap) {
        return false;
    }

    int16_t gap = gapSizeForDifficulty();
    int16_t gapTop = gapY - gap / 2;
    int16_t gapBottom = gapY + gap / 2;
    return (birdTop < gapTop) || (birdBottom > gapBottom);
}

void updateGame() {
    if (flapEvent) {
        flapEvent = false;
        if (gameOver) {
            resetGame();
        } else {
            birdVel = -2.45f;
        }
    }

    if (gameOver) {
        return;
    }

    birdVel += 0.22f;
    if (birdVel > 2.8f) birdVel = 2.8f;
    birdY += birdVel;

    float oldPipeX = pipeX;
    pipeX -= pipeSpeedForDifficulty();

    if (oldPipeX + PIPE_W >= BIRD_X && pipeX + PIPE_W < BIRD_X) {
        score++;
    }

    if (pipeX < -PIPE_W) {
        resetPipe();
    }

    if (collision()) {
        gameOver = true;
    }
}

void drawGame() {
    if (!oledOk) return;

    display.clearDisplay();
    display.setTextColor(SSD1306_WHITE);
    display.setTextSize(1);

    display.setCursor(1, 0);
    display.printf("SCORE:%03u  Diff: %02u", score > 999 ? 999 : score, difficulty);
    display.drawFastHLine(0, HUD_H - 1, SCREEN_W, SSD1306_WHITE);

    int16_t gap = gapSizeForDifficulty();
    int16_t gapTop = gapY - gap / 2;
    int16_t gapBottom = gapY + gap / 2;
    int16_t px = (int16_t)pipeX;

    if (px < SCREEN_W && px + PIPE_W >= 0) {
        if (gapTop > HUD_H) {
            display.fillRect(px, HUD_H, PIPE_W, gapTop - HUD_H, SSD1306_WHITE);
        }
        if (gapBottom < SCREEN_H) {
            display.fillRect(px, gapBottom, PIPE_W, SCREEN_H - gapBottom, SSD1306_WHITE);
        }
    }

    display.fillRect(BIRD_X, (int16_t)birdY, BIRD_W, BIRD_H, SSD1306_WHITE);
    display.drawPixel(BIRD_X + BIRD_W, (int16_t)birdY + 1, SSD1306_WHITE);

    if (gameOver) {
        display.fillRect(17, 22, 94, 24, SSD1306_BLACK);
        display.drawRect(17, 22, 94, 24, SSD1306_WHITE);
        display.setCursor(28, 28);
        display.print("GAME OVER");
        display.setCursor(24, 38);
        display.print("KEY0 restarts");
    }

    display.display();
}

void setup() {
    Serial.begin(115200);
    delay(250);
    Serial.println();
    Serial.println("--- Flappy Bird Part 1 ---");

    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    oledOk = display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR);
    if (!oledOk) {
        Serial.println("OLED init failed");
    }

    FpgaSerial.begin(FPGA_BAUD, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);
    Serial.println("UART2 ready: FPGA TX ARDUINO_IO[1] -> ESP32 GPIO17");

    drawGame();
}

void loop() {
    readFpgaPackets();

    uint32_t now = millis();
    if (now - lastFrameMs >= GAME_FRAME_MS) {
        lastFrameMs = now;
        updateGame();
        drawGame();
    }

    static uint32_t lastSerialMs = 0;
    if (now - lastSerialMs >= 1000) {
        lastSerialMs = now;
        Serial.printf("diff=%u score=%u packets=%lu bad=%lu gameOver=%d\n",
                      difficulty,
                      score,
                      (unsigned long)packetCount,
                      (unsigned long)badPacketCount,
                      gameOver ? 1 : 0);
    }
}
