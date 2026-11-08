# Swift/Python path parity fixtures (GolfDB, 22 swings)

`path_parity_golfdb22.json` is the export_parity.py format: name, phases, landmarks [frames][33][x,y,vis], plus the expected verdict, offset, backswing_offset, loop and jump_frames.

Expected values come from tools/faults/path_fault.py at commit a8c363d (branch claude/tracking-jumps, MIN_FILLED_GAP=3), run on these exact rounded landmarks. Rounding: x,y to 0.01 px and visibility to 0.001. All 22 verdicts and offsets match the full-precision float64 run.

Run it:
    COACHME_PATH_PARITY=<path>/path_parity_golfdb22.json swift test --package-path CoachMeCore --filter SwingPathParityTests

What the 22 swings cover:
- In range: golfdb_0, 24, 82, plus 1, 40 and 56, which have jump frames removed.
- Outside (外下过度): golfdb_113, 255, 669.
- Inside (内下过度): golfdb_267, 663, 772.
- Gap-filled, i.e. refused before a8c363d: golfdb_62, 396, 518, 668. 668 is the boundary case where real-time reads in range while slow-mo 669 reads outside.
- Refused, camera: golfdb_33, 122. Refused, tracking lost or jumping: golfdb_63, 478. Refused, wrists not visible: golfdb_181.
- Boundary: golfdb_724 (-0.513, 11 jump frames; the inside line is -0.516).

Note: with coarser rounding (0.1 px), 724 moved to -0.403 and 396 moved from -0.43 to -0.30, because a 0.1 px change flips which frames despike drops. Parity on these swings is therefore a strict test of the jump guard. A small Swift/Python float difference in the despike step will show up here first.
