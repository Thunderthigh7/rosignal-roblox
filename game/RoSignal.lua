--[[
	RoSignal runtime (module v3).

	Inserted and refreshed by the RoSignal Studio plugin — do not edit this
	file, your changes are replaced on the next setup or repair. Put your own
	code in ServerScriptService.RoSignalHandlers.

	This public copy uses placeholder game credentials/ids. RoSignal injects the
	real game key, game id and account-specific ingest settings at pairing time.

	Layout:
	  1.  Services, constants and runtime state
	  2.  Developer settings (RoSignalSettings)
	  3.  Live config, overrides and rollouts
	  4.  Config fetching and the Studio poll
	  5.  Announcements and acknowledgements
	  6.  Player traits
	  7.  MessagingService and moderation
	  8.  Event aggregation (MemoryStore)
	  9.  Group ranks
	  10. Public API  -> installPublicApi()
	  11. Startup     -> startRuntime()

	Every public method lives in installPublicApi(); nothing above it is part
	of the supported API.
]]

-- =============================================================================
-- 1. Services, constants and runtime state
-- =============================================================================

local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local GAME_KEY = "<GAME_KEY_INJECTED_AT_PAIRING>"
local CONFIG_URL = "https://rosignal.app/api/public/config/<GAME_ID>"
local AGG_URL = "https://rosignal.app/api/public/agg/<GAME_ID>"
local ACK_URL = "https://rosignal.app/api/public/ack"
local TRAITS_URL = "https://rosignal.app/api/public/traits/<GAME_ID>"
local GROUPS_URL = "https://rosignal.app/api/public/groups/<GAME_ID>"

local IN_STUDIO = RunService:IsStudio()

local RoSignal = {}

-- Defaults shown here. RoSignal injects the account's current ingest settings.
local sampleRate = 0.1
local mapCell = 16

-- Live settings and the handlers listening to them.
local cache = {}
local overrides = {}
-- Events a funnel depends on: never sampled, always sent whole.
local fullEvents = {}
-- Active percentage rollouts: key -> { percent = n, value = v, members = {} }.
local rollouts = {}

local anyChange = {}
local keyChange = {}
local anyMessage = {}
local topicMessage = {}
local announcementHandlers = {}

--- Run every handler in `list` on its own thread so one error cannot stop the rest.
local function fire(list, ...)
	for _, fn in ipairs(list) do
		task.spawn(fn, ...)
	end
end

--- Accepts either a Player instance or a raw user id.
local function userIdOf(player)
	return typeof(player) == "Instance" and player.UserId or player
end

local function clamp(value, low, high, fallback)
	local n = tonumber(value)
	if n == nil or n ~= n then
		return fallback
	end
	return math.max(low, math.min(high, n))
end

-- =============================================================================
-- 2. Developer settings (RoSignalSettings)
-- =============================================================================
-- Map behaviour lives in ServerScriptService.RoSignalSettings: that file is
-- owned by the developer and never overwritten, this one is regenerated.

local mapSettings = { MapByDefault = true, MapEvents = nil, MapExclude = {} }

do
	local module = ServerScriptService:FindFirstChild("RoSignalSettings")
	if module and module:IsA("ModuleScript") then
		local ok, loaded = pcall(require, module)
		if ok and type(loaded) == "table" then
			for key, value in pairs(loaded) do
				mapSettings[key] = value
			end
		end
	end
end

local function listHas(list, name)
	if type(list) ~= "table" then
		return false
	end
	for _, entry in ipairs(list) do
		if entry == name then
			return true
		end
	end
	return false
end

--- Should this event carry a position (and so show up on the map)?
local function wantsMap(name, options)
	if type(options) == "table" and options.map ~= nil then
		return options.map and true or false
	end
	if listHas(mapSettings.MapExclude, name) then
		return false
	end
	if type(mapSettings.MapEvents) == "table" then
		return listHas(mapSettings.MapEvents, name)
	end
	return mapSettings.MapByDefault ~= false
end

-- =============================================================================
-- 3. Live config, overrides and rollouts
-- =============================================================================

--- Merge new values into the cache, firing change handlers for what moved.
local function applyValues(values)
	for key, value in pairs(values) do
		local old = cache[key]
		if old ~= value then
			cache[key] = value
			fire(anyChange, key, value, old)
			if keyChange[key] then
				fire(keyChange[key], value, old)
			end
		end
	end
end

local function applyOverrides(map)
	for userId, values in pairs(map) do
		overrides[tostring(userId)] = values
	end
end

--- Replace the full rollout map.
local function applyRollouts(map)
	rollouts = {}
	for key, entry in pairs(map) do
		if type(entry) == "table" then
			rollouts[key] = {
				percent = tonumber(entry.percent) or 0,
				value = entry.value,
				members = type(entry.members) == "table" and entry.members or nil,
			}
		end
	end
end

--- Deterministic bucket (0-99) for one player on one setting. The same player
--- always lands in the same bucket, so rollout groups stay stable across
--- sessions. Keep in sync with rolloutBucket() in config.server.ts.
local function bucketFor(key, userId)
	local input = key .. ":" .. tostring(userId)
	local h = 0
	for i = 1, #input do
		h = (h * 31 + string.byte(input, i)) % 4294967296
	end
	return h % 100
end

--- True when this player receives the rollout value: either they are inside the
--- percentage bucket, or they are in the segment the rollout targets.
local function inRollout(key, userId)
	local rollout = rollouts[key]
	if rollout == nil then
		return false
	end
	if rollout.members ~= nil then
		return rollout.members[tostring(userId)] == true
	end
	return bucketFor(key, userId) < rollout.percent
end

-- =============================================================================
-- 4. Config fetching and the Studio poll
-- =============================================================================

--- GETs the full config payload. Returns the decoded body, or nil on failure.
local function requestConfig()
	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = CONFIG_URL,
			Method = "GET",
			Headers = {
				["x-rosignal-key"] = GAME_KEY,
				["x-rosignal-place-version"] = tostring(game.PlaceVersion),
			},
		})
	end)
	if not ok or not res or not res.Success then
		return nil
	end

	local decoded = nil
	local parsed = pcall(function()
		decoded = HttpService:JSONDecode(res.Body)
	end)
	if not parsed or type(decoded) ~= "table" then
		return nil
	end
	return decoded
end

local function applyIngestSettings(body)
	if type(body.ingest) ~= "table" then
		return
	end
	sampleRate = clamp(body.ingest.sampleRate, 0, 1, sampleRate)
	mapCell = clamp(body.ingest.mapCell, 1, 512, mapCell)
end

--- First load: replace everything we hold with the server's answer.
local function fetchConfig()
	local body = requestConfig()
	if not body then
		warn("[RoSignal] could not load settings — is Allow HTTP Requests on?")
		return
	end

	cache = body.config or {}
	overrides = body.overrides or {}
	fullEvents = {}
	for _, name in ipairs(body.fullEvents or {}) do
		fullEvents[name] = true
	end
	applyIngestSettings(body)
	applyRollouts(body.rollouts or {})
end

-- =============================================================================
-- 5. Announcements and acknowledgements
-- =============================================================================

local function fireAnnouncements(text)
	for _, fn in ipairs(announcementHandlers) do
		task.spawn(fn, text)
	end
end

local function postAck(payload)
	task.spawn(function()
		pcall(function()
			HttpService:RequestAsync({
				Url = ACK_URL,
				Method = "POST",
				Headers = { ["Content-Type"] = "application/json", ["x-rosignal-key"] = GAME_KEY },
				Body = HttpService:JSONEncode(payload),
			})
		end)
	end)
end

local function ack(runId, actionId)
	postAck({ runId = runId, actionId = actionId, jobId = game.JobId })
end

local function ackAnnouncement(announcementId)
	postAck({ announcementId = announcementId, jobId = game.JobId })
end

local function startStudioPoll()
	local seenAnnouncements = {}

	task.spawn(function()
		local wait = 1
		while true do
			task.wait(wait)

			local ok, body = pcall(requestConfig)
			if not (ok and body) then
				wait = math.min(wait * 2, 30)
				continue
			end

			wait = 1
			applyValues(body.config or {})
			applyOverrides(body.overrides or {})
			if body.rollouts ~= nil then
				applyRollouts(body.rollouts)
			end
			applyIngestSettings(body)

			for _, item in ipairs(body.announcements or {}) do
				if item.id and not seenAnnouncements[item.id] then
					seenAnnouncements[item.id] = true
					fireAnnouncements(tostring(item.text or ""))
					ackAnnouncement(item.id)
				end
			end
		end
	end)
end

-- =============================================================================
-- 6. Player traits
-- =============================================================================

local traitQueue = {}
local traitFlushScheduled = false

local function flushTraits()
	traitFlushScheduled = false

	local batch = {}
	for userId, traits in pairs(traitQueue) do
		table.insert(batch, { playerId = userId, traits = traits })
	end
	traitQueue = {}
	if #batch == 0 then
		return
	end

	task.spawn(function()
		pcall(function()
			HttpService:RequestAsync({
				Url = TRAITS_URL,
				Method = "POST",
				Headers = { ["Content-Type"] = "application/json", ["x-rosignal-key"] = GAME_KEY },
				Body = HttpService:JSONEncode({ players = batch }),
			})
		end)
	end)
end

-- =============================================================================
-- 7. MessagingService and moderation
-- =============================================================================

local function handleModeration(decoded)
	if decoded.action ~= "kick" then
		return
	end

	local userId = tonumber(decoded.userId)
	if not userId then
		return
	end

	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end

	player:Kick(decoded.reason ~= "" and decoded.reason or "You were removed from this server.")

	if decoded.actionId then
		ack(nil, decoded.actionId)
	end
end

local function handleSegmentMessage(target, topic, data)
	local matched = {}
	for _, userId in ipairs(target.userIds or {}) do
		local found = Players:GetPlayerByUserId(tonumber(userId) or 0)
		if found then
			table.insert(matched, found)
		end
	end
	if #matched == 0 then
		return
	end

	if target.runId then
		ack(target.runId)
	end
	for _, found in ipairs(matched) do
		if topic and topicMessage[topic] then
			fire(topicMessage[topic], data, topic, found)
		end
		fire(anyMessage, data, topic, found)
	end
end

local function handleGameMessage(message)
	local raw = message.Data
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	local envelope = (ok and type(decoded) == "table") and decoded or nil

	if envelope and envelope.kind == "config" then
		applyValues(envelope.values or {})
		applyOverrides(envelope.overrides or {})
		if envelope.rollouts ~= nil then
			applyRollouts(envelope.rollouts)
		end
		return
	end

	if envelope and envelope.kind == "moderation" then
		handleModeration(envelope)
		return
	end

	if envelope and envelope.kind == "announcement" then
		fireAnnouncements(tostring(envelope.text or ""))
		return
	end

	local topic, data, target = nil, raw, nil
	if envelope and envelope.kind == "message" then
		topic, data, target = envelope.topic, envelope.data, envelope.target
	end

	if target and target.kind == "segment" then
		handleSegmentMessage(target, topic, data)
		return
	end

	local player = nil
	if target and target.kind and target.kind ~= "all" then
		local userId = tonumber(target.userId)
		player = userId and Players:GetPlayerByUserId(userId) or nil
		if not player then
			return
		end
		if target.runId then
			ack(target.runId)
		end
		if target.kind ~= "player" then
			player = nil
		end
	end

	if topic and topicMessage[topic] then
		fire(topicMessage[topic], data, topic, player)
	end
	fire(anyMessage, data, topic, player)
end

local function handleLegacyConfigMessage(message)
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(message.Data)
	end)
	if not (ok and type(decoded) == "table" and decoded.kind == "config") then
		return
	end
	applyValues(decoded.values or {})
	applyOverrides(decoded.overrides or {})
	if decoded.rollouts ~= nil then
		applyRollouts(decoded.rollouts)
	end
end

local function subscribeToMessages()
	MessagingService:SubscribeAsync("RoSignal", handleGameMessage)
	MessagingService:SubscribeAsync("RoSignal:config", handleLegacyConfigMessage)
end

-- =============================================================================
-- 8. Event aggregation (MemoryStore)
-- =============================================================================

-- Defaults shown here. RoSignal injects the account's current ingest settings.
local FLUSH_SECONDS = 20
local MAX_PROP_KEYS = 5
local SEND_DELAY = 45
local SEP = "\30"

local store = nil
do
	local ok, map = pcall(function()
		return MemoryStoreService:GetHashMap("RoSignalAgg")
	end)
	if ok then
		store = map
	end
end

local pending = {}
local awaitingSend = {}

local function bucketNow()
	return math.floor(os.time() / 60) * 60
end

local function stateFor(bucket)
	local state = pending[bucket]
	if not state then
		state = { counters = {}, players = {}, cells = {}, samples = {} }
		pending[bucket] = state
	end
	return state
end

local function bumpCounter(state, name, key, value, numeric)
	local id = name .. SEP .. key .. SEP .. value
	local row = state.counters[id]
	if not row then
		row = { n = name, k = key, v = value, c = 0 }
		state.counters[id] = row
	end

	row.c += 1
	if numeric ~= nil then
		row.s = (row.s or 0) + numeric
		row.mn = row.mn == nil and numeric or math.min(row.mn, numeric)
		row.mx = row.mx == nil and numeric or math.max(row.mx, numeric)
	end
end

local function mergeCounters(into, from)
	for id, row in pairs(from) do
		local target = into[id]
		if not target then
			into[id] = row
		else
			target.c += row.c
			if row.s then
				target.s = (target.s or 0) + row.s
			end
			if row.mn then
				target.mn = target.mn == nil and row.mn or math.min(target.mn, row.mn)
			end
			if row.mx then
				target.mx = target.mx == nil and row.mx or math.max(target.mx, row.mx)
			end
		end
	end
end

local function mergeCounts(into, from)
	for id, value in pairs(from) do
		into[id] = (into[id] or 0) + value
	end
end

local function mergeState(into, from)
	into.counters = into.counters or {}
	into.players = into.players or {}
	into.cells = into.cells or {}
	mergeCounters(into.counters, from.counters or {})
	mergeCounts(into.players, from.players or {})
	mergeCounts(into.cells, from.cells or {})
	return into
end

local function encode(bucket, state, samples)
	local counters, players, cells = {}, {}, {}
	local iso = DateTime.fromUnixTimestamp(bucket):ToIsoDate()

	for _, row in pairs(state.counters or {}) do
		table.insert(counters, {
			bucket = iso,
			name = row.n,
			prop_key = row.k,
			prop_value = row.v,
			count = row.c,
			sum = row.s,
			min = row.mn,
			max = row.mx,
		})
	end

	for id, count in pairs(state.players or {}) do
		local playerId, name = string.match(id, "^(.-)" .. SEP .. "(.*)$")
		if playerId then
			table.insert(players, { playerId = playerId, name = name, count = count })
		end
	end

	for id, count in pairs(state.cells or {}) do
		local name, gx, gz = string.match(id, "^(.-)" .. SEP .. "(-?%d+)" .. SEP .. "(-?%d+)$")
		if name then
			table.insert(cells, { name = name, gx = tonumber(gx), gz = tonumber(gz), count = count })
		end
	end

	return { counters = counters, players = players, cells = cells, samples = samples or {}, cell = mapCell }
end

local backoffUntil = 0
local backoffStep = 0

local function backOff()
	backoffStep = math.min(backoffStep + 1, 6)
	backoffUntil = os.time() + math.min(300, 15 * (2 ^ (backoffStep - 1)))
end

local function send(payload, ignoreBackoff)
	if not ignoreBackoff and os.time() < backoffUntil then
		return false
	end

	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = AGG_URL,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json", ["x-rosignal-key"] = GAME_KEY },
			Body = HttpService:JSONEncode(payload),
		})
	end)
	if not ok or type(res) ~= "table" then
		backOff()
		return false
	end
	if res.StatusCode == 429 or res.StatusCode >= 500 then
		backOff()
		return false
	end

	backoffStep = 0
	return true
end

local function flushBucket(bucket, state, closing)
	local samples = state.samples
	state.samples = nil

	if closing then
		send(encode(bucket, state, samples), true)
		return
	end

	if store then
		local ok = pcall(function()
			store:UpdateAsync("b" .. bucket, function(old)
				return mergeState(old or { counters = {}, players = {}, cells = {} }, state)
			end, 900)
		end)
		if ok then
			awaitingSend[bucket] = os.time() + SEND_DELAY
			if samples and #samples > 0 then
				send({ counters = {}, players = {}, cells = {}, samples = samples, cell = mapCell })
			end
			return
		end
	end

	send(encode(bucket, state, samples))
end

local function trySend(bucket, closing)
	if not store then
		return true
	end

	local claimed = false
	local ok = pcall(function()
		store:UpdateAsync("s" .. bucket, function(old)
			if old ~= nil then
				return nil
			end
			claimed = true
			return 1
		end, 1800)
	end)
	if not ok then
		return false
	end
	if not claimed then
		return true
	end

	local merged = nil
	pcall(function()
		merged = store:GetAsync("b" .. bucket)
	end)
	if merged then
		if not send(encode(bucket, merged, nil), closing) then
			return false
		end
		pcall(function()
			store:RemoveAsync("b" .. bucket)
		end)
	end
	return true
end

local function tick()
	local current = bucketNow()
	for bucket, state in pairs(pending) do
		if bucket < current then
			pending[bucket] = nil
			flushBucket(bucket, state)
		end
	end

	local now = os.time()
	for bucket, due in pairs(awaitingSend) do
		if now >= due then
			if trySend(bucket) then
				awaitingSend[bucket] = nil
			end
		end
	end
end

local function startFlushLoop()
	task.spawn(function()
		while true do
			task.wait(FLUSH_SECONDS)
			pcall(tick)
		end
	end)
end

local function flushOnClose()
	local deadline = os.clock() + 20

	pcall(function()
		for bucket, state in pairs(pending) do
			pending[bucket] = nil
			flushBucket(bucket, state, true)
			if os.clock() > deadline then
				return
			end
		end
	end)

	pcall(function()
		for bucket in pairs(awaitingSend) do
			awaitingSend[bucket] = nil
			trySend(bucket, true)
			if os.clock() > deadline then
				return
			end
		end
	end)
end

local function trackInternal(name, props, player, options)
	if type(name) ~= "string" or name == "" then
		return
	end

	local bucket = bucketNow()
	local state = stateFor(bucket)
	bumpCounter(state, name, "", "", nil)

	local keys = 0
	if type(props) == "table" then
		for key, value in pairs(props) do
			if keys >= MAX_PROP_KEYS then
				break
			end
			keys += 1
			local numeric = type(value) == "number" and value or nil
			bumpCounter(state, name, tostring(key), string.sub(tostring(value), 1, 120), numeric)
		end
	end

	local userId = nil
	if player then
		userId = tostring(userIdOf(player))
		local playerId = userId .. SEP .. name
		state.players[playerId] = (state.players[playerId] or 0) + 1

		if wantsMap(name, options) then
			local character = typeof(player) == "Instance" and player.Character or nil
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root then
				local gx = math.floor(root.Position.X / mapCell)
				local gz = math.floor(root.Position.Z / mapCell)
				local cellId = name .. SEP .. gx .. SEP .. gz
				state.cells[cellId] = (state.cells[cellId] or 0) + 1
			end
		end
	end

	if (fullEvents[name] or (sampleRate > 0 and math.random() < sampleRate)) and #state.samples < 200 then
		local sample = { name = name, props = props or {} }
		if userId then
			sample.playerId = userId
		end
		table.insert(state.samples, sample)
	end
end

-- =============================================================================
-- 9. Group ranks
-- =============================================================================

local function buildRankBody(userId, role, options)
	local body = { playerId = userId }

	if type(role) == "table" then
		body.roleId = role.roleId and tostring(role.roleId) or nil
		body.roleName = role.roleName
	elseif tonumber(role) ~= nil then
		body.roleId = tostring(role)
	else
		body.roleName = tostring(role)
	end

	if body.roleId == nil and body.roleName == nil then
		return nil, "Pass a role name or roleId."
	end

	body.onlyPromote = options.onlyPromote ~= false
	return body, nil
end

local function requestRankChange(body)
	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = GROUPS_URL,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json", ["x-rosignal-key"] = GAME_KEY },
			Body = HttpService:JSONEncode(body),
		})
	end)
	if not ok then
		return false, "Could not reach RoSignal."
	end

	local decoded = nil
	pcall(function()
		decoded = HttpService:JSONDecode(res.Body)
	end)
	if res.Success and type(decoded) == "table" and decoded.ok then
		return true, nil
	end
	return false, (type(decoded) == "table" and decoded.error) or ("Rank change failed (" .. res.StatusCode .. ").")
end

-- =============================================================================
-- 10. Public API
-- =============================================================================
-- Everything a game is meant to call lives here, and nowhere else.

local function installPublicApi()
	function RoSignal.Get(key, default)
		local value = cache[key]
		if value == nil then
			return default
		end
		return value
	end

	RoSignal.GetConfig = RoSignal.Get

	function RoSignal.GetFor(player, key, default)
		local userId = userIdOf(player)
		local forPlayer = overrides[tostring(userId)]
		if forPlayer ~= nil and forPlayer[key] ~= nil then
			return forPlayer[key]
		end
		if inRollout(key, userId) then
			return rollouts[key].value
		end
		return RoSignal.Get(key, default)
	end

	function RoSignal.HasOverride(player, key)
		local forPlayer = overrides[tostring(userIdOf(player))]
		return forPlayer ~= nil and forPlayer[key] ~= nil
	end

	function RoSignal.InRollout(player, key)
		return inRollout(key, userIdOf(player))
	end

	function RoSignal.SetTraits(player, traits)
		if type(traits) ~= "table" then
			return
		end

		local userId = tostring(userIdOf(player))
		local queued = traitQueue[userId] or {}
		for key, value in pairs(traits) do
			queued[key] = value
		end
		traitQueue[userId] = queued

		if not traitFlushScheduled then
			traitFlushScheduled = true
			task.delay(5, flushTraits)
		end
	end

	function RoSignal.Bind(key, fn)
		keyChange[key] = keyChange[key] or {}
		table.insert(keyChange[key], fn)
		task.spawn(fn, cache[key])
	end

	function RoSignal.OnKeyChange(key, fn)
		keyChange[key] = keyChange[key] or {}
		table.insert(keyChange[key], fn)
	end

	function RoSignal.OnChange(target, maybeFn)
		if type(target) == "table" then
			for key, fn in pairs(target) do
				RoSignal.OnKeyChange(key, fn)
			end
		elseif type(maybeFn) == "function" then
			RoSignal.OnKeyChange(target, maybeFn)
		else
			table.insert(anyChange, target)
		end
	end

	function RoSignal.OnMessage(target, maybeFn)
		if type(target) == "function" then
			table.insert(anyMessage, target)
		else
			topicMessage[target] = topicMessage[target] or {}
			table.insert(topicMessage[target], maybeFn)
		end
	end

	function RoSignal.OnAnnouncement(fn)
		table.insert(announcementHandlers, fn)
	end

	function RoSignal.Track(name, props, player, options)
		pcall(trackInternal, name, props, player, options)
	end

	function RoSignal.SetRank(player, role, options)
		local userId = tostring(userIdOf(player))
		options = type(options) == "table" and options or {}

		local body, invalid = buildRankBody(userId, role, options)
		if not body then
			return false, invalid
		end
		return requestRankChange(body)
	end
end

-- =============================================================================
-- 11. Startup
-- =============================================================================

local function startRuntime()
	installPublicApi()
	fetchConfig()

	if IN_STUDIO then
		startStudioPoll()
	else
		subscribeToMessages()
	end

	startFlushLoop()
	game:BindToClose(flushOnClose)
end

startRuntime()

return RoSignal
