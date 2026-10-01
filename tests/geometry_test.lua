-- Tests for the pure 2D geometry of guidelines.script.tl.
-- Run through tools/check.py, which passes a loader for the compiled mod scripts.

return function(load)
	local g = load("guidelines/guidelines.script.tl").geometry
	local results = {}

	local function near(a, b, eps)
		return math.abs(a - b) <= (eps or 1e-6)
	end

	local function nearV(p, x, y, eps)
		return near(p.x, x, eps) and near(p.y, y, eps)
	end

	local function test(name, fn)
		local ok, err = pcall(fn)
		table.insert(results, { name, ok, err and tostring(err) or "" })
	end

	local function line(ax, ay, ux, uy)
		return { a = g.vec(ax, ay), u = g.vec(ux, uy) }
	end

	test("intersect perpendicular lines", function()
		local x = g.intersect(line(0, 0, 1, 0), line(5, -3, 0, 1))
		assert(nearV(x, 5, 0), "got " .. x.x .. "," .. x.y)
	end)

	test("intersect parallel lines is nil", function()
		assert(g.intersect(line(0, 0, 1, 0), line(0, 4, 1, 0)) == nil)
	end)

	test("signed distance is positive on the left", function()
		assert(near(g.signedDistance(line(0, 0, 1, 0), g.vec(3, 2)), 2))
		assert(near(g.signedDistance(line(0, 0, 1, 0), g.vec(3, -2)), -2))
	end)

	test("dedupe keeps the anchor closest to the reference", function()
		local out = g.dedupe({ line(0, 0, 1, 0), line(50, 0, 1, 0), line(0, 1, 1, 0) }, g.vec(60, 0))
		assert(#out == 2, "got " .. #out .. " lines")
		assert(nearV(out[1].a, 50, 0))
	end)

	test("dedupe keeps opposite rays on the same line", function()
		assert(#g.dedupe({ line(0, 0, 1, 0), line(50, 0, -1, 0) }, g.vec(25, 0)) == 2)
	end)

	test("open end: extension and both perpendiculars", function()
		-- road leaves the node westwards, so the extension points east
		local dirs = g.rayDirections(g.vec(1, 0), { g.vec(-1, 0) })
		assert(#dirs == 3 and nearV(dirs[1], 1, 0))
	end)

	test("crossing: no ray along the roads leaving the node", function()
		-- straight crossing: roads leave west, east, north and south
		local leaving = { g.vec(-1, 0), g.vec(1, 0), g.vec(0, 1), g.vec(0, -1) }
		assert(#g.rayDirections(g.vec(1, 0), leaving) == 0)
	end)

	test("T-junction: perpendicular into the branch is dropped", function()
		-- main road leaves west, branch leaves north (slightly curved)
		local u = g.vec(math.cos(math.rad(80)), math.sin(math.rad(80)))
		local dirs = g.rayDirections(g.vec(1, 0), { g.vec(-1, 0), u })
		assert(#dirs == 2 and nearV(dirs[1], 1, 0) and nearV(dirs[2], 0, -1))
	end)

	test("ribbon outlines a segment", function()
		local poly = g.ribbon({ g.vec(0, 0), g.vec(10, 0) }, 2)
		assert(#poly == 4)
		assert(nearV(poly[1], 0, 1) and nearV(poly[2], 10, 1) and nearV(poly[3], 10, -1) and nearV(poly[4], 0, -1))
	end)

	-- segments as read from a proposal: nodes, positions and tangents
	local function seg(n0, x0, y0, n1, x1, y1, t0x, t0y, t1x, t1y)
		return {
			n0 = n0, n1 = n1, p0 = { x = x0, y = y0, z = 0 }, p1 = { x = x1, y = y1, z = 0 },
			t0 = g.vec(t0x, t0y), t1 = g.vec(t1x, t1y),
		}
	end

	test("chain from the dragged end to the drag start", function()
		-- dragging from node 1 (0,0) through a split point -2 to the new node -3
		local segs = {
			seg(-2, 50, 0, -3, 100, 20, 50, 0, 50, 40),
			seg(1, 0, 0, -2, 50, 0, 50, 0, 50, 0),
		}
		local chain = g.findChain(segs, g.vec(99, 21))
		assert(nearV(chain.e, 100, 20) and nearV(chain.s, 0, 0))
		assert(nearV(chain.dirE, 50, 40))
	end)

	test("chain stops where the drag start splits a street", function()
		-- street 10 -> 11 along y = 0 is split at the new node -1, from which the
		-- new segment runs north to -2 (stored reversed, so tangents point south)
		local segs = {
			seg(10, -100, 0, -1, 0, 0, 100, 0, 100, 0),
			seg(-1, 0, 0, 11, 100, 0, 100, 0, 100, 0),
			seg(-2, 0, 80, -1, 0, 0, 0, -80, 0, -80),
		}
		local chain = g.findChain(segs, g.vec(1, 79))
		assert(nearV(chain.e, 0, 80) and nearV(chain.s, 0, 0), "start " .. chain.s.x .. "," .. chain.s.y)
		assert(nearV(chain.dirE, 0, 80) and chain.startNode == -1)
		assert(chain.segments[3] and not chain.segments[1] and not chain.segments[2])
	end)

	test("end splitting an existing street is connected", function()
		-- dragging from node 5 up to -1, which splits the street 10 -> 11
		local segs = {
			seg(5, 0, -80, -1, 0, 0, 0, 80, 0, 80),
			seg(10, -100, 0, -1, 0, 0, 100, 0, 100, 0),
			seg(-1, 0, 0, 11, 100, 0, 100, 0, 100, 0),
		}
		local chain = g.findChain(segs, g.vec(1, 1))
		assert(nearV(chain.e, 0, 0) and chain.connected)
	end)

	test("free end is not connected", function()
		local chain = g.findChain({ seg(5, 0, -80, -1, 0, 0, 0, 80, 0, 80) }, g.vec(1, 1))
		assert(nearV(chain.e, 0, 0) and not chain.connected)
	end)

	test("end on an existing node is connected", function()
		local chain = g.findChain({ seg(-1, 0, -80, 7, 0, 0, 0, 80, 0, 80) }, g.vec(1, 1))
		assert(nearV(chain.e, 0, 0) and chain.connected)
	end)

	return results
end
