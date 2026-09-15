#!/usr/bin/env python3

import unittest

from ring_capture_analyzer import analyze


class RingCaptureAnalyzerTests(unittest.TestCase):

    def test_pairing_timing_agreement_and_overflow_summary(self):
        summary = analyze([
            "MFSCROLL_RING_HID: version=1 action=start result=0\n",
            "MFSCROLL_RING_HID: version=1 action=attach device=42\n",
            "MFSCROLL_RING_HID: version=1 action=sample rawSequence=1 device=42 axis=vertical units=1 overflowCount=0\n",
            "MFSCROLL_RING_HID: version=1 action=sample rawSequence=2 device=42 axis=vertical units=2 overflowCount=0\n",
            "MFSCROLL_RING_HID: version=1 action=sample rawSequence=3 device=42 axis=horizontal units=-2 overflowCount=0\n",
            "MFSCROLL_RING_INPUT: source=hid rawSequence=1 device=42 axis=vertical units=1 hidToCGMs=3.000 magnitudeMatch=1 cgLine=1 cgPoint=6\n",
            "MFSCROLL_RING_INPUT: source=cg-line-fallback rawSequence=0 device=42 axis=vertical units=2 hidToCGMs=-1.000 magnitudeMatch=0 cgLine=2 cgPoint=20\n",
            "MFSCROLL_RING_INPUT: source=hid rawSequence=3 device=42 axis=horizontal units=-2 hidToCGMs=5.000 magnitudeMatch=0 cgLine=-1 cgPoint=-8\n",
        ])

        self.assertEqual(summary["sidecar"]["successfulStarts"], 1)
        self.assertEqual(summary["reports"]["rawSamples"], 3)
        self.assertEqual(summary["reports"]["cgTargetReports"], 3)
        self.assertEqual(summary["reports"]["pairedHID"], 2)
        self.assertEqual(summary["reports"]["cgLineFallback"], 1)
        self.assertAlmostEqual(summary["reports"]["pairingRate"], 2 / 3)
        self.assertAlmostEqual(
            summary["reports"]["capturedRawUtilization"], 2 / 3)
        self.assertEqual(
            summary["reports"]["axisCounts"],
            {"horizontal": 1, "vertical": 2},
        )
        self.assertEqual(summary["agreement"]["signMismatches"], 0)
        self.assertEqual(summary["agreement"]["magnitudeMatches"], 1)
        self.assertEqual(summary["timingMs"]["minimum"], 3.0)
        self.assertEqual(summary["timingMs"]["p50"], 4.0)
        self.assertEqual(summary["timingMs"]["p95"], 4.9)
        self.assertEqual(summary["timingMs"]["maximum"], 5.0)
        self.assertEqual(summary["buffer"]["maximumOverflowCount"], 0)
        self.assertTrue(summary["gate"]["hasBothAxes"])
        self.assertTrue(summary["gate"]["readyForReview"])

    def test_empty_capture_is_not_ready(self):
        summary = analyze(["unrelated log line\n"])
        self.assertFalse(summary["gate"]["hasPhysicalInput"])
        self.assertFalse(summary["gate"]["hasRawSamples"])
        self.assertFalse(summary["gate"]["readyForReview"])
        self.assertIsNone(summary["reports"]["pairingRate"])

    def test_legacy_input_without_raw_samples_exposes_acquisition_gap(self):
        summary = analyze([
            "MFSCROLL_INPUT: cont=0 phase=0 line=(3,0) point=(18,0)\n",
            "MFSCROLL_INPUT: cont=0 phase=0 line=(-1,0) point=(-6,0)\n",
            "MFSCROLL_LATENCY: inputToFirstOutputMs=8.0 inputQueueMs=1.0\n",
            "MFSCROLL_LATENCY: inputToFirstOutputMs=12.0 inputQueueMs=3.0\n",
        ])

        self.assertTrue(summary["gate"]["hasPhysicalInput"])
        self.assertTrue(summary["gate"]["rawAcquisitionGap"])
        self.assertFalse(summary["gate"]["hasRawSamples"])
        self.assertEqual(summary["legacyPath"]["physicalReports"], 2)
        self.assertEqual(summary["legacyPath"]["verticalReports"], 2)
        self.assertEqual(summary["legacyPath"]["horizontalReports"], 0)
        self.assertEqual(summary["legacyPath"]["multiUnitReports"], 1)
        self.assertEqual(summary["legacyPath"]["positiveReports"], 1)
        self.assertEqual(summary["legacyPath"]["negativeReports"], 1)
        self.assertEqual(summary["legacyPath"]["firstOutputMs"]["p50"], 10.0)

    def test_latest_helper_session_is_selected(self):
        summary = analyze([
            "Mac Mouse Fix Helper[10:aaa] MFSCROLL_RING_HID: action=start result=0\n",
            "Mac Mouse Fix Helper[10:aaa] MFSCROLL_RING_HID: action=sample rawSequence=1 device=42 axis=vertical units=-1 overflowCount=0\n",
            "Mac Mouse Fix Helper[10:aaa] MFSCROLL_RING_INPUT: source=cg-line-fallback rawSequence=0 device=42 axis=vertical units=1\n",
            "Mac Mouse Fix Helper[20:bbb] MFSCROLL_RING_HID: action=start result=0\n",
            "Mac Mouse Fix Helper[20:bbb] MFSCROLL_RING_HID: action=sample rawSequence=1 device=42 axis=vertical units=1 overflowCount=0\n",
            "Mac Mouse Fix Helper[20:bbb] MFSCROLL_RING_INPUT: source=hid rawSequence=1 device=42 axis=vertical units=1 hidToCGMs=0 magnitudeMatch=1 cgLine=1\n",
        ])

        self.assertEqual(summary["capture"]["sessionPIDs"], [10, 20])
        self.assertEqual(summary["capture"]["selectedPID"], 20)
        self.assertEqual(summary["reports"]["rawSamples"], 1)
        self.assertEqual(summary["reports"]["pairedHID"], 1)
        self.assertEqual(summary["reports"]["cgLineFallback"], 0)
        self.assertEqual(summary["reports"]["pairingRate"], 1.0)

    def test_ring_live_renderer_and_latency_summary(self):
        summary = analyze([
            "MFSCROLL_RING_HID: action=start result=0\n",
            "MFSCROLL_RING_HID: action=sample rawSequence=1 device=42 axis=vertical units=1 overflowCount=0\n",
            "MFSCROLL_RING_ENGINE: action=select selected=ring-live\n",
            "MFSCROLL_RING_INPUT: engine=ring-live source=hid rawSequence=1 device=42 axis=vertical units=1 hidToCGMs=0 magnitudeMatch=1 cgLine=1\n",
            "MFSCROLL_RING_MODEL: engine=ring-live sequence=1 directionChanged=0 responsivenessDecayLimited=1 stoppedOpeningResponsivenessDecayLimited=1 stoppedOpeningDistanceRaised=1 stoppedOpeningVelocityDecayLimited=1 velocityLimited=0 carryDroppedPx=0 remainingPx=20\n",
            "MFSCROLL_LATENCY: path=ring-live sequence=1 inputToFirstOutputMs=8 inputQueueMs=1\n",
            "MFSCROLL_RING_FRAME: engine=ring-live action=stop frameHz=120 maxFrameGapMs=8.4 callbacks=4 events=3\n",
            "MFSCROLL_RING_RENDERER: engine=ring-live action=parked-frame-discard\n",
            "MFSCROLL_DISPLAY: action=start result=0\n",
        ])

        self.assertEqual(summary["ringEngine"]["selected"], "ring-live")
        self.assertEqual(summary["ringEngine"]["liveModelUpdates"], 1)
        self.assertEqual(summary["ringEngine"]["responsivenessLimitEvents"], 1)
        self.assertEqual(
            summary["ringEngine"]["stoppedOpeningResponsivenessLimitEvents"], 1)
        self.assertEqual(
            summary["ringEngine"]["stoppedOpeningDistanceRaiseEvents"], 1)
        self.assertEqual(
            summary["ringEngine"]["stoppedOpeningVelocityLimitEvents"], 1)
        self.assertEqual(summary["ringEngine"]["latencySamples"], 1)
        self.assertEqual(summary["ringEngine"]["firstOutputMs"]["p50"], 8.0)
        self.assertEqual(summary["renderer"]["callbacks"], 4)
        self.assertEqual(summary["renderer"]["parkedFrameDiscards"], 1)
        self.assertTrue(summary["gate"]["liveCaptureReadyForReview"])

    def test_phase5_horizontal_and_compatibility_routes(self):
        summary = analyze([
            "MFSCROLL_RING_ENGINE: action=select selected=ring-live\n",
            "MFSCROLL_RING_INPUT: engine=ring-live source=hid rawSequence=1 device=42 axis=vertical units=1 cgLine=1\n",
            "MFSCROLL_RING_INPUT: engine=ring-live source=hid rawSequence=2 device=42 axis=horizontal units=-1 cgLine=-1\n",
            "MFSCROLL_RING_ROUTE: engine=ring-live action=live sequence=1 axis=vertical reason=eligible\n",
            "MFSCROLL_RING_ROUTE: engine=ring-live action=live sequence=2 axis=horizontal reason=eligible\n",
            "MFSCROLL_RING_ROUTE: engine=ring-live action=fallback sequence=3 axis=vertical reason=effect\n",
            "MFSCROLL_RING_ROUTE: engine=ring-live action=fallback sequence=4 axis=vertical reason=system-acceleration\n",
            "MFSCROLL_RING_ROUTE: engine=ring-live action=fallback sequence=5 axis=vertical reason=non-regular\n",
            "MFSCROLL_RING_MODEL: engine=ring-live sequence=1 axis=vertical directionChanged=0 remainingPx=10\n",
            "MFSCROLL_RING_MODEL: engine=ring-live sequence=2 axis=horizontal directionChanged=0 remainingPx=10\n",
            "MFSCROLL_LATENCY: path=ring-live axis=vertical sequence=1 inputToFirstOutputMs=8 inputQueueMs=1\n",
            "MFSCROLL_LATENCY: path=ring-live axis=horizontal sequence=2 inputToFirstOutputMs=9 inputQueueMs=1\n",
            "MFSCROLL_RING_FRAME: engine=ring-live action=stop axis=mixed frameHz=120 maxFrameGapMs=8.4 callbacks=4 events=3 verticalEvents=2 horizontalEvents=3\n",
        ])

        self.assertEqual(
            summary["ringEngine"]["liveModelAxisCounts"],
            {"horizontal": 1, "vertical": 1},
        )
        self.assertEqual(
            summary["ringEngine"]["liveRouteAxisCounts"],
            {"horizontal": 1, "vertical": 1},
        )
        self.assertEqual(
            summary["ringEngine"]["fallbackReasonCounts"],
            {"effect": 1, "non-regular": 1, "system-acceleration": 1},
        )
        self.assertEqual(
            summary["renderer"]["eventAxisCounts"],
            {"horizontal": 3, "vertical": 2},
        )
        self.assertEqual(
            summary["ringEngine"]["axisFirstOutputMs"]["horizontal"]["p50"],
            9.0,
        )
        self.assertTrue(summary["gate"]["hasHorizontalLiveOutput"])
        self.assertTrue(summary["gate"]["hasNoAxisTransitionResets"])
        self.assertTrue(
            summary["gate"]["hasCompatibilityFallbackCoverage"])

    def test_axis_change_reset_is_reported_as_regression(self):
        summary = analyze([
            "MFSCROLL_RING_MODEL: engine=ring-live action=reset generation=2 reason=axis-change\n",
        ])

        self.assertEqual(summary["ringEngine"]["axisTransitionResets"], 1)
        self.assertFalse(summary["gate"]["hasNoAxisTransitionResets"])


if __name__ == "__main__":
    unittest.main()
