#!/usr/bin/env python3
"""Summarize TB800 raw correlation plus shadow/live engine telemetry."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Iterable


FIELD_PATTERN = re.compile(r"([A-Za-z][A-Za-z0-9]*)=([^\s]+)")
LEGACY_LINE_PATTERN = re.compile(r"\bline=\((-?\d+),(-?\d+)\)")
HELPER_PID_PATTERN = re.compile(r"Mac Mouse Fix Helper\[(\d+):")


def _fields(line: str) -> dict[str, str]:
    return dict(FIELD_PATTERN.findall(line))


def _integer(value: str | None, default: int = 0) -> int:
    try:
        return int(value) if value is not None else default
    except ValueError:
        return default


def _number(value: str | None) -> float | None:
    try:
        result = float(value) if value is not None else None
    except ValueError:
        return None
    return result if result is not None and math.isfinite(result) else None


def _percentile(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * percentile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * fraction


def analyze(lines: Iterable[str]) -> dict[str, object]:
    capture_lines = list(lines)
    session_pids: list[int] = []
    selected_pid: int | None = None
    for line in capture_lines:
        if "MFSCROLL_RING_HID:" not in line:
            continue
        pid_match = HELPER_PID_PATTERN.search(line)
        if pid_match is None:
            continue
        pid = int(pid_match.group(1))
        if pid not in session_pids:
            session_pids.append(pid)
        if _fields(line).get("action") == "start":
            selected_pid = pid
    if selected_pid is None and session_pids:
        selected_pid = session_pids[-1]

    raw_samples: dict[int, dict[str, str]] = {}
    ring_inputs: list[dict[str, str]] = []
    starts: list[dict[str, str]] = []
    attachments: list[dict[str, str]] = []
    detachments: list[dict[str, str]] = []
    legacy_inputs: list[tuple[int, int]] = []
    legacy_first_output_ms: list[float] = []
    legacy_input_queue_ms: list[float] = []
    live_first_output_ms: list[float] = []
    live_input_queue_ms: list[float] = []
    live_first_output_by_axis: dict[str, list[float]] = defaultdict(list)
    live_input_queue_by_axis: dict[str, list[float]] = defaultdict(list)
    engine_selections: list[dict[str, str]] = []
    route_records: list[dict[str, str]] = []
    model_records: list[dict[str, str]] = []
    frame_records: list[dict[str, str]] = []
    renderer_records: list[dict[str, str]] = []
    display_records: list[dict[str, str]] = []
    tap_records: list[dict[str, str]] = []
    maximum_overflow_count = 0

    ignored_other_session_lines = 0
    for line in capture_lines:
        pid_match = HELPER_PID_PATTERN.search(line)
        if (selected_pid is not None
                and pid_match is not None
                and int(pid_match.group(1)) != selected_pid):
            ignored_other_session_lines += 1
            continue
        if "MFSCROLL_RING_HID:" in line:
            fields = _fields(line)
            action = fields.get("action")
            if action == "sample":
                sequence = _integer(fields.get("rawSequence"))
                if sequence > 0:
                    raw_samples[sequence] = fields
                maximum_overflow_count = max(
                    maximum_overflow_count,
                    _integer(fields.get("overflowCount")),
                )
            elif action == "start":
                starts.append(fields)
            elif action == "attach":
                attachments.append(fields)
            elif action == "detach":
                detachments.append(fields)
        elif "MFSCROLL_RING_INPUT:" in line:
            ring_inputs.append(_fields(line))
        elif "MFSCROLL_RING_ENGINE:" in line:
            engine_selections.append(_fields(line))
        elif "MFSCROLL_RING_ROUTE:" in line:
            route_records.append(_fields(line))
        elif "MFSCROLL_RING_MODEL:" in line:
            model_records.append(_fields(line))
        elif "MFSCROLL_RING_FRAME:" in line:
            frame_records.append(_fields(line))
        elif "MFSCROLL_RING_RENDERER:" in line:
            renderer_records.append(_fields(line))
        elif "MFSCROLL_DISPLAY:" in line:
            display_records.append(_fields(line))
        elif "MFSCROLL_TAP:" in line:
            tap_records.append(_fields(line))
        elif "MFSCROLL_INPUT:" in line:
            match = LEGACY_LINE_PATTERN.search(line)
            if match is not None:
                legacy_inputs.append((int(match.group(1)), int(match.group(2))))
        elif "MFSCROLL_LATENCY:" in line:
            fields = _fields(line)
            first_output = _number(fields.get("inputToFirstOutputMs"))
            input_queue = _number(fields.get("inputQueueMs"))
            if fields.get("path") == "ring-live":
                axis = fields.get("axis", "unknown")
                if first_output is not None:
                    live_first_output_ms.append(first_output)
                    live_first_output_by_axis[axis].append(first_output)
                if input_queue is not None:
                    live_input_queue_ms.append(input_queue)
                    live_input_queue_by_axis[axis].append(input_queue)
            else:
                if first_output is not None:
                    legacy_first_output_ms.append(first_output)
                if input_queue is not None:
                    legacy_input_queue_ms.append(input_queue)

    paired = [entry for entry in ring_inputs if entry.get("source") == "hid"]
    fallback = [
        entry for entry in ring_inputs
        if entry.get("source") == "cg-line-fallback"
    ]
    hid_to_cg = [
        timing
        for timing in (_number(entry.get("hidToCGMs")) for entry in paired)
        if timing is not None
    ]
    matched_sequences = {
        _integer(entry.get("rawSequence"))
        for entry in paired
        if _integer(entry.get("rawSequence")) > 0
    }
    sign_mismatches = 0
    for entry in paired:
        units = _integer(entry.get("units"))
        cg_units = _integer(entry.get("cgLine"))
        if cg_units == 0:
            cg_units = _integer(entry.get("cgPoint"))
        if (units > 0) != (cg_units > 0):
            sign_mismatches += 1

    input_count = len(ring_inputs)
    raw_count = len(raw_samples)
    paired_count = len(paired)
    legacy_input_count = len(legacy_inputs)
    legacy_vertical_count = sum(vertical != 0 for vertical, _ in legacy_inputs)
    legacy_horizontal_count = sum(horizontal != 0 for _, horizontal in legacy_inputs)
    magnitude_matches = sum(
        _integer(entry.get("magnitudeMatch")) != 0 for entry in paired
    )
    input_devices = sorted({
        _integer(entry.get("device"))
        for entry in ring_inputs
        if _integer(entry.get("device")) != 0
    })
    raw_devices = sorted({
        _integer(entry.get("device"))
        for entry in raw_samples.values()
        if _integer(entry.get("device")) != 0
    })
    accepted_models = [
        entry for entry in model_records
        if entry.get("action") not in {"reset", "reject"}
    ]
    rejected_models = [
        entry for entry in model_records if entry.get("action") == "reject"
    ]
    frame_rates = [
        value for value in (_number(entry.get("frameHz"))
                            for entry in frame_records)
        if value is not None and value > 0
    ]
    frame_gaps = [
        value for value in (_number(entry.get("maxFrameGapMs"))
                            for entry in frame_records)
        if value is not None
    ]
    live_model_records = [
        entry for entry in accepted_models if entry.get("engine") == "ring-live"
    ]
    live_routes = [
        entry for entry in route_records if entry.get("action") == "live"
    ]
    fallback_routes = [
        entry for entry in route_records if entry.get("action") == "fallback"
    ]
    live_route_axis_counts = Counter(
        entry.get("axis", "unknown") for entry in live_routes
    )
    live_model_axis_counts = Counter(
        entry.get("axis", "unknown") for entry in live_model_records
    )
    frame_callback_axis_counts = Counter()
    frame_event_axis_counts = Counter()
    for entry in frame_records:
        axis = entry.get("axis", "unknown")
        frame_callback_axis_counts[axis] += _integer(entry.get("callbacks"))
        if "verticalEvents" in entry or "horizontalEvents" in entry:
            frame_event_axis_counts["vertical"] += _integer(
                entry.get("verticalEvents"))
            frame_event_axis_counts["horizontal"] += _integer(
                entry.get("horizontalEvents"))
        else:
            frame_event_axis_counts[axis] += _integer(entry.get("events"))
    fallback_reason_counts = Counter(
        entry.get("reason", "unknown") for entry in fallback_routes
    )
    selected_engine = (
        engine_selections[-1].get("selected") if engine_selections else None
    )

    return {
        "schema": "mf-ring-capture-summary-v4",
        "capture": {
            "sessionPIDs": session_pids,
            "selectedPID": selected_pid,
            "ignoredOtherSessionLines": ignored_other_session_lines,
        },
        "sidecar": {
            "startRecords": len(starts),
            "successfulStarts": sum(
                entry.get("result") == "0" for entry in starts
            ),
            "attachments": len(attachments),
            "detachments": len(detachments),
        },
        "reports": {
            "rawSamples": raw_count,
            "cgTargetReports": input_count,
            "pairedHID": paired_count,
            "cgLineFallback": len(fallback),
            "pairingRate": paired_count / input_count if input_count else None,
            "capturedRawUtilization": (
                len(matched_sequences & raw_samples.keys()) / raw_count
                if raw_count else None
            ),
            "axisCounts": dict(sorted(Counter(
                entry.get("axis", "unknown") for entry in ring_inputs
            ).items())),
            "sourceCounts": dict(sorted(Counter(
                entry.get("source", "unknown") for entry in ring_inputs
            ).items())),
            "engineCounts": dict(sorted(Counter(
                entry.get("engine", "unknown") for entry in ring_inputs
            ).items())),
        },
        "agreement": {
            "signMismatches": sign_mismatches,
            "magnitudeMatches": magnitude_matches,
            "magnitudeMismatches": paired_count - magnitude_matches,
            "magnitudeMatchRate": (
                magnitude_matches / paired_count if paired_count else None
            ),
            "rawDeviceRegistryIDs": raw_devices,
            "inputDeviceRegistryIDs": input_devices,
            "deviceRegistryIDSetsMatch": (
                raw_devices == input_devices
                if raw_devices and input_devices else None
            ),
        },
        "timingMs": {
            "minimum": min(hid_to_cg) if hid_to_cg else None,
            "p50": _percentile(hid_to_cg, 0.50),
            "p95": _percentile(hid_to_cg, 0.95),
            "maximum": max(hid_to_cg) if hid_to_cg else None,
            "negativeSamples": sum(value < 0 for value in hid_to_cg),
        },
        "buffer": {
            "maximumOverflowCount": maximum_overflow_count,
        },
        "legacyPath": {
            "physicalReports": legacy_input_count,
            "verticalReports": legacy_vertical_count,
            "horizontalReports": legacy_horizontal_count,
            "multiUnitReports": sum(
                abs(vertical) > 1 or abs(horizontal) > 1
                for vertical, horizontal in legacy_inputs
            ),
            "positiveReports": sum(
                vertical > 0 or horizontal > 0
                for vertical, horizontal in legacy_inputs
            ),
            "negativeReports": sum(
                vertical < 0 or horizontal < 0
                for vertical, horizontal in legacy_inputs
            ),
            "latencySamples": len(legacy_first_output_ms),
            "firstOutputMs": {
                "minimum": (
                    min(legacy_first_output_ms)
                    if legacy_first_output_ms else None
                ),
                "p50": _percentile(legacy_first_output_ms, 0.50),
                "p95": _percentile(legacy_first_output_ms, 0.95),
                "maximum": (
                    max(legacy_first_output_ms)
                    if legacy_first_output_ms else None
                ),
            },
            "inputQueueMs": {
                "minimum": (
                    min(legacy_input_queue_ms)
                    if legacy_input_queue_ms else None
                ),
                "p50": _percentile(legacy_input_queue_ms, 0.50),
                "p95": _percentile(legacy_input_queue_ms, 0.95),
                "maximum": (
                    max(legacy_input_queue_ms)
                    if legacy_input_queue_ms else None
                ),
            },
        },
        "ringEngine": {
            "selected": selected_engine,
            "selectionRecords": len(engine_selections),
            "modelUpdates": len(accepted_models),
            "liveModelUpdates": len(live_model_records),
            "liveModelAxisCounts": dict(sorted(live_model_axis_counts.items())),
            "liveRoutes": len(live_routes),
            "liveRouteAxisCounts": dict(sorted(live_route_axis_counts.items())),
            "fallbackRoutes": len(fallback_routes),
            "fallbackReasonCounts": dict(sorted(fallback_reason_counts.items())),
            "modelRejects": len(rejected_models),
            "axisTransitionResets": sum(
                entry.get("action") == "reset"
                and entry.get("reason") == "axis-change"
                for entry in model_records
            ),
            "reversals": sum(
                _integer(entry.get("directionChanged")) != 0
                for entry in live_model_records
            ),
            "velocityLimitEvents": sum(
                _integer(entry.get("velocityLimited")) != 0
                for entry in live_model_records
            ),
            "responsivenessLimitEvents": sum(
                _integer(entry.get("responsivenessDecayLimited")) != 0
                for entry in live_model_records
            ),
            "stoppedOpeningResponsivenessLimitEvents": sum(
                _integer(entry.get(
                    "stoppedOpeningResponsivenessDecayLimited")) != 0
                for entry in live_model_records
            ),
            "stoppedOpeningDistanceRaiseEvents": sum(
                _integer(entry.get("stoppedOpeningDistanceRaised")) != 0
                for entry in live_model_records
            ),
            "stoppedOpeningVelocityLimitEvents": sum(
                _integer(entry.get(
                    "stoppedOpeningVelocityDecayLimited")) != 0
                for entry in live_model_records
            ),
            "carryDroppedPixels": sum(
                _number(entry.get("carryDroppedPx")) or 0.0
                for entry in live_model_records
            ),
            "maximumRemainingPixels": max(
                (_number(entry.get("remainingPx")) or 0.0
                 for entry in live_model_records),
                default=0.0,
            ),
            "latencySamples": len(live_first_output_ms),
            "firstOutputMs": {
                "minimum": min(live_first_output_ms)
                    if live_first_output_ms else None,
                "p50": _percentile(live_first_output_ms, 0.50),
                "p95": _percentile(live_first_output_ms, 0.95),
                "maximum": max(live_first_output_ms)
                    if live_first_output_ms else None,
            },
            "inputQueueMs": {
                "minimum": min(live_input_queue_ms)
                    if live_input_queue_ms else None,
                "p50": _percentile(live_input_queue_ms, 0.50),
                "p95": _percentile(live_input_queue_ms, 0.95),
                "maximum": max(live_input_queue_ms)
                    if live_input_queue_ms else None,
            },
            "axisFirstOutputMs": {
                axis: {
                    "minimum": min(values),
                    "p50": _percentile(values, 0.50),
                    "p95": _percentile(values, 0.95),
                    "maximum": max(values),
                    "samples": len(values),
                }
                for axis, values in sorted(live_first_output_by_axis.items())
            },
            "axisInputQueueMs": {
                axis: {
                    "minimum": min(values),
                    "p50": _percentile(values, 0.50),
                    "p95": _percentile(values, 0.95),
                    "maximum": max(values),
                    "samples": len(values),
                }
                for axis, values in sorted(live_input_queue_by_axis.items())
            },
        },
        "renderer": {
            "frameWindows": len(frame_records),
            "callbacks": sum(
                _integer(entry.get("callbacks")) for entry in frame_records
            ),
            "nonzeroEvents": sum(
                _integer(entry.get("events")) for entry in frame_records
            ),
            "callbackAxisCounts": dict(sorted(
                frame_callback_axis_counts.items()
            )),
            "eventAxisCounts": dict(sorted(frame_event_axis_counts.items())),
            "frameHz": {
                "minimum": min(frame_rates) if frame_rates else None,
                "p50": _percentile(frame_rates, 0.50),
                "maximum": max(frame_rates) if frame_rates else None,
            },
            "maximumFrameGapMs": max(frame_gaps) if frame_gaps else None,
            "parkedFrameDiscards": sum(
                entry.get("action") == "parked-frame-discard"
                for entry in renderer_records
            ),
            "stallDiscards": sum(
                entry.get("action") == "recover-stall-discard"
                for entry in renderer_records
            ),
            "latencyOverflows": sum(
                entry.get("action") == "latency-overflow"
                for entry in renderer_records
            ),
        },
        "lifecycle": {
            "displayStartFailures": sum(
                entry.get("action") == "start-failed"
                for entry in display_records
            ),
            "displayRecoveries": sum(
                entry.get("action") == "recover-stall"
                for entry in display_records
            ),
            "tapDisables": sum(
                "disable" in entry.get("action", "") for entry in tap_records
            ),
        },
        "gate": {
            "hasPhysicalInput": input_count > 0 or legacy_input_count > 0,
            "hasRawSamples": raw_count > 0,
            "rawAcquisitionGap": legacy_input_count > 0 and raw_count == 0,
            "hasBothAxes": {
                entry.get("axis") for entry in ring_inputs
            } >= {"vertical", "horizontal"},
            "readyForReview": (
                input_count > 0
                and raw_count > 0
                and paired_count > 0
                and maximum_overflow_count == 0
            ),
            "liveCaptureReadyForReview": (
                selected_engine == "ring-live"
                and len(live_model_records) > 0
                and len(live_first_output_ms) > 0
                and len(rejected_models) == 0
            ),
            "hasHorizontalLiveOutput": (
                live_route_axis_counts["horizontal"] > 0
                and live_model_axis_counts["horizontal"] > 0
                and frame_event_axis_counts["horizontal"] > 0
            ),
            "hasNoAxisTransitionResets": not any(
                entry.get("action") == "reset"
                and entry.get("reason") == "axis-change"
                for entry in model_records
            ),
            "hasCompatibilityFallbackCoverage": (
                set(fallback_reason_counts)
                >= {"effect", "system-acceleration", "non-regular"}
            ),
        },
    }


def _format_rate(value: object) -> str:
    return "n/a" if value is None else f"{float(value) * 100.0:.1f}%"


def print_human(summary: dict[str, object]) -> None:
    capture = summary["capture"]
    sidecar = summary["sidecar"]
    reports = summary["reports"]
    agreement = summary["agreement"]
    timing = summary["timingMs"]
    buffer = summary["buffer"]
    legacy = summary["legacyPath"]
    engine = summary["ringEngine"]
    renderer = summary["renderer"]
    lifecycle = summary["lifecycle"]
    gate = summary["gate"]

    print("TB800 ring capture summary")
    print(
        f"  session: selectedPID={capture['selectedPID']} "
        f"seen={capture['sessionPIDs']} "
        f"ignoredOtherLines={capture['ignoredOtherSessionLines']}"
    )
    print(
        f"  sidecar: starts={sidecar['startRecords']} "
        f"successful={sidecar['successfulStarts']} "
        f"attach={sidecar['attachments']} detach={sidecar['detachments']}"
    )
    print(
        f"  reports: raw={reports['rawSamples']} cg={reports['cgTargetReports']} "
        f"paired={reports['pairedHID']} fallback={reports['cgLineFallback']} "
        f"pairing={_format_rate(reports['pairingRate'])}"
    )
    print(
        f"  axes: {reports['axisCounts']} sources: {reports['sourceCounts']}"
    )
    print(
        f"  agreement: signMismatch={agreement['signMismatches']} "
        f"magnitudeMatch={_format_rate(agreement['magnitudeMatchRate'])} "
        f"deviceIDsMatch={agreement['deviceRegistryIDSetsMatch']}"
    )
    if timing["p50"] is None:
        print("  HID->CG timing ms: n/a")
    else:
        print(
            "  HID->CG timing ms: "
            f"min={timing['minimum']:.3f} p50={timing['p50']:.3f} "
            f"p95={timing['p95']:.3f} max={timing['maximum']:.3f} "
            f"negative={timing['negativeSamples']}"
        )
    print(f"  buffer overflow count: {buffer['maximumOverflowCount']}")
    print(
        f"  legacy input: reports={legacy['physicalReports']} "
        f"vertical={legacy['verticalReports']} "
        f"horizontal={legacy['horizontalReports']} "
        f"multiUnit={legacy['multiUnitReports']} "
        f"positive={legacy['positiveReports']} "
        f"negative={legacy['negativeReports']}"
    )
    legacy_latency = legacy["firstOutputMs"]
    if legacy_latency["p50"] is not None:
        print(
            "  legacy first-output ms: "
            f"min={legacy_latency['minimum']:.3f} "
            f"p50={legacy_latency['p50']:.3f} "
            f"p95={legacy_latency['p95']:.3f} "
            f"max={legacy_latency['maximum']:.3f}"
        )
    print(
        f"  engine: selected={engine['selected']} "
        f"models={engine['liveModelUpdates']} rejects={engine['modelRejects']} "
        f"axisResets={engine['axisTransitionResets']} "
        f"reversals={engine['reversals']} "
        f"velocityCaps={engine['velocityLimitEvents']} "
        f"responseCaps={engine['responsivenessLimitEvents']} "
        f"stoppedOpeningCaps={engine['stoppedOpeningResponsivenessLimitEvents']} "
        f"stoppedDistanceRaises={engine['stoppedOpeningDistanceRaiseEvents']} "
        f"stoppedVelocityCaps={engine['stoppedOpeningVelocityLimitEvents']} "
        f"carryDroppedPx={engine['carryDroppedPixels']:.3f} "
        f"maxRemainingPx={engine['maximumRemainingPixels']:.3f}"
    )
    print(
        f"  routing: live={engine['liveRoutes']} "
        f"axes={engine['liveRouteAxisCounts']} "
        f"fallback={engine['fallbackRoutes']} "
        f"reasons={engine['fallbackReasonCounts']}"
    )
    live_latency = engine["firstOutputMs"]
    if live_latency["p50"] is not None:
        print(
            "  ring-live first-output ms: "
            f"min={live_latency['minimum']:.3f} "
            f"p50={live_latency['p50']:.3f} "
            f"p95={live_latency['p95']:.3f} "
            f"max={live_latency['maximum']:.3f}"
        )
        print(f"  ring-live latency axes: {engine['axisFirstOutputMs']}")
        print(f"  ring-live queue axes: {engine['axisInputQueueMs']}")
    print(
        f"  renderer: windows={renderer['frameWindows']} "
        f"callbacks={renderer['callbacks']} events={renderer['nonzeroEvents']} "
        f"eventAxes={renderer['eventAxisCounts']} "
        f"maxGapMs={renderer['maximumFrameGapMs']} "
        f"parkedDiscards={renderer['parkedFrameDiscards']} "
        f"stallDiscards={renderer['stallDiscards']}"
    )
    print(
        f"  lifecycle: startFailures={lifecycle['displayStartFailures']} "
        f"recoveries={lifecycle['displayRecoveries']} "
        f"tapDisables={lifecycle['tapDisables']}"
    )
    print(f"  raw acquisition gap: {gate['rawAcquisitionGap']}")
    print(f"  ready for review: {gate['readyForReview']}")
    print(f"  ring-live ready for review: {gate['liveCaptureReadyForReview']}")
    print(f"  horizontal live output observed: {gate['hasHorizontalLiveOutput']}")
    print(f"  axis transitions preserve state: {gate['hasNoAxisTransitionResets']}")
    print(
        "  compatibility fallbacks observed: "
        f"{gate['hasCompatibilityFallbackCoverage']}"
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture", type=Path)
    parser.add_argument("--json", action="store_true")
    arguments = parser.parse_args(argv)

    try:
        with arguments.capture.open(encoding="utf-8", errors="replace") as capture:
            summary = analyze(capture)
    except OSError as error:
        parser.error(str(error))

    if arguments.json:
        json.dump(summary, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        print_human(summary)
    return 0 if summary["gate"]["hasPhysicalInput"] else 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
