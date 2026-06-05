// Challenge 9 Milestone 3: ESP32 training plus FPGA inference mode.
//
// The ESP32 trains a population using the same game physics as Part 1. When
// FPGA mode is selected, it evaluates the archived top generation champions on
// a held-out course, uploads the winner as fixed-point weights, then lets the
// FPGA drive one bird through UART inference responses.

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <math.h>
#include "../../../../projects/common/esp32/pin_config.h"

static const uint8_t FPGA_SYNC = 0xA5;
static const uint8_t FP_RESET = 0x01;
static const uint8_t FP_DIFF = 0x02;
static const uint8_t FP_MODE = 0x03;
static const uint8_t FP_INFER = 0x04;

static const uint8_t ESP_SYNC = 0x5A;
static const uint8_t ESP_WEIGHT = 0x10;
static const uint8_t ESP_LOAD_BEGIN = 0x11;
static const uint8_t ESP_STATE = 0x20;

static const uint8_t POP_SIZE = 64;
static const uint8_t INPUTS = 4;
static const uint8_t HIDDEN = 4;
static const uint8_t ELITES = 6;
static const uint8_t ARCHIVE_SIZE = 10;
static const uint8_t WEIGHT_COUNT = 25;

static const uint32_t FRAME_MS = 33;
static const uint32_t TRAIN_DRAW_MS = 250;
static const uint8_t TRAIN_STEPS_PER_TICK = 10;
static const uint16_t EVAL_MAX_FRAMES = 1800;
static const int16_t SCREEN_W = OLED_WIDTH;
static const int16_t SCREEN_H = OLED_HEIGHT;
static const int16_t HUD_H = 9;
static const int16_t BIRD_X = 22;
static const int16_t BIRD_W = 5;
static const int16_t BIRD_H = 4;
static const int16_t PIPE_W = 8;

struct Brain {
    float w1[HIDDEN][INPUTS];
    float b1[HIDDEN];
    float w2[HIDDEN];
    float b2;
};

struct Bird {
    float y;
    float vel;
    bool alive;
    uint16_t pipes;
    uint32_t frames;
    float fitness;
};

struct ChampionSnapshot {
    Brain brain;
    uint32_t generation;
    float progress;
    uint16_t pipes;
    float fitness;
};

enum FpgaParseState {
    WAIT_SYNC,
    READ_TYPE,
    READ_VALUE,
    READ_CHECKSUM
};

HardwareSerial FpgaSerial(2);
Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);
bool oledOk = false;

Brain brains[POP_SIZE];
Brain nextBrains[POP_SIZE];
Brain bestBrain;
bool bestBrainValid = false;
Bird birds[POP_SIZE];
Bird fpgaBird;
ChampionSnapshot archive[ARCHIVE_SIZE];

uint8_t archiveCount = 0;
uint8_t difficulty = 0;
bool fpgaInferenceMode = false;
bool weightsUploaded = false;
bool resetRequested = false;
bool finishGenerationRequested = false;

uint32_t generation = 1;
uint16_t bestPipesEver = 0;
float bestFitnessEver = -1000000.0f;
float previousChampionProgress = 0.0f;
float lastChampionProgress = 0.0f;
float championDelta = 0.0f;
uint16_t lastChampionPipes = 0;
uint32_t lastChampionGeneration = 0;
float lastEvalProgress = 0.0f;
uint16_t lastEvalPipes = 0;
uint32_t lastEvalGeneration = 0;
uint8_t lastEvalSlot = 0;
uint16_t fpgaScore = 0;
uint32_t fpgaFrames = 0;

uint32_t packetCount = 0;
uint32_t badPackets = 0;
uint32_t inferRequests = 0;
uint32_t inferResponses = 0;
uint8_t stateSeq = 0;
uint8_t lastResponseSeq = 0;
bool lastFpgaFlap = false;

float pipeX = SCREEN_W + 8;
int16_t gapY = 32;
uint32_t lastFrameMs = 0;
uint32_t lastDrawMs = 0;
uint32_t obstacleRng = 0x00C0FFEE;
uint32_t trainRng = 0x12345678;

FpgaParseState parseState = WAIT_SYNC;
uint8_t pktType = 0;
uint8_t pktValue = 0;

uint32_t nextTrainRand() {
    trainRng = trainRng * 1664525UL + 1013904223UL;
    return trainRng;
}

uint32_t nextObstacleRand() {
    obstacleRng = obstacleRng * 1103515245UL + 12345UL;
    return obstacleRng;
}

float randFloat(float lo, float hi) {
    uint32_t r = nextTrainRand() & 0x00FFFFFFUL;
    float t = (float)r / 16777215.0f;
    return lo + (hi - lo) * t;
}

float activation(float x) {
    return tanhf(x);
}

float sigmoid(float x) {
    if (x > 8.0f) return 0.9997f;
    if (x < -8.0f) return 0.0003f;
    return 1.0f / (1.0f + expf(-x));
}

int16_t gapSizeForDifficulty() {
    int16_t gap = 28 - (int16_t)difficulty;
    if (gap < 13) gap = 13;
    return gap;
}

float pipeSpeedForDifficulty() {
    return 1.0f + (float)difficulty * 0.16f;
}

float progressForBird(const Bird& bird) {
    return (float)bird.frames * pipeSpeedForDifficulty();
}

int8_t clampInt8(int value) {
    if (value > 127) return 127;
    if (value < -128) return -128;
    return (int8_t)value;
}

int8_t quantizeWeight(float value) {
    return clampInt8((int)lrintf(value * 16.0f));
}

int8_t quantizeInput(float value) {
    return clampInt8((int)lrintf(value * 32.0f));
}

void randomizeBrain(Brain& brain) {
    for (uint8_t h = 0; h < HIDDEN; h++) {
        for (uint8_t i = 0; i < INPUTS; i++) {
            brain.w1[h][i] = randFloat(-1.0f, 1.0f);
        }
        brain.b1[h] = randFloat(-0.5f, 0.5f);
        brain.w2[h] = randFloat(-1.0f, 1.0f);
    }
    brain.b2 = randFloat(-0.5f, 0.5f);
}

float mutateWeight(float w) {
    uint32_t r = nextTrainRand() % 1000;
    if (r < 80) {
        w += randFloat(-0.18f, 0.18f);
    } else if (r < 92) {
        w += randFloat(-0.85f, 0.85f);
    }
    if (w > 4.0f) w = 4.0f;
    if (w < -4.0f) w = -4.0f;
    return w;
}

void copyMutatedBrain(const Brain& parent, Brain& child, bool preserve) {
    for (uint8_t h = 0; h < HIDDEN; h++) {
        for (uint8_t i = 0; i < INPUTS; i++) {
            child.w1[h][i] = preserve ? parent.w1[h][i] : mutateWeight(parent.w1[h][i]);
        }
        child.b1[h] = preserve ? parent.b1[h] : mutateWeight(parent.b1[h]);
        child.w2[h] = preserve ? parent.w2[h] : mutateWeight(parent.w2[h]);
    }
    child.b2 = preserve ? parent.b2 : mutateWeight(parent.b2);
}

void makeInputs(const Bird& bird, float inputs[INPUTS]) {
    float nextPipeDist = (pipeX + PIPE_W - BIRD_X) / (float)SCREEN_W;
    if (nextPipeDist < 0.0f) nextPipeDist = 0.0f;

    inputs[0] = (bird.y - HUD_H) / (float)(SCREEN_H - HUD_H);
    inputs[1] = bird.vel / 4.0f;
    inputs[2] = nextPipeDist;
    inputs[3] = (bird.y + BIRD_H * 0.5f - (float)gapY) / (float)SCREEN_H;
}

float runNetwork(const Brain& brain, const Bird& bird) {
    float inputs[INPUTS];
    makeInputs(bird, inputs);

    float hidden[HIDDEN];
    for (uint8_t h = 0; h < HIDDEN; h++) {
        float sum = brain.b1[h];
        for (uint8_t i = 0; i < INPUTS; i++) {
            sum += brain.w1[h][i] * inputs[i];
        }
        hidden[h] = activation(sum);
    }

    float out = brain.b2;
    for (uint8_t h = 0; h < HIDDEN; h++) {
        out += brain.w2[h] * hidden[h];
    }
    return sigmoid(out);
}

void resetPipe() {
    int16_t gap = gapSizeForDifficulty();
    int16_t minY = HUD_H + 4 + gap / 2;
    int16_t maxY = SCREEN_H - 4 - gap / 2;
    if (maxY < minY) maxY = minY;
    gapY = minY + (int16_t)(nextObstacleRand() % (uint32_t)(maxY - minY + 1));
    pipeX = SCREEN_W + 4;
}

void resetCourse() {
    obstacleRng = 0x00C0FFEE ^ ((uint32_t)difficulty << 12);
    resetPipe();
}

void resetEvaluationCourse() {
    obstacleRng = 0x0BADBEEF ^ ((uint32_t)difficulty << 12);
    resetPipe();
}

void resetBirds() {
    for (uint8_t i = 0; i < POP_SIZE; i++) {
        birds[i].y = 30.0f;
        birds[i].vel = 0.0f;
        birds[i].alive = true;
        birds[i].pipes = 0;
        birds[i].frames = 0;
        birds[i].fitness = 0.0f;
    }
}

void startGeneration() {
    resetCourse();
    resetBirds();
}

void resetFpgaGame() {
    resetCourse();
    fpgaBird.y = 30.0f;
    fpgaBird.vel = 0.0f;
    fpgaBird.alive = true;
    fpgaBird.pipes = 0;
    fpgaBird.frames = 0;
    fpgaBird.fitness = 0.0f;
    fpgaScore = 0;
    fpgaFrames = 0;
    lastFpgaFlap = false;
    stateSeq = 0;
}

void clearArchive() {
    archiveCount = 0;
    previousChampionProgress = 0.0f;
    lastChampionProgress = 0.0f;
    championDelta = 0.0f;
    lastChampionPipes = 0;
    lastChampionGeneration = 0;
    lastEvalProgress = 0.0f;
    lastEvalPipes = 0;
    lastEvalGeneration = 0;
    lastEvalSlot = 0;
}

void initializeTraining() {
    trainRng = 0x12345678;
    for (uint8_t i = 0; i < POP_SIZE; i++) {
        randomizeBrain(brains[i]);
    }
    bestBrain = brains[0];
    bestBrainValid = true;
    generation = 1;
    bestPipesEver = 0;
    bestFitnessEver = -1000000.0f;
    weightsUploaded = false;
    clearArchive();
    startGeneration();
}

bool birdCollides(const Bird& bird) {
    int16_t birdTop = (int16_t)bird.y;
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

uint8_t aliveCount() {
    uint8_t count = 0;
    for (uint8_t i = 0; i < POP_SIZE; i++) {
        if (birds[i].alive) count++;
    }
    return count;
}

void rankBirds(uint8_t top[ELITES]) {
    bool used[POP_SIZE] = {false};
    for (uint8_t e = 0; e < ELITES; e++) {
        float best = -1000000.0f;
        uint8_t bestIdx = 0;
        for (uint8_t i = 0; i < POP_SIZE; i++) {
            if (!used[i] && birds[i].fitness > best) {
                best = birds[i].fitness;
                bestIdx = i;
            }
        }
        top[e] = bestIdx;
        used[bestIdx] = true;
    }
}

void archiveChampion(const Brain& brain, const Bird& bird, uint32_t sourceGeneration) {
    float progress = progressForBird(bird);

    previousChampionProgress = lastChampionProgress;
    lastChampionProgress = progress;
    championDelta = (sourceGeneration <= 1) ? 0.0f : (lastChampionProgress - previousChampionProgress);
    lastChampionPipes = bird.pipes;
    lastChampionGeneration = sourceGeneration;

    if (bird.fitness > bestFitnessEver) {
        bestFitnessEver = bird.fitness;
        bestBrain = brain;
        bestBrainValid = true;
        weightsUploaded = false;
    }

    uint8_t slot = archiveCount;
    if (archiveCount < ARCHIVE_SIZE) {
        archiveCount++;
    } else {
        float weakest = archive[0].progress;
        slot = 0;
        for (uint8_t i = 1; i < ARCHIVE_SIZE; i++) {
            if (archive[i].progress < weakest) {
                weakest = archive[i].progress;
                slot = i;
            }
        }
        if (progress <= weakest) {
            return;
        }
    }

    archive[slot].brain = brain;
    archive[slot].generation = sourceGeneration;
    archive[slot].progress = progress;
    archive[slot].pipes = bird.pipes;
    archive[slot].fitness = bird.fitness;
}

void evolve() {
    uint8_t top[ELITES];
    rankBirds(top);
    archiveChampion(brains[top[0]], birds[top[0]], generation);

    for (uint8_t e = 0; e < ELITES; e++) {
        copyMutatedBrain(brains[top[e]], nextBrains[e], true);
    }

    for (uint8_t i = ELITES; i < POP_SIZE; i++) {
        uint8_t parent = top[i % ELITES];
        copyMutatedBrain(brains[parent], nextBrains[i], false);
    }

    for (uint8_t i = 0; i < POP_SIZE; i++) {
        brains[i] = nextBrains[i];
    }

    generation++;
    startGeneration();
}

void updateTrainingSimulation() {
    if (finishGenerationRequested) {
        finishGenerationRequested = false;
        evolve();
        return;
    }

    if (aliveCount() == 0) {
        evolve();
        return;
    }

    float oldPipeX = pipeX;
    pipeX -= pipeSpeedForDifficulty();
    bool pipePassed = (oldPipeX + PIPE_W >= BIRD_X) && (pipeX + PIPE_W < BIRD_X);

    if (pipeX < -PIPE_W) {
        resetPipe();
    }

    for (uint8_t i = 0; i < POP_SIZE; i++) {
        Bird& bird = birds[i];
        if (!bird.alive) continue;

        float output = runNetwork(brains[i], bird);
        if (output > 0.55f) {
            bird.vel = -2.45f;
        }

        bird.vel += 0.22f;
        if (bird.vel > 2.8f) bird.vel = 2.8f;
        bird.y += bird.vel;
        bird.frames++;

        if (pipePassed) {
            bird.pipes++;
        }

        float gapError = fabsf((bird.y + BIRD_H * 0.5f) - (float)gapY);
        float progress = progressForBird(bird);
        bird.fitness = progress + (float)bird.pipes * 1000.0f - gapError * 0.25f;

        if (bird.pipes > bestPipesEver) {
            bestPipesEver = bird.pipes;
        }
        if (bird.fitness > bestFitnessEver) {
            bestFitnessEver = bird.fitness;
            bestBrain = brains[i];
            bestBrainValid = true;
            weightsUploaded = false;
        }

        if (birdCollides(bird)) {
            bird.alive = false;
        }
    }
}

void drawLoading(const char* title, const char* detail, uint8_t done, uint8_t total) {
    if (!oledOk) return;

    display.clearDisplay();
    display.setTextColor(SSD1306_WHITE);
    display.setTextSize(1);
    display.setCursor(0, 6);
    display.print(title);
    display.setCursor(0, 20);
    display.print(detail);
    display.setCursor(0, 34);
    display.printf("%u/%u", done, total);
    if (total > 0) {
        int16_t w = (int16_t)((uint32_t)done * 120UL / total);
        display.drawRect(0, 48, 122, 8, SSD1306_WHITE);
        display.fillRect(1, 49, w, 6, SSD1306_WHITE);
    }
    display.display();
}

void sendEspPacket5(uint8_t type, uint8_t a, uint8_t b) {
    uint8_t chk = ESP_SYNC ^ type ^ a ^ b;
    FpgaSerial.write(ESP_SYNC);
    FpgaSerial.write(type);
    FpgaSerial.write(a);
    FpgaSerial.write(b);
    FpgaSerial.write(chk);
}

void sendLoadBegin() {
    sendEspPacket5(ESP_LOAD_BEGIN, 0, WEIGHT_COUNT);
}

void sendWeight(uint8_t index, int8_t value) {
    sendEspPacket5(ESP_WEIGHT, index, (uint8_t)value);
}

void uploadBrainToFpga(const Brain& brain) {
    drawLoading("Uploading to FPGA", "fixed-point weights", 0, WEIGHT_COUNT);
    sendLoadBegin();

    uint8_t idx = 0;
    for (uint8_t h = 0; h < HIDDEN; h++) {
        for (uint8_t i = 0; i < INPUTS; i++) {
            sendWeight(idx++, quantizeWeight(brain.w1[h][i]));
            if ((idx % 5) == 0) drawLoading("Uploading to FPGA", "input weights", idx, WEIGHT_COUNT);
        }
    }
    for (uint8_t h = 0; h < HIDDEN; h++) {
        sendWeight(idx++, quantizeWeight(brain.b1[h]));
    }
    drawLoading("Uploading to FPGA", "hidden/output", idx, WEIGHT_COUNT);
    for (uint8_t h = 0; h < HIDDEN; h++) {
        sendWeight(idx++, quantizeWeight(brain.w2[h]));
    }
    sendWeight(idx++, quantizeWeight(brain.b2));
    FpgaSerial.flush();
    drawLoading("Uploading to FPGA", "complete", WEIGHT_COUNT, WEIGHT_COUNT);
    weightsUploaded = true;
}

uint8_t runArchiveRace() {
    if (archiveCount == 0) {
        lastEvalProgress = 0.0f;
        lastEvalPipes = 0;
        lastEvalGeneration = 0;
        lastEvalSlot = 0;
        return 0;
    }

    Bird racers[ARCHIVE_SIZE];
    bool alive[ARCHIVE_SIZE];
    uint8_t aliveRacers = archiveCount;

    resetEvaluationCourse();
    for (uint8_t i = 0; i < archiveCount; i++) {
        racers[i].y = 30.0f;
        racers[i].vel = 0.0f;
        racers[i].alive = true;
        racers[i].pipes = 0;
        racers[i].frames = 0;
        racers[i].fitness = 0.0f;
        alive[i] = true;
    }

    drawLoading("Evaluating archive", "held-out course", 0, archiveCount);

    for (uint16_t frame = 0; frame < EVAL_MAX_FRAMES && aliveRacers > 0; frame++) {
        float oldPipeX = pipeX;
        pipeX -= pipeSpeedForDifficulty();
        bool pipePassed = (oldPipeX + PIPE_W >= BIRD_X) && (pipeX + PIPE_W < BIRD_X);

        if (pipeX < -PIPE_W) {
            resetPipe();
        }

        for (uint8_t i = 0; i < archiveCount; i++) {
            if (!alive[i]) continue;

            float output = runNetwork(archive[i].brain, racers[i]);
            if (output > 0.55f) {
                racers[i].vel = -2.45f;
            }

            racers[i].vel += 0.22f;
            if (racers[i].vel > 2.8f) racers[i].vel = 2.8f;
            racers[i].y += racers[i].vel;
            racers[i].frames++;

            if (pipePassed) {
                racers[i].pipes++;
            }

            float gapError = fabsf((racers[i].y + BIRD_H * 0.5f) - (float)gapY);
            float progress = progressForBird(racers[i]);
            racers[i].fitness = progress + (float)racers[i].pipes * 1000.0f - gapError * 0.25f;

            if (birdCollides(racers[i])) {
                alive[i] = false;
                aliveRacers--;
            }
        }

        if ((frame % 240) == 0) {
            drawLoading("Evaluating archive", "held-out course", archiveCount - aliveRacers, archiveCount);
        }
    }

    uint8_t bestIdx = 0;
    float bestProgress = progressForBird(racers[0]);
    for (uint8_t i = 1; i < archiveCount; i++) {
        float progress = progressForBird(racers[i]);
        if (progress > bestProgress) {
            bestProgress = progress;
            bestIdx = i;
        }
    }

    lastEvalSlot = bestIdx;
    lastEvalProgress = bestProgress;
    lastEvalPipes = racers[bestIdx].pipes;
    lastEvalGeneration = archive[bestIdx].generation;
    bestBrain = archive[bestIdx].brain;
    bestBrainValid = true;
    drawLoading("Evaluating archive", "winner selected", archiveCount, archiveCount);
    return bestIdx;
}

void prepareAndUploadBrainToFpga() {
    if (archiveCount > 0) {
        runArchiveRace();
    } else {
        drawLoading("Evaluating archive", "no champions yet", 0, 1);
    }

    const Brain& brain = bestBrainValid ? bestBrain : brains[0];
    uploadBrainToFpga(brain);
}

void sendStateToFpga(const Bird& bird) {
    float inputs[INPUTS];
    makeInputs(bird, inputs);

    uint8_t seq = stateSeq++ & 0x7F;
    uint8_t in0 = (uint8_t)quantizeInput(inputs[0]);
    uint8_t in1 = (uint8_t)quantizeInput(inputs[1]);
    uint8_t in2 = (uint8_t)quantizeInput(inputs[2]);
    uint8_t in3 = (uint8_t)quantizeInput(inputs[3]);
    uint8_t chk = ESP_SYNC ^ ESP_STATE ^ seq ^ in0 ^ in1 ^ in2 ^ in3;

    FpgaSerial.write(ESP_SYNC);
    FpgaSerial.write(ESP_STATE);
    FpgaSerial.write(seq);
    FpgaSerial.write(in0);
    FpgaSerial.write(in1);
    FpgaSerial.write(in2);
    FpgaSerial.write(in3);
    FpgaSerial.write(chk);
    inferRequests++;
}

void enterFpgaInferenceMode() {
    fpgaInferenceMode = true;
    if (aliveCount() > 0) {
        evolve();
    }
    prepareAndUploadBrainToFpga();
    resetFpgaGame();
    sendStateToFpga(fpgaBird);
}

void updateFpgaInferenceSimulation() {
    if (resetRequested) {
        resetRequested = false;
        weightsUploaded = false;
    }

    if (!weightsUploaded) {
        prepareAndUploadBrainToFpga();
        resetFpgaGame();
    }

    if (!fpgaBird.alive) {
        resetFpgaGame();
    }

    bool flapNow = lastFpgaFlap;
    lastFpgaFlap = false;
    if (flapNow) {
        fpgaBird.vel = -2.45f;
    }

    float oldPipeX = pipeX;
    pipeX -= pipeSpeedForDifficulty();
    bool pipePassed = (oldPipeX + PIPE_W >= BIRD_X) && (pipeX + PIPE_W < BIRD_X);

    if (pipeX < -PIPE_W) {
        resetPipe();
    }

    fpgaBird.vel += 0.22f;
    if (fpgaBird.vel > 2.8f) fpgaBird.vel = 2.8f;
    fpgaBird.y += fpgaBird.vel;
    fpgaBird.frames++;
    fpgaFrames++;

    if (pipePassed) {
        fpgaBird.pipes++;
        fpgaScore = fpgaBird.pipes;
        if (fpgaScore > bestPipesEver) {
            bestPipesEver = fpgaScore;
        }
    }

    if (birdCollides(fpgaBird)) {
        fpgaBird.alive = false;
    }

    sendStateToFpga(fpgaBird);
}

void drawPipes() {
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
}

void drawTraining() {
    if (!oledOk) return;

    display.clearDisplay();
    display.setTextColor(SSD1306_WHITE);
    display.setTextSize(1);

    display.setCursor(0, 0);
    display.printf("Train Gen:%lu",
                   (unsigned long)generation);
    display.setCursor(0, 10);
    display.printf("Alive:%02u Diff:%02u",
                   aliveCount(),
                   difficulty);
    display.setCursor(0, 20);
    display.printf("Max distance:%lu",
                   (unsigned long)lastChampionProgress);
    display.setCursor(0, 30);
    display.printf("Previous PB:%u",
                   lastChampionPipes);
    display.setCursor(0, 40);
    display.printf("Current PB:%u",
                   bestPipesEver);

    for (uint8_t i = 0; i < archiveCount; i++) {
        int16_t h = (int16_t)(archive[i].progress / 75.0f);
        if (h > 9) h = 9;
        display.drawFastVLine(i * 12, 62 - h, h, SSD1306_WHITE);
    }

    display.display();
}

void drawFpgaInference() {
    if (!oledOk) return;

    display.clearDisplay();
    display.setTextColor(SSD1306_WHITE);
    display.setTextSize(1);
    display.setCursor(0, 0);
    display.printf("SCORE:%03u  Diff: %02u", fpgaScore > 999 ? 999 : fpgaScore, difficulty);
    display.drawFastHLine(0, HUD_H - 1, SCREEN_W, SSD1306_WHITE);
    drawPipes();

    int16_t y = (int16_t)fpgaBird.y;
    if (y >= HUD_H && y < SCREEN_H) {
        display.fillRect(BIRD_X, y, BIRD_W, BIRD_H, SSD1306_WHITE);
        display.drawPixel(BIRD_X + BIRD_W, y + 1, SSD1306_WHITE);
    }

    if (!fpgaBird.alive) {
        display.setCursor(36, 34);
        display.print("RESET");
    }

    display.display();
}

void handlePacket(uint8_t type, uint8_t value) {
    packetCount++;

    if (type == FP_DIFF) {
        uint8_t newDifficulty = value & 0x0F;
        if (difficulty != newDifficulty) {
            difficulty = newDifficulty;
            if (fpgaInferenceMode) {
                weightsUploaded = false;
                resetFpgaGame();
            } else {
                initializeTraining();
            }
        }
    } else if (type == FP_RESET) {
        difficulty = value & 0x0F;
        if (fpgaInferenceMode) {
            resetRequested = true;
        } else {
            finishGenerationRequested = true;
        }
    } else if (type == FP_MODE) {
        bool newMode = (value & 0x01) != 0;
        if (newMode && !fpgaInferenceMode) {
            enterFpgaInferenceMode();
        } else if (!newMode && fpgaInferenceMode) {
            fpgaInferenceMode = false;
            startGeneration();
        }
    } else if (type == FP_INFER) {
        lastResponseSeq = value >> 1;
        lastFpgaFlap = (value & 0x01) != 0;
        inferResponses++;
    }
}

void parseByte(uint8_t b) {
    switch (parseState) {
        case WAIT_SYNC:
            if (b == FPGA_SYNC) parseState = READ_TYPE;
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
            uint8_t expected = FPGA_SYNC ^ pktType ^ pktValue;
            if (b == expected) {
                handlePacket(pktType, pktValue);
            } else {
                badPackets++;
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

void setup() {
    Serial.begin(115200);
    delay(250);
    Serial.println();
    Serial.println("--- Flappy Bird Part 3 FPGA Inference ---");

    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    oledOk = display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR);
    if (!oledOk) {
        Serial.println("OLED init failed");
    }

    FpgaSerial.begin(FPGA_BAUD, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);
    initializeTraining();
    resetFpgaGame();
}

void loop() {
    readFpgaPackets();

    uint32_t now = millis();
    if (fpgaInferenceMode) {
        if (now - lastFrameMs >= FRAME_MS) {
            lastFrameMs = now;
            updateFpgaInferenceSimulation();
            drawFpgaInference();
        }
    } else {
        if (now - lastFrameMs >= FRAME_MS) {
            lastFrameMs = now;
            for (uint8_t i = 0; i < TRAIN_STEPS_PER_TICK; i++) {
                updateTrainingSimulation();
            }
        }
        if (now - lastDrawMs >= TRAIN_DRAW_MS) {
            lastDrawMs = now;
            drawTraining();
        }
    }

    static uint32_t lastSerialMs = 0;
    if (now - lastSerialMs >= 1000) {
        lastSerialMs = now;
        Serial.printf("mode=%s gen=%lu alive=%u progress=%.1f delta=%.1f archive=%u evalGen=%lu evalP=%.1f fpga=%u req=%lu resp=%lu seq=%u bad=%lu\n",
                      fpgaInferenceMode ? "fpga" : "train",
                      (unsigned long)generation,
                      aliveCount(),
                      lastChampionProgress,
                      championDelta,
                      archiveCount,
                      (unsigned long)lastEvalGeneration,
                      lastEvalProgress,
                      fpgaScore,
                      (unsigned long)inferRequests,
                      (unsigned long)inferResponses,
                      lastResponseSeq,
                      (unsigned long)badPackets);
    }
}
