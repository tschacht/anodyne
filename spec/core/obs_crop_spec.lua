local ObsCrop = require("Anodyne.core.obs_crop")

describe("core OBS crop", function()
  it("calculates asymmetric integer crops at scale one", function()
    assert.same({
      ok = true,
      left = 150,
      top = 75,
      right = 350,
      bottom = 225,
      sourceWidth = 1500,
      sourceHeight = 900,
      resultWidth = 1000,
      resultHeight = 600,
      scale = 1,
    }, ObsCrop.calculate({ x = -200, y = 40, w = 1500, h = 900 }, { x = -50, y = 115, w = 1000, h = 600 }, 1))
  end)

  it("converts point geometry at scale two", function()
    local result = ObsCrop.calculate({ x = 10, y = 20, w = 800, h = 500 }, { x = 110, y = 70, w = 600, h = 400 }, 2)
    assert.same({ 200, 100, 200, 100 }, { result.left, result.top, result.right, result.bottom })
    assert.same({ 1600, 1000, 1200, 800 }, { result.sourceWidth, result.sourceHeight, result.resultWidth, result.resultHeight })
  end)

  it("calculates a frozen normal-origin screen source near its edges", function()
    local screenFullFrame = { x = 0, y = 0, w = 1728, h = 1117 }
    local guideRect = { x = 7, y = 0, w = 1721, h = 1104 }
    local result = ObsCrop.calculate(screenFullFrame, guideRect, 1)
    assert.same({ 7, 0, 0, 13 }, { result.left, result.top, result.right, result.bottom })
    assert.same({ 1728, 1117, 1721, 1104 }, { result.sourceWidth, result.sourceHeight, result.resultWidth, result.resultHeight })
  end)

  it("derives frozen negative-origin screen far edges from rounded dimensions", function()
    local screenFullFrame = { x = -1512.25, y = -100.25, w = 1512.5, h = 982.5 }
    local guideRect = { x = -1512.25, y = -87.75, w = 1500.25, h = 970 }
    local result = ObsCrop.calculate(screenFullFrame, guideRect, 2)
    assert.same({ 0, 25, 24, 0 }, { result.left, result.top, result.right, result.bottom })
    assert.same({ 3025, 1965, 3001, 1940 }, { result.sourceWidth, result.sourceHeight, result.resultWidth, result.resultHeight })
    assert.are.equal(result.resultWidth, result.sourceWidth - result.left - result.right)
    assert.are.equal(result.resultHeight, result.sourceHeight - result.top - result.bottom)
  end)

  it("rounds the source, relative origin, and guide size as pixel rectangles", function()
    local finalRect = { x = -20.2, y = 9.1, w = 500.49, h = 300.51 }
    local guideRect = { x = 30.05, y = 59.35, w = 300.49, h = 100.51 }
    local result = ObsCrop.calculate(finalRect, guideRect, 1)
    assert.same({ 50, 50, 150, 150 }, { result.left, result.top, result.right, result.bottom })
    assert.same({ 500, 301, 300, 101 }, { result.sourceWidth, result.sourceHeight, result.resultWidth, result.resultHeight })
    assert.are.equal(math.floor((guideRect.x - finalRect.x) + 0.5), result.left)
    assert.are.equal(math.floor((guideRect.y - finalRect.y) + 0.5), result.top)
  end)

  it("preserves rounded result dimensions when rounding is asymmetric", function()
    local result = ObsCrop.calculate({ x = 0.1, y = 0.2, w = 100.6, h = 80.6 }, { x = 20.7, y = 10.8, w = 60.6, h = 50.6 }, 1)
    assert.are.equal(result.resultWidth, result.sourceWidth - result.left - result.right)
    assert.are.equal(result.resultHeight, result.sourceHeight - result.top - result.bottom)
    assert.same({ 21, 11, 19, 19, 61, 51 }, { result.left, result.top, result.right, result.bottom, result.resultWidth, result.resultHeight })
  end)

  it("returns zero crops when the guide and final rectangle match", function()
    local result = ObsCrop.calculate({ x = -1.25, y = 2.75, w = 640.25, h = 480.25 }, { x = -1.25, y = 2.75, w = 640.25, h = 480.25 }, 2)
    assert.same({ 0, 0, 0, 0 }, { result.left, result.top, result.right, result.bottom })
  end)

  it("clamps tiny point containment residue while preserving guide dimensions", function()
    local tolerance = ObsCrop.POINT_TOLERANCE
    local left = ObsCrop.calculate({ x = 10, y = 20, w = 300, h = 200 }, { x = 10 - tolerance / 2, y = 40, w = 200, h = 100 }, 2)
    local bottom = ObsCrop.calculate({ x = 10, y = 20, w = 300, h = 200 }, { x = 40, y = 120 + tolerance / 2, w = 200, h = 100 }, 2)
    assert.same({ 0, 400 }, { left.left, left.resultWidth })
    assert.same({ 0, 200 }, { bottom.bottom, bottom.resultHeight })
  end)

  it("reconciles opposing tolerance edges when their rounded pixel dimensions fit", function()
    local tolerance = ObsCrop.POINT_TOLERANCE
    local result = ObsCrop.calculate(
      { x = 0, y = 0, w = 100, h = 100 },
      { x = -tolerance / 2, y = -tolerance / 2, w = 100 + tolerance, h = 100 + tolerance },
      1
    )
    assert.same({ 0, 0, 0, 0 }, { result.left, result.top, result.right, result.bottom })
    assert.same({ result.sourceWidth, result.sourceHeight }, { result.resultWidth, result.resultHeight })
  end)

  it("rejects opposing tolerance edges when the rounded guide is larger than the source", function()
    local tolerance = ObsCrop.POINT_TOLERANCE
    local horizontal = ObsCrop.calculate({ x = 0, y = 0, w = 100, h = 100 }, { x = -tolerance / 2, y = 0, w = 100 + tolerance, h = 100 }, 100)
    local vertical = ObsCrop.calculate({ x = 0, y = 0, w = 100, h = 100 }, { x = 0, y = -tolerance / 2, w = 100, h = 100 + tolerance }, 100)
    assert.same({ ok = false, error = { code = "outside_final", edge = "right" } }, horizontal)
    assert.same({ ok = false, error = { code = "outside_final", edge = "bottom" } }, vertical)
  end)

  it("rejects asymmetric rounding that would require shifting the rounded origin", function()
    local horizontal = ObsCrop.calculate({ x = 0, y = 0, w = 100.2, h = 80 }, { x = 49.6, y = 10, w = 50.6, h = 60 }, 1)
    local vertical = ObsCrop.calculate({ x = 0, y = 0, w = 100, h = 100.2 }, { x = 10, y = 49.6, w = 80, h = 50.6 }, 1)
    assert.same({ ok = false, error = { code = "outside_final", edge = "right" } }, horizontal)
    assert.same({ ok = false, error = { code = "outside_final", edge = "bottom" } }, vertical)
  end)

  it("validates rectangle shape, finite coordinates, and positive dimensions", function()
    local cases = {
      { value = nil, field = nil },
      { value = { x = 0, y = 0, w = 1 }, field = "h" },
      { value = { x = 0 / 0, y = 0, w = 1, h = 1 }, field = "x" },
      { value = { x = 0, y = math.huge, w = 1, h = 1 }, field = "y" },
      { value = { x = 0, y = 0, w = 0, h = 1 }, field = "w" },
      { value = { x = 0, y = 0, w = 1, h = -1 }, field = "h" },
    }
    for _, case in ipairs(cases) do
      local result = ObsCrop.validateRect(case.value, "guide")
      assert.is_false(result.ok)
      assert.are.equal("invalid_rect", result.error.code)
      assert.are.equal("guide", result.error.rect)
      assert.are.equal(case.field, result.error.field)
    end
  end)

  it("identifies which input rectangle is invalid during calculation", function()
    local finalResult = ObsCrop.calculate({ x = 0, y = 0, w = 0, h = 10 }, { x = 0, y = 0, w = 1, h = 1 }, 1)
    local guideResult = ObsCrop.calculate({ x = 0, y = 0, w = 10, h = 10 }, { x = 0, y = 0, w = 1 / 0, h = 1 }, 1)
    assert.same({ "invalid_rect", "final", "w" }, { finalResult.error.code, finalResult.error.rect, finalResult.error.field })
    assert.same({ "invalid_rect", "guide", "w" }, { guideResult.error.code, guideResult.error.rect, guideResult.error.field })
  end)

  it("rejects non-finite, non-numeric, and non-positive scales", function()
    for _, scale in ipairs({ 0, -1, math.huge, -math.huge, "2" }) do
      assert.same({ ok = false, error = { code = "invalid_scale" } }, ObsCrop.validateScale(scale))
    end
    assert.same({ ok = false, error = { code = "invalid_scale" } }, ObsCrop.validateScale(0 / 0))
  end)

  it("converts a valid point rectangle to integer pixels", function()
    assert.same({ ok = true, rect = { x = -20, y = 21, w = 201, h = 101 } }, ObsCrop.toPixelRect({ x = -10.2, y = 10.4, w = 100.3, h = 50.4 }, 2))
  end)

  it("rejects invalid point rectangles and scales during pixel conversion", function()
    assert.same({ ok = false, error = { code = "invalid_rect", rect = "rect", field = "w" } }, ObsCrop.toPixelRect({ x = 0, y = 0, w = 0, h = 1 }, 1))
    assert.same({ ok = false, error = { code = "invalid_scale" } }, ObsCrop.toPixelRect({ x = 0, y = 0, w = 1, h = 1 }, 0))
  end)

  it("reports every guide edge outside the final rectangle beyond tolerance", function()
    local tolerance = ObsCrop.POINT_TOLERANCE
    local finalRect = { x = 10, y = 20, w = 100, h = 80 }
    local cases = {
      { edge = "left", guide = { x = 10 - tolerance * 2, y = 30, w = 50, h = 40 } },
      { edge = "top", guide = { x = 20, y = 20 - tolerance * 2, w = 50, h = 40 } },
      { edge = "right", guide = { x = 60 + tolerance * 2, y = 30, w = 50, h = 40 } },
      { edge = "bottom", guide = { x = 20, y = 60 + tolerance * 2, w = 50, h = 40 } },
    }
    for _, case in ipairs(cases) do
      local result = ObsCrop.calculate(finalRect, case.guide, 1)
      assert.is_false(result.ok)
      assert.same({ code = "outside_final", edge = case.edge }, result.error)
    end
  end)

  it("has no native, window-object, formatting, or UI dependency", function()
    local source = assert(io.open("Anodyne/core/obs_crop.lua")):read("*a")
    for _, forbidden in ipairs({ "require%s*%(", "_G", "hs%.", "pasteboard", "canvas", "string%.format" }) do
      assert.is_nil(source:match(forbidden), forbidden)
    end
  end)
end)
