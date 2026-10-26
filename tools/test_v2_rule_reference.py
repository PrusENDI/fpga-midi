import unittest
from tools.v2_rule_reference import *


class LiveRuleTests(unittest.TestCase):
    def test_left_edge_then_four_tick_revoice(self):
        f = LiveRuleEngine(min_event_ticks=4)
        self.assertEqual(f.push(LiveFrame(0, tick=0, left_edge=True, bow=True))[0].type, EVENT_NOTE_ON)
        self.assertEqual(f.push(LiveFrame(5000, y=10000, tick=1, bow=True)), [])
        self.assertEqual(f.push(LiveFrame(6000, y=12000, tick=4, bow=True))[0].type, EVENT_NOTE_REVOICE)

    def test_reverse_approach_does_not_arm(self):
        f = LiveRuleEngine()
        self.assertEqual(f.push(LiveFrame(5000, tick=0, left_edge=False, bow=True)), [])
        self.assertEqual(f.push(LiveFrame(1000, tick=1, left_edge=True, bow=True)), [])
        self.assertEqual(f.fault_code, FAULT_REVERSE)

    def test_touch_split_and_pure_z(self):
        f = LiveRuleEngine(gate_source="touch", min_event_ticks=0)
        self.assertEqual(f.push(LiveFrame(0, z=100, tick=0, left_edge=True, touch=True))[0].type, EVENT_NOTE_ON)
        self.assertEqual(f.push(LiveFrame(0, z=200, tick=1, touch=True))[0].type, EVENT_CONTROL)
        self.assertEqual(f.push(LiveFrame(0, z=200, tick=2, touch=False))[0].type, EVENT_NOTE_OFF)

    def test_invalid_rebase_never_creates_note(self):
        f = LiveRuleEngine()
        self.assertEqual(f.push(LiveFrame(0, tick=0, left_edge=True, valid=False, bow=True)), [])
        self.assertFalse(f.active)


class LoopRecorderTests(unittest.TestCase):
    def test_six_tracks_and_monotonic_tick(self):
        r = LoopEventRecorder(depth=2)
        r.start()
        self.assertTrue(r.push(Event(EVENT_NOTE_ON, track=5, tick=3)))
        self.assertTrue(r.push(Event(EVENT_CONTROL, track=0, tick=4)))
        self.assertFalse(r.push(Event(EVENT_NOTE_OFF, track=1, tick=2)))
        self.assertEqual(r.fault_code, FAULT_TICK)

    def test_track_overflow_and_abort(self):
        r = LoopEventRecorder(depth=1)
        r.start()
        self.assertTrue(r.push(Event(EVENT_NOTE_ON, track=2, tick=0)))
        self.assertFalse(r.push(Event(EVENT_NOTE_OFF, track=2, tick=1)))
        self.assertEqual(r.fault_code, FAULT_OVERFLOW)
        r.abort()
        self.assertEqual(r.fault_code, FAULT_ABORT)


if __name__ == "__main__":
    unittest.main()
