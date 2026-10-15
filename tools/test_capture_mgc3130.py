import unittest
from capture_mgc3130 import parse_report_line, pack_replay_word

class CaptureParserTests(unittest.TestCase):
    def test_valid_report_is_parsed_and_packed(self):
        line = ('TS=0 M=1 S=1 C=1 V=31 E=00 K=0 X=A4E3 Y=CBDC '
                'Z=1161 G=00 P=1 D=00000000 F=0117 L=18')
        report = parse_report_line(line)
        self.assertIsNotNone(report)
        self.assertEqual((report['x'], report['y'], report['z']),
                         (0xA4E3, 0xCBDC, 0x1161))
        self.assertEqual(pack_replay_word(report), 'A4E3CBDC11610001')

    def test_invalid_status_is_rejected(self):
        line = ('TS=1 M=1 S=1 C=1 V=92 E=00 K=0 X=FFFF Y=A446 '
                'Z=FFFF G=00 P=0 D=00000000 F=0117 L=18')
        self.assertIsNone(parse_report_line(line))

    def test_malformed_line_is_rejected(self):
        self.assertIsNone(parse_report_line('hello'))

if __name__ == '__main__':
    unittest.main()
