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
		local out = g.dedupe({ line(0, 0, 1, 0), line(50, 0, -1, 0), line(0, 1, 1, 0) }, g.vec(60, 0))
		assert(#out == 2, "got " .. #out .. " lines")
		assert(nearV(out[1].a, 50, 0))
	end)

	test("quarter turn onto a crossing line", function()
		local arcs = g.tangentArcs(g.vec(0, 0), g.vec(1, 0), line(100, -50, 0, 1), 8, 3000)
		assert(#arcs == 2, "got " .. #arcs .. " arcs")
		for _, arc in ipairs(arcs) do
			assert(near(arc.r, 100, 1e-6), "radius " .. arc.r)
			assert(near(arc.sweep, math.pi / 2, 1e-9), "sweep " .. arc.sweep)
			assert(nearV(arc.t, 100, 100 * arc.sign, 1e-6), "target " .. arc.t.x .. "," .. arc.t.y)
		end
	end)

	test("half turn onto a parallel line", function()
		local arcs = g.tangentArcs(g.vec(0, 0), g.vec(1, 0), line(-20, 50, 1, 0), 8, 3000)
		assert(#arcs == 1, "got " .. #arcs .. " arcs")
		assert(near(arcs[1].r, 25) and nearV(arcs[1].t, 0, 50, 1e-6))
	end)

	test("no arc onto a line behind the start", function()
		local arcs = g.tangentArcs(g.vec(0, 0), g.vec(1, 0), line(-100, 0, 0, 1), 8, 3000)
		assert(#arcs == 0, "got " .. #arcs .. " arcs")
	end)

	test("oblique merge ends tangent to the line", function()
		-- road crossing 100 m ahead at 60 degrees: a left turn of 60 degrees with
		-- r = 100 * tan(60) merges into it
		local u = g.vec(math.cos(math.rad(60)), math.sin(math.rad(60)))
		local arcs = g.tangentArcs(g.vec(0, 0), g.vec(1, 0), { a = g.vec(100, 0), u = u }, 8, 3000)
		local found = false
		for _, arc in ipairs(arcs) do
			local radial = g.vec(arc.t.x - arc.c.x, arc.t.y - arc.c.y)
			assert(near(radial.x * u.x + radial.y * u.y, 0, 1e-6), "not tangent")
			assert(near(g.dist(arc.c, arc.s), arc.r, 1e-6), "start not on circle")
			if arc.sign == 1 then
				found = near(arc.r, 100 * math.tan(math.rad(60)), 1e-6) and near(arc.sweep, math.rad(60), 1e-9)
			end
		end
		assert(found, "left merge arc missing")
	end)

	test("no single arc onto a diverging line", function()
		local u = g.vec(math.cos(math.rad(30)), math.sin(math.rad(30)))
		assert(#g.tangentArcs(g.vec(0, 0), g.vec(1, 0), { a = g.vec(0, 80), u = u }, 8, 3000) == 0)
	end)

	test("arc polyline runs from start to target", function()
		local arc = g.tangentArcs(g.vec(0, 0), g.vec(1, 0), line(100, -50, 0, 1), 8, 3000)[1]
		local pts = g.arcPoints(arc, 2.0)
		assert(nearV(pts[1], 0, 0, 1e-9))
		assert(nearV(pts[#pts], arc.t.x, arc.t.y, 1e-6))
		for _, p in ipairs(pts) do
			assert(near(g.dist(p, arc.c), arc.r, 1e-6))
		end
	end)

	test("ribbon outlines a segment", function()
		local poly = g.ribbon({ g.vec(0, 0), g.vec(10, 0) }, 2)
		assert(#poly == 4)
		assert(nearV(poly[1], 0, 1) and nearV(poly[2], 10, 1) and nearV(poly[3], 10, -1) and nearV(poly[4], 0, -1))
	end)

	test("turn angle direction", function()
		assert(near(g.turnAngle(g.vec(1, 0), g.vec(0, 1), 1), math.pi / 2))
		assert(near(g.turnAngle(g.vec(1, 0), g.vec(0, 1), -1), 3 * math.pi / 2))
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
		assert(nearV(chain.dirE, 50, 40) and nearV(chain.dirS, 50, 0))
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
		assert(nearV(chain.dirS, 0, 80) and nearV(chain.dirE, 0, 80))
		assert(chain.segments[3] and not chain.segments[1] and not chain.segments[2])
	end)

	return results
end
