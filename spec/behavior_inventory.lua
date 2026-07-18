return {
  {
    id = "A-LIFE-01",
    behavior = "Repeated load, start, and stop leaves exactly one active registration set and no stale resources.",
    source = "init.lua:148-210,1408-1457",
  },
  {
    id = "A-WIN-01",
    behavior = "Outside modal, target focused then remembered then frontmost; modal targeting stays pinned to its entry window.",
    source = "init.lua:304-354,803-825",
  },
  {
    id = "A-FRAME-01",
    behavior = "Requested frames clamp to usable screen bounds and configured minimums, including undersized screens.",
    source = "init.lua:434-452",
  },
  {
    id = "A-TXN-01",
    behavior = "Frame writes record authoritative readback, reject ignored changes, roll back inexact writes, and invalidate on failure.",
    source = "init.lua:458-564",
  },
  {
    id = "A-HIST-01",
    behavior = "History is copied per window, bounded to three, reset on discontinuity, and cleared on destruction.",
    source = "init.lua:414-431,587-642,1415-1422",
  },
  {
    id = "A-SCREEN-01",
    behavior = "Undo and reset require original screen identity and fullFrame while placement continues to use frame.",
    source = "init.lua:376-412,566-585",
  },
  {
    id = "A-KEY-01",
    behavior = "Key precedence, modifiers, arrow and Fn exception, navigation, invalid feedback, and consumption remain stable.",
    source = "init.lua:1047-1274",
  },
  {
    id = "A-UI-01",
    behavior = "Menu order and titles, modal content, status policy, delays, and action feedback remain stable.",
    source = "init.lua:885-1045,1280-1401",
  },
}
