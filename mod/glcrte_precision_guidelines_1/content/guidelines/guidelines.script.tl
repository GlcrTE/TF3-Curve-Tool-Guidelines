-- Curve Tool - Guidelines
-- While a street or track is being dragged, draws guidelines derived from the
-- nearby network: the extension and the perpendicular of open road ends and
-- intersections, and the crossing points of those lines.
--
-- A guideline turns green when the dragged end lies on it.

local MOD_TAG <const> = "[Curve Tool - Guidelines]"
local ZONE_PREFIX <const> = "glcrte_precision_guidelines_"
local RENDERER_PARAM <const> = "glcrte_pg_renderer"

local CONFIG <const> = {
	-- m: only intersections this close to the dragged end give guidelines
	searchRadius = 100.0,
	-- m: the same for open road ends
	openEndRadius = 300.0,
	-- m: guidelines further away from the dragged end are not drawn
	showDistance = 40.0,
	maxLines = 8,
	-- m: the dragged end counts as "on" a guideline within this distance
	hitTolerance = 0.3,
	-- m drawn beyond the dragged end's projection onto a guideline
	lineOverhang = 20.0,
	-- the builder sends no event when a drag is cancelled. While dragging, every
	-- cursor movement creates a new proposal within the same frame (measured:
	-- 3-5 ms), so guidelines are cleared once the cursor has moved more than
	-- cancelMove (m, ignores jitter) without a proposal within cancelDelay (s).
	cancelMove = 0.05,
	cancelDelay = 0.1,
	-- writes builder events, cursor positions and clear decisions to the game log
	debugLog = false,
}

local RENDER_ZONES <const> = 1
local RENDER_POINTS <const> = 2
local RENDER_BOTH <const> = 3
local DEBUG_LAYERS <const> = 1

local type Color = {number, number, number, number}
local COLOR_GUIDE : Color = { 0.35, 0.75, 1.0, 0.55 }
local COLOR_HIT : Color = { 0.25, 1.0, 0.35, 0.85 }

---------------------------------------------------------------------------
-- 2D geometry (pure, no game API)
---------------------------------------------------------------------------

local record V2
	x : number
	y : number
end

-- ray from anchor `a` in unit direction `u`
local record Line
	a : V2
	u : V2
end

local function vec(x : number, y : number) : V2
	return { x = x, y = y }
end

local function add(a : V2, b : V2) : V2
	return vec(a.x + b.x, a.y + b.y)
end

local function sub(a : V2, b : V2) : V2
	return vec(a.x - b.x, a.y - b.y)
end

local function mul(a : V2, k : number) : V2
	return vec(a.x * k, a.y * k)
end

local function dot(a : V2, b : V2) : number
	return a.x * b.x + a.y * b.y
end

local function cross(a : V2, b : V2) : number
	return a.x * b.y - a.y * b.x
end

local function len(a : V2) : number
	return math.sqrt(a.x * a.x + a.y * a.y)
end

local function dist(a : V2, b : V2) : number
	return len(sub(a, b))
end

local function normalize(a : V2) : V2
	local l = len(a)
	if l < 1e-9 then
		return nil
	end
	return vec(a.x / l, a.y / l)
end

-- rotated 90° counter-clockwise
local function perp(a : V2) : V2
	return vec(-a.y, a.x)
end

local function rotate(a : V2, angle : number) : V2
	local c, s = math.cos(angle), math.sin(angle)
	return vec(a.x * c - a.y * s, a.x * s + a.y * c)
end

local function signedDistance(l : Line, p : V2) : number
	return cross(l.u, sub(p, l.a))
end

local function project(l : Line, p : V2) : V2
	return add(l.a, mul(l.u, dot(sub(p, l.a), l.u)))
end

local function intersect(l1 : Line, l2 : Line) : V2
	local den = cross(l1.u, l2.u)
	if math.abs(den) < 1e-4 then
		return nil
	end
	return add(l1.a, mul(l1.u, cross(sub(l2.a, l1.a), l2.u) / den))
end

-- position of the projection of `p` along the ray (negative: behind the anchor)
local function along(l : Line, p : V2) : number
	return dot(sub(p, l.a), l.u)
end

-- rays on the same line pointing the same way
local function sameLine(l1 : Line, l2 : Line) : boolean
	return dot(l1.u, l2.u) > 0 and math.abs(cross(l1.u, l2.u)) < 2e-3
		and math.abs(signedDistance(l1, l2.a)) < 0.05
end

-- removes duplicate lines, keeping the anchor closest to `ref`
local function dedupe(lines : {Line}, ref : V2) : {Line}
	local out : {Line} = {}
	for __, l in ipairs(lines) do
		local merged = false
		for i, o in ipairs(out) do
			if sameLine(l, o) then
				if dist(l.a, ref) < dist(o.a, ref) then
					out[i] = l
				end
				merged = true
				break
			end
		end
		if not merged then
			table.insert(out, l)
		end
	end
	return out
end

-- outline polygon of a polyline with the given width
local function ribbon(points : {V2}, width : number) : {V2}
	local left : {V2} = {}
	local right : {V2} = {}
	local h = width / 2
	for i, p in ipairs(points) do
		local prev = points[math.max(1, i - 1)]
		local nxt = points[math.min(#points, i + 1)]
		local t = normalize(sub(nxt, prev)) or vec(1, 0)
		local n = mul(perp(t), h)
		table.insert(left, add(p, n))
		table.insert(right, sub(p, n))
	end
	for i = #right, 1, -1 do
		table.insert(left, right[i])
	end
	return left
end

---------------------------------------------------------------------------
-- Reading the proposal and the surrounding network
---------------------------------------------------------------------------

local record Seg
	n0 : Engine.Entity
	n1 : Engine.Entity
	p0 : Vec3f
	p1 : Vec3f
	t0 : V2
	t1 : V2
end

-- the dragged chain of new segments: `e` is the end under the cursor, `s` the drag start
local record Chain
	e : V2
	ez : number
	s : V2
	-- travel direction at e (arriving)
	dirE : V2
	-- indices of the chain's segments in the segment list
	segments : {integer : boolean}
	-- the dragged end snapped onto an existing node or street
	connected : boolean
	endNode : Engine.Entity
	startNode : Engine.Entity
end

local function toV2(p : Vec3f) : V2
	return vec(p.x, p.y)
end

local function nodePosition(node : Engine.Entity, added : {Engine.Entity : Vec3f}) : Vec3f
	local p = added[node]
	if p ~= nil then
		return p
	end
	if node == nil or node < 0 then
		return nil
	end
	local comp : Engine.Component.BaseNode = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE)
	if comp ~= nil then
		return comp.position
	end
	return nil
end

local function readSegments(sp : Proposal.StreetProposal) : {Seg}
	local added : {Engine.Entity : Vec3f} = {}
	for __, nae in ipairs(sp.addedNodes or {}) do
		added[nae.entity] = nae.comp.position
	end
	local out : {Seg} = {}
	for __, sae in ipairs(sp.addedSegments or {}) do
		local e = sae.comp
		local p0 = nodePosition(e.node0, added) or e.position0
		local p1 = nodePosition(e.node1, added) or e.position1
		if p0 ~= nil and p1 ~= nil and e.node0 ~= e.node1 then
			table.insert(out, {
				n0 = e.node0, n1 = e.node1, p0 = p0, p1 = p1,
				t0 = vec(e.tangent0.x, e.tangent0.y), t1 = vec(e.tangent1.x, e.tangent1.y),
			})
		end
	end
	return out
end

local function findChain(segs : {Seg}, mouse : V2) : Chain
	local degree : {Engine.Entity : integer} = {}
	local pos : {Engine.Entity : Vec3f} = {}
	for __, sg in ipairs(segs) do
		degree[sg.n0] = (degree[sg.n0] or 0) + 1
		degree[sg.n1] = (degree[sg.n1] or 0) + 1
		pos[sg.n0] = sg.p0
		pos[sg.n1] = sg.p1
	end

	-- the dragged end is the chain end closest to the cursor. A chain end is an
	-- open end, or a junction where the end splits an existing street.
	local endNode : Engine.Entity = segs[#segs].n1
	if mouse ~= nil then
		local best = math.huge
		for node, deg in pairs(degree) do
			local d = dist(toV2(pos[node]), mouse)
			if deg ~= 2 and d < best then
				best, endNode = d, node
			end
		end
	end
	-- new nodes have negative ids, existing ones are entities
	local connected = endNode >= 0 or degree[endNode] >= 3

	local visited : {integer : boolean} = {}
	local current = endNode
	local dirE : V2
	while true do
		local nextSeg : Seg = nil
		local nextIndex = 0
		for i, sg in ipairs(segs) do
			if not visited[i] and (sg.n0 == current or sg.n1 == current) then
				nextSeg, nextIndex = sg, i
				break
			end
		end
		if nextSeg == nil then
			break
		end
		visited[nextIndex] = true
		if dirE == nil then
			dirE = nextSeg.n1 == current and nextSeg.t1 or mul(nextSeg.t0, -1)
		end
		current = nextSeg.n0 == current and nextSeg.n1 or nextSeg.n0
		-- stop at junctions, e.g. where the drag starts in the middle of a street
		-- that the proposal splits into two new segments
		if degree[current] ~= 2 then
			break
		end
	end

	return {
		e = toV2(pos[endNode]),
		ez = pos[endNode].z,
		s = toV2(pos[current]),
		dirE = dirE,
		segments = visited,
		connected = connected,
		endNode = endNode,
		startNode = current,
	}
end

-- extension and perpendicular line at a segment end with tangent `t`
local RAY_CLEARANCE <const> = math.cos(math.rad(20))

-- Guideline directions at a road end: the extension (`outward`, pointing away
-- from the road) and both perpendiculars. Directions running along a road that
-- leaves the same node (`leaving`, unit vectors) are dropped, so no guideline
-- lies on top of an existing street.
local function rayDirections(outward : V2, leaving : {V2}) : {V2}
	local out : {V2} = {}
	for __, u in ipairs({ outward, perp(outward), mul(perp(outward), -1) }) do
		local free = true
		for __, l in ipairs(leaving) do
			if dot(u, l) > RAY_CLEARANCE then
				free = false
			end
		end
		if free then
			table.insert(out, u)
		end
	end
	return out
end

-- number of segments connected to an existing node: 1 = open end, 2 = build
-- point in the middle of a road, 3+ = intersection
local function nodeDegree(node : Engine.Entity, cache : {Engine.Entity : integer}) : integer
	local d = cache[node]
	if d == nil then
		local segments = api.engine.system.streetSystem.getNodeSegments(node)
		d = segments ~= nil and #segments or 0
		cache[node] = d
	end
	return d
end

-- marks `edge` and the road it belongs to, followed through build points in the
-- middle of the road (nodes with two segments) up to intersections and open ends
local function markRoad(edge : Engine.Entity, out : {Engine.Entity : boolean}, degrees : {Engine.Entity : integer})
	local pending : {Engine.Entity} = { edge }
	local count = 0
	while #pending > 0 and count < 500 do
		local current = table.remove(pending)
		if not out[current] then
			out[current] = true
			count = count + 1
			local comp : Engine.Component.BaseEdge = api.engine.getComponent(current, api.type.ComponentType.BASE_EDGE)
			if comp ~= nil then
				for __, node in ipairs({ comp.node0, comp.node1 }) do
					if node >= 0 and nodeDegree(node, degrees) == 2 then
						for __, nextEdge in ipairs(api.engine.system.streetSystem.getNodeSegments(node) or {}) do
							if not out[nextEdge] then
								table.insert(pending, nextEdge)
							end
						end
					end
				end
			end
		end
	end
end

-- The roads attached to the drag start are what is being extended. Returns
-- their segments and their nodes, including the intersections and open ends
-- where they stop.
local function extendedRoads(sp : Proposal.StreetProposal, startNode : Engine.Entity,
	degrees : {Engine.Entity : integer}) : {Engine.Entity : boolean}, {Engine.Entity : boolean}

	local edges : {Engine.Entity : boolean} = {}
	if startNode ~= nil and startNode >= 0 then
		for __, edge in ipairs(api.engine.system.streetSystem.getNodeSegments(startNode) or {}) do
			markRoad(edge, edges, degrees)
		end
	end
	-- a street split by the drag start is replaced by the proposal
	for __, sae in ipairs(sp.removedSegments or {}) do
		markRoad(sae.entity, edges, degrees)
	end
	local nodes : {Engine.Entity : boolean} = {}
	for edge in pairs(edges) do
		local comp : Engine.Component.BaseEdge = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE)
		if comp ~= nil then
			nodes[comp.node0] = true
			nodes[comp.node1] = true
		end
	end
	return edges, nodes
end

-- lines at the ends of an existing segment that are open ends or intersections
-- within the search radius of the dragged end, except at `skipNodes`
-- unit directions in which the segments at `node` leave it
local function leavingDirections(node : Engine.Entity) : {V2}
	local out : {V2} = {}
	for __, edge in ipairs(api.engine.system.streetSystem.getNodeSegments(node) or {}) do
		local comp : Engine.Component.BaseEdge = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE)
		if comp ~= nil then
			local u : V2 = nil
			if comp.node0 == node then
				u = normalize(vec(comp.tangent0.x, comp.tangent0.y))
			elseif comp.node1 == node then
				u = normalize(vec(-comp.tangent1.x, -comp.tangent1.y))
			end
			if u ~= nil then
				table.insert(out, u)
			end
		end
	end
	return out
end

-- guideline rays at the ends of an existing segment that are open ends (within
-- openEndRadius of the dragged end) or intersections (within searchRadius),
-- except at `skipNodes`
local function addEdgeLines(edge : Engine.Entity, out : {Line}, e : V2, degrees : {Engine.Entity : integer},
	skipNodes : {Engine.Entity : boolean})
	local comp : Engine.Component.BaseEdge = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE)
	if comp == nil then
		return
	end
	-- the tangents point from node0 to node1, so away from the road at node1 only
	local ends : {{Engine.Entity, Vec3f, V2}} = {
		{ comp.node0, nodePosition(comp.node0, {}) or comp.position0, vec(-comp.tangent0.x, -comp.tangent0.y) },
		{ comp.node1, nodePosition(comp.node1, {}) or comp.position1, vec(comp.tangent1.x, comp.tangent1.y) },
	}
	for __, en in ipairs(ends) do
		local node, p, outward = en[1], en[2], normalize(en[3])
		if p ~= nil and outward ~= nil then
			local a = toV2(p)
			local degree = nodeDegree(node, degrees)
			local radius = degree == 1 and CONFIG.openEndRadius or CONFIG.searchRadius
			if not skipNodes[node] and degree ~= 2 and dist(a, e) <= radius then
				for __, u in ipairs(rayDirections(outward, leavingDirections(node))) do
					table.insert(out, { a = a, u = u })
				end
			end
		end
	end
end

local function findEdges(center : V2, radius : number) : {Engine.Entity}
	return api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(center.x, center.y), radius,
		api.type.ComponentType.BASE_EDGE) or {}
end

---------------------------------------------------------------------------
-- Building the shapes to draw
---------------------------------------------------------------------------

local record Shape
	-- polyline, or the center of a marker
	points : {V2}
	-- > 0 for circular markers
	radius : number
	width : number
	color : Color
end

local function lineWidth(at : V2, z : number) : number
	local ok, eye = pcall(api.gui.camera.getEye)
	if not ok or eye == nil then
		return 0.5
	end
	local e = eye as Vec3f
	local dx, dy, dz = e.x - at.x, e.y - at.y, e.z - z
	return math.max(0.25, math.min(4.0, math.sqrt(dx * dx + dy * dy + dz * dz) * 0.0025))
end

local record Candidate
	line : Line
	d : number
end

-- A new road can only connect to a node once, so each road end or intersection
-- shows a single guideline: the first one per anchor in `sorted` (closest first).
local function closestPerAnchor(sorted : {Candidate}) : {Candidate}
	local out : {Candidate} = {}
	for __, c in ipairs(sorted) do
		local taken = false
		for __, o in ipairs(out) do
			if dist(o.line.a, c.line.a) < 0.5 then
				taken = true
				break
			end
		end
		if not taken then
			table.insert(out, c)
		end
	end
	return out
end

local function buildShapes(sp : Proposal.StreetProposal, mouse : V2) : {Shape}
	local shapes : {Shape} = {}
	local segs = readSegments(sp)
	if #segs == 0 then
		return shapes
	end
	local chain = findChain(segs, mouse)
	if chain.connected then
		-- the end is already attached to the network: guidelines would only distract
		return shapes
	end
	local E, S = chain.e, chain.s

	-- the road being extended gives no guidelines, not even where it ends
	local lines : {Line} = {}
	local degrees : {Engine.Entity : integer} = {}
	local skipEdges, skipNodes = extendedRoads(sp, chain.startNode, degrees)
	for __, edge in ipairs(findEdges(E, math.max(CONFIG.searchRadius, CONFIG.openEndRadius))) do
		if not skipEdges[edge] then
			addEdgeLines(edge, lines, E, degrees, skipNodes)
		end
	end
	lines = dedupe(lines, E)

	local visible : {Candidate} = {}
	for __, l in ipairs(lines) do
		-- rays from the drag start or the dragged end say nothing, and a ray
		-- only guides ahead of its anchor
		if dist(l.a, E) > 1.0 and dist(l.a, S) > 1.0 and along(l, E) > 0 then
			local d = math.abs(signedDistance(l, E))
			if d < CONFIG.showDistance then
				table.insert(visible, { line = l, d = d })
			end
		end
	end
	table.sort(visible, function(a : Candidate, b : Candidate) : boolean return a.d < b.d end)
	visible = closestPerAnchor(visible)
	while #visible > CONFIG.maxLines do
		table.remove(visible)
	end

	local crossings : {V2} = {}
	for i = 1, #visible do
		for j = i + 1, #visible do
			local li, lj = visible[i].line, visible[j].line
			local x = intersect(li, lj)
			if x ~= nil and along(li, x) > 0 and along(lj, x) > 0 and dist(x, E) < CONFIG.showDistance then
				table.insert(crossings, x)
			end
		end
	end

	local w = lineWidth(E, chain.ez)

	for __, c in ipairs(visible) do
		local l = c.line
		local hit = math.abs(signedDistance(l, E)) < CONFIG.hitTolerance
		local p = project(l, E)
		local out = dot(sub(p, l.a), l.u) >= 0 and l.u or mul(l.u, -1)
		table.insert(shapes, {
			points = { l.a, add(p, mul(out, CONFIG.lineOverhang)) },
			radius = 0,
			width = hit and w * 1.6 or w,
			color = hit and COLOR_HIT or COLOR_GUIDE,
		})
	end

	for __, x in ipairs(crossings) do
		table.insert(shapes, {
			points = { x },
			radius = w * 2.5,
			width = w,
			color = dist(x, E) < 2 * CONFIG.hitTolerance and COLOR_HIT or COLOR_GUIDE,
		})
	end
	return shapes
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local zoneCount = 0

local function zoneKey(i : integer) : string
	return ZONE_PREFIX .. tostring(i)
end

local function color4(c : Color) : Vec4f
	return api.type.Vec4f.new(c[1], c[2], c[3], c[4])
end

-- ground overlays via mission zones; keys are reused so nothing flickers
local function drawZones(shapes : {Shape})
	local n = 0
	for __, sh in ipairs(shapes) do
		n = n + 1
		if sh.radius > 0 then
			local p = sh.points[1]
			api.gui.mission.setZoneCircle(zoneKey(n), api.type.Vec2f.new(p.x, p.y), sh.radius, true,
				color4(sh.color), false, false)
		else
			local polygon : {Vec2f} = {}
			for __, p in ipairs(ribbon(sh.points, sh.width)) do
				table.insert(polygon, api.type.Vec2f.new(p.x, p.y))
			end
			api.gui.mission.setZone(zoneKey(n), polygon, true, color4(sh.color), false, false)
		end
	end
	for i = n + 1, zoneCount do
		api.gui.mission.removeZone(zoneKey(i))
	end
	zoneCount = n
end

local type PointFn = function(Vec3f, Vec3f, integer)
local type ClearFn = function(integer)

-- api.util.debug.draw is bound by the engine but missing from the type definitions
local function debugDraw() : PointFn, ClearFn
	local util = api.util as any as {string : any}
	local dbg = util["debug"] as {string : any}
	local draw = dbg ~= nil and dbg["draw"] as {string : any} or nil
	if draw == nil then
		return nil, nil
	end
	return draw["point"] as PointFn, draw["clear"] as ClearFn
end

local function samplePolyline(points : {V2}, step : number, out : {V2})
	table.insert(out, points[1])
	for i = 2, #points do
		local a, b = points[i - 1], points[i]
		local n = math.max(1, math.ceil(dist(a, b) / step))
		for k = 1, n do
			table.insert(out, add(a, mul(sub(b, a), k / n)))
		end
	end
end

local function drawPoints(shapes : {Shape})
	local point, clear = debugDraw()
	if point == nil then
		return
	end
	clear(DEBUG_LAYERS)
	for __, sh in ipairs(shapes) do
		local samples : {V2} = {}
		local step = math.max(1.0, sh.width * 2)
		if sh.radius > 0 then
			local ring : {V2} = {}
			local c = sh.points[1]
			for k = 0, 16 do
				table.insert(ring, add(c, rotate(vec(sh.radius, 0), 2 * math.pi * k / 16)))
			end
			samplePolyline(ring, step, samples)
		else
			samplePolyline(sh.points, step, samples)
		end
		local color = api.type.Vec3f.new(sh.color[1], sh.color[2], sh.color[3])
		for __, p in ipairs(samples) do
			local z = api.engine.terrain.getHeightAt(api.type.Vec2f.new(p.x, p.y)) + 0.3
			point(api.type.Vec3f.new(p.x, p.y, z), color, DEBUG_LAYERS)
		end
	end
end

local paramCache : {string : integer} = {}

-- mod option value (1-based index). The keys are unique, so they are found
-- regardless of how the params are namespaced.
local function getParam(key : string, default : integer) : integer
	if paramCache[key] == nil then
		paramCache[key] = default
		local ok, params = pcall(api.engine.config.getModParams)
		if ok and params ~= nil then
			for __, modParams in pairs(params as {string : {string : any}}) do
				local v = modParams[key]
				if type(v) == "number" then
					paramCache[key] = math.floor(v as number)
				end
			end
		end
		debugPrint(MOD_TAG .. " option " .. key .. " = " .. tostring(paramCache[key]))
	end
	return paramCache[key]
end

local function getRendererMode() : integer
	return getParam(RENDERER_PARAM, RENDER_ZONES)
end

local shown = false

local function render(shapes : {Shape})
	local mode = getRendererMode()
	if mode == RENDER_ZONES or mode == RENDER_BOTH then
		drawZones(shapes)
	end
	if mode == RENDER_POINTS or mode == RENDER_BOTH then
		drawPoints(shapes)
	end
	shown = #shapes > 0
end

---------------------------------------------------------------------------
-- Builder tracking
---------------------------------------------------------------------------

local lastLogTime = 0.0
local framesSinceLog = 0

local function log(msg : string)
	if CONFIG.debugLog then
		debugPrint(MOD_TAG .. " " .. string.format("%.3f", os.clock()) .. " " .. msg)
	end
end

local function fmtV2(p : V2) : string
	if p == nil then
		return "nil"
	end
	return string.format("(%.1f, %.1f)", p.x, p.y)
end

-- cursor position when the current guidelines were built
local eventMouse : V2 = nil
-- time at which the cursor left eventMouse
local movedAt : number = nil
local errorReported = false

local function terrainMouse() : V2
	if api.gui.mouse.hasTerrainPosition() then
		return toV2(api.gui.mouse.getTerrainPosition())
	end
	return nil
end

local function clear(reason : string)
	if shown then
		log("clear: " .. reason)
		render({})
	end
	eventMouse = nil
	movedAt = nil
end

local function onProposal(sp : Proposal.StreetProposal)
	local mouse = terrainMouse()
	local shapes = buildShapes(sp, mouse)
	log("proposalCreate: segments=" .. tostring(#(sp.addedSegments or {})) .. " mouse=" .. fmtV2(mouse)
		.. " shapes=" .. tostring(#shapes) .. " native=" .. type((sp as any as {string : any})["addedNodes_native"]))
	render(shapes)
	eventMouse = mouse
	movedAt = nil
end

local record State
end

local record GuiState
end

local guidelines = {}

function guidelines.update(_userParams : table, state : GameScriptState<State>, _dt : number) : any
	if not state:hasEventSubscriptions() then
		state:subscribeToEvent("builder.proposalCreate")
		state:subscribeToEvent("builder.proposalApply")
	end
	return nil
end

function guidelines.guiUpdate(_userParams : table, _state : GameScriptStateReadOnly<State>, _guiState : GameScriptState<GuiState>)
	if not shown then
		return
	end
	local mouse = terrainMouse()
	framesSinceLog = framesSinceLog + 1
	if CONFIG.debugLog and os.clock() - lastLogTime > 0.25 then
		log("guiUpdate: frames=" .. tostring(framesSinceLog) .. " mouse=" .. fmtV2(mouse)
			.. " eventMouse=" .. fmtV2(eventMouse))
		lastLogTime = os.clock()
		framesSinceLog = 0
	end
	if eventMouse == nil or mouse == nil or dist(mouse, eventMouse) <= CONFIG.cancelMove then
		movedAt = nil
	elseif movedAt == nil then
		movedAt = os.clock()
	elseif os.clock() - movedAt > CONFIG.cancelDelay then
		clear("cursor moved without a new proposal")
	end
end

function guidelines.guiHandleEvent(_userParams : table, _state : GameScriptStateReadOnly<State>,
	_guiState : GameScriptState<GuiState>, _src : string, _id : string, name : string, param : any) : any

	if name == "builder.proposalCreate" then
		local ok, err : boolean, any = pcall(function()
			local proposal = (param as {Proposal, ProposalData})[1]
			if proposal ~= nil and proposal.proposal ~= nil then
				onProposal(proposal.proposal)
			else
				clear("event without street proposal")
			end
		end)
		if not ok and not errorReported then
			errorReported = true
			debugPrint(MOD_TAG .. " error while building guidelines: " .. tostring(err))
		end
	elseif name == "builder.proposalApply" then
		log("proposalApply")
		pcall(clear, "built")
	end
	-- the result reports build errors (see the base game's company script); report none
	return nil
end

-- exposed for tests
;(guidelines as any as {string : any})["geometry"] = {
	vec = vec, dist = dist, intersect = intersect, dedupe = dedupe,
	signedDistance = signedDistance, ribbon = ribbon, findChain = findChain,
	rayDirections = rayDirections,
}

return guidelines
