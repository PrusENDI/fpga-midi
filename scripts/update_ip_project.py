"""Update Gowin include settings and GAO probes after the IP replacement."""
from pathlib import Path
import json
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
config = root / 'impl/mgc3130_uart_process_config.json'
settings = json.loads(config.read_text(encoding='utf-8-sig'))
settings['IncludePath'] = [(root / 'ip/gowin_i2c_master').as_posix()]
config.write_text(json.dumps(settings, indent=4), encoding='utf-8')

rao = root / 'mgc3130_uart.rao'
tree = ET.fromstring(rao.read_text(encoding='utf-8').replace('version="1"', 'version="1.0"'))
core = tree.find('AoCore')
core.set('storage_depth', '8192')
core.set('capture_amount', '8192')
signals = core.find('SignalList')
signals.clear()
for name in ['ts_in', 'sda_in', 'scl_in', 'ts_oe', 'report_valid',
             'report_error', 'ip_wr_en', 'ip_rd_en']:
    ET.SubElement(signals, 'Signal', capture_enable='true').text = 'u_reader/' + name
for name, width in [('state', 6), ('ip_status', 8), ('rx_byte', 8),
                    ('frame_length', 8), ('ip_wr_data', 8), ('last_message_id', 8)]:
    bus = ET.SubElement(signals, 'Bus', capture_enable='true',
                        name=f'u_reader/{name}[{width-1}:0]')
    for bit in reversed(range(width)):
        ET.SubElement(bus, 'Signal').text = f'u_reader/{name}[{bit}]'
core.find('MatchUnits/MatchUnit').set('value0', '000101') # ST_ADDRESS
ET.indent(tree, space='    ')
rao.write_text('<?xml version="1.0" encoding="UTF-8"?>\n' +
               ET.tostring(tree, encoding='unicode') + '\n', encoding='utf-8')
print('Include path and GAO probes updated.')
