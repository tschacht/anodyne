local previous = { anodyne = rawget(_G, "Anodyne"), legacy = rawget(_G, "WindowManager") }
local nextInstance = require("Anodyne").replace({ hs = hs, previous = previous })
_G.Anodyne, _G.WindowManager = nextInstance, nextInstance
