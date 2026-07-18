local previous = rawget(_G, "Anodyne")
local nextInstance = require("Anodyne").replace({ hs = hs, previous = previous })
_G.Anodyne = nextInstance
