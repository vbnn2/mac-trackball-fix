//
// --------------------------------------------------------------------------
// RingMotionReplay.c
// Minimal deterministic JSONL trace runner for the pure ring model.
// --------------------------------------------------------------------------
//

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../Helper/Core/Scroll/RingMotionModel.h"

static bool readNumber(
    const char *line,
    const char *field,
    double *result
) {
    const char *value = strstr(line, field);
    if (value == NULL) return false;
    value += strlen(field);
    while (*value == ' ' || *value == '\t') value++;
    if (strncmp(value, "null", 4) == 0) return false;

    errno = 0;
    char *end = NULL;
    double parsed = strtod(value, &end);
    if (errno != 0 || end == value || !isfinite(parsed)) return false;
    *result = parsed;
    return true;
}

static bool lineHasKind(const char *line, const char *kind) {
    char pattern[96];
    int length = snprintf(pattern, sizeof(pattern), "\"kind\":\"%s\"", kind);
    return length > 0
        && (size_t)length < sizeof(pattern)
        && strstr(line, pattern) != NULL;
}

static int replay(const char *path) {
    FILE *file = fopen(path, "r");
    if (file == NULL) {
        fprintf(stderr, "RingMotionReplay: cannot open %s: %s\n",
                path, strerror(errno));
        return 1;
    }

    MFRingMotionConfig config = MFRingMotionConfigDefault();
    MFRingMotionState state;
    uint64_t generation = 1;
    MFRingMotionInitialize(&state, generation);
    char line[8192];
    size_t inputs = 0;
    size_t skippedInputs = 0;
    size_t resets = 0;
    size_t reversals = 0;
    size_t firstFrameFailures = 0;
    double previousTimestamp = 0.0;
    bool hasPreviousTimestamp = false;
    int previousInputSign = 0;
    double outputPixels = 0.0;
    double maximumRemainingPixels = 0.0;

    while (fgets(line, sizeof(line), file) != NULL) {
        if (lineHasKind(line, "session") && strstr(line, "\"event\":\"reset\"") != NULL) {
            generation += 1;
            MFRingMotionReset(&state, generation);
            if (state.hasAcceptedReport
                || state.velocityPixelsPerSecond != 0.0
                || MFRingMotionRemainingDistance(&state) != 0.0) {
                fprintf(stderr, "RingMotionReplay: reset retained state in %s\n", path);
                fclose(file);
                return 1;
            }
            hasPreviousTimestamp = false;
            previousInputSign = 0;
            resets += 1;
            continue;
        }
        if (!lineHasKind(line, "input")) continue;

        double timestamp;
        double units;
        if (!readNumber(line, "\"timestamp\":", &timestamp)
            || (!readNumber(line, "\"rawUnits\":", &units)
                && !readNumber(line, "\"cgLine\":", &units))) {
            skippedInputs += 1;
            continue;
        }
        if (units == 0.0 || units < (double)INT64_MIN || units > (double)INT64_MAX) {
            skippedInputs += 1;
            continue;
        }

        if (hasPreviousTimestamp && timestamp > previousTimestamp) {
            outputPixels += MFRingMotionAdvance(
                &state, timestamp - previousTimestamp).distancePixels;
        }
        MFRingMotionUpdate update = MFRingMotionApplyReport(
            &config,
            &state,
            (MFRingMotionReport) {
                .generation = generation,
                .timestamp = timestamp,
                .signedUnits = (int64_t)units,
            });
        if (!update.accepted) {
            fprintf(stderr, "RingMotionReplay: rejected input in %s at %.9f\n",
                    path, timestamp);
            fclose(file);
            return 1;
        }
        inputs += 1;
        previousTimestamp = timestamp;
        hasPreviousTimestamp = true;

        int inputSign = (units > 0.0) - (units < 0.0);
        if (previousInputSign != 0 && inputSign != previousInputSign) {
            reversals += 1;
            if (!update.directionChanged) {
                fprintf(stderr, "RingMotionReplay: missed reversal in %s at %.9f\n",
                        path, timestamp);
                fclose(file);
                return 1;
            }
        }
        previousInputSign = inputSign;
        if ((state.velocityPixelsPerSecond > 0.0)
                - (state.velocityPixelsPerSecond < 0.0) != inputSign) {
            fprintf(stderr, "RingMotionReplay: old-sign velocity survived in %s at %.9f\n",
                    path, timestamp);
            fclose(file);
            return 1;
        }
        maximumRemainingPixels = fmax(
            maximumRemainingPixels,
            MFRingMotionRemainingDistance(&state));

        MFRingMotionState firstFrameState = state;
        MFRingMotionFrame firstFrame = MFRingMotionAdvance(
            &firstFrameState, 1.0 / 120.0);
        if (!firstFrame.accepted
            || firstFrame.distancePixels == 0.0
            || ((firstFrame.distancePixels > 0.0)
                - (firstFrame.distancePixels < 0.0)) != inputSign) {
            firstFrameFailures += 1;
        }
        if (!isfinite(state.velocityPixelsPerSecond)
            || MFRingMotionRemainingDistance(&state)
                > config.maximumRemainingDistancePixels + 1e-9) {
            fprintf(stderr, "RingMotionReplay: unbounded state in %s at %.9f\n",
                    path, timestamp);
            fclose(file);
            return 1;
        }
    }
    fclose(file);

    outputPixels += copysign(MFRingMotionRemainingDistance(&state),
                             state.velocityPixelsPerSecond);
    if (inputs > 0 && firstFrameFailures > 0) {
        fprintf(stderr, "RingMotionReplay: %zu invisible first frames in %s\n",
                firstFrameFailures, path);
        return 1;
    }
    printf("RingMotionReplay: PASS fixture=%s inputs=%zu skipped=%zu resets=%zu reversals=%zu maxRemainingPx=%.3f outputPx=%.3f\n",
           path, inputs, skippedInputs, resets, reversals,
           maximumRemainingPixels, outputPixels);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s fixture.jsonl [...]\n", argv[0]);
        return 2;
    }
    int status = 0;
    for (int index = 1; index < argc; index++) {
        if (replay(argv[index]) != 0) status = 1;
    }
    return status;
}
