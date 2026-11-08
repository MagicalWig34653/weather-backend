#!/usr/bin/env python3
"""Regenerates Sources/RadarCore/TempScaleData.swift from docs/fixtures/scales/scales-v1.json (run from the repo root).
The server colours ICON-D2 images with this table; TempScaleTests fails if the Swift table and the JSON contract differ."""
import json
d = json.load(open('docs/fixtures/scales/scales-v1.json'))
out = ['// Generated from docs/fixtures/scales/scales-v1.json by tools/gen_temp_scales.py; TempScaleTests compares both. Do not edit by hand.', '',
       'extension TempScale {', '    static let table: [TempScale] = [']
for s in d['scales']:
    out.append(f'        TempScale(id: "{s["id"]}", unit: "{s["unit"]}", min: {s["min"]}, max: {s["max"]}, step: {s["step"]}, labelEvery: {s["label_every"]}, bandColors: [')
    items = ['0x' + b['hex'][1:].upper() for b in s['bands']]
    for i in range(0, len(items), 10): out.append('            ' + ', '.join(items[i:i + 10]) + ',')
    out.append('        ]),')
out += ['    ]', '}']
open('Sources/RadarCore/TempScaleData.swift', 'w').write('\n'.join(out) + '\n')
