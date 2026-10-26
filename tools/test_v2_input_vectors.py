import json
import unittest
from pathlib import Path
from tools.v2_fixed_reference import Profile, process_frame, REASON_GAP

class VectorFileTest(unittest.TestCase):
    def test_v2_input_vectors(self):
        profile = Profile(neutral=(100,-200,300), workspace=((-1000,1000),)*3, epoch=7)
        rows = [json.loads(x) for x in Path('tools/testdata/v2_input/vectors.jsonl').read_text().splitlines()]
        previous = None
        for row in rows:
            result = process_frame(row, profile, previous_sequence=previous)
            if row['name'] in ('invalid','saturation','gap'):
                self.assertFalse(result['frame_valid'], row['name'])
            if row['name'] == 'gap':
                self.assertTrue(result['calibration_reason'] & REASON_GAP)
            previous = row['sequence']

if __name__ == '__main__': unittest.main()
