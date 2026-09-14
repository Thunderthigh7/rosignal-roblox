--[[
	RoSignal runtime — behavior-preserving refactor of the generated runtime.

	This file is a readable template for the code RoSignal inserts as
	ServerScriptService.RoSignal. The backend replaces the __ROSIGNAL_*__
	placeholders at pairing time.

	The refactor intentionally keeps the same transport, polling, batching,
	acknowledgement, moderation, rollout, event, and group-rank behavior.
	The main structural change is that every public RoSignal.* method is
	registered together inside installPublicApi().
]]

local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

-- Values injected by the RoSignal backend when the place is paired/repaired.
local GAME_KEY = "__ROSIGNAL_GAME_KEY__"
local CONFIG_URL = "__ROSIGNAL_ORIGIN__/api/public/config/__ROSIGNAL_GAME_ID__"
local AGG_URL = "__ROSIGNAL_ORIGIN__/api/public/agg/__ROSIGNAL_GAME_ID__"
local ACK_URL = "__ROSIGNAL_ORIGIN__/api/public/ack"
local TRAITS_URL = "__ROSIGNAL_ORIGIN__/api/public/traits/__ROSIGNAL_GAME_ID__"
local GROUPS_URL = "__ROSIGNAL_ORIGIN__/api/public/groups/__ROSIGNAL_GAME_ID__"

local GAME_TOPIC = "RoSignal"
local SETTINGS_NAME = "RoSignalSettings"

local FLUSH_SECONDS = __ROSIGNAL_FLUSH_SECONDS__
local MAX_PROP_KEYS = __ROSIGNAL_MAX_PROP_KEYS__
local SEND_DELAY = 45
local SEP = "\30"

local RoSignal = {}

-- Runtime state ---------------------------------------------------------------

local sampleRate = __ROSIGNAL_SAMPLE_RATE__
local mapCell = __ROSIGNAL_MAP_CELL_SIZE__

local cache = {}
local overrides = {}
local fullEvents = {}
local rollouts = {}

local anyChange = {}
local keyChange = {}
local anyMessage = {}
local topicMessage = {}
local announcementHandlers = {}

local traitQueue = {}
local traitFlushScheduled = false

local pending = {}
local awaitingSend = {}
local store = nil
local backoffUntil = 0
local backoffStep = 0

local inStudio = false

-- Developer-owned map settings ------------------------------------------------

local mapSettings = { MapByDefault = true, MapEvents = nil, MapExclude = {} }
do
	local module = ServerScriptService:FindFirstChild(SETTINGS_NAME)
	if module and module:IsA("ModuleScript") then
		local ok, loaded = pcall(require, module)
		if ok and type(loaded) == "table" then
			for key, value in pairs(loaded) do
				mapSettings[key] = value
			end
		end
	end
end

-- Small shared helpers --------------------------------------------------------

local function fire(list, ...)
	for _, fn in ipairs(list) do
		task.spawn(fn, ...)
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

local function clamp(value, low, high, fallback)
	local n = tonumber(value)
	if n == nil or n ~= n then
		return fallback
	end
	return math.max(low, math.min(high, n))
end

-- Live config -----------------------------------------------------------------

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

local function bucketFor(key, userId)
	local input = key .. ":" .. tostring(userId)
	local h = 0
	for i = 1, #input do
		h = (h * 31 + string.byte(input, i)) % 4294967296
	end
	return h % 100
end

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
	if type(body.ingest) == "table" then
		sampleRate = clamp(body.ingest.sampleRate, 0, 1, sampleRate)
		mapCell = clamp(body.ingest.mapCell, 1, 512, mapCell)
	end
end

local function fetchConfig()
	local body = requestConfig()
	if body then
		cache = body.config or {}
		overrides = body.overrides or {}
		fullEvents = {}
		for _, name in ipairs(body.fullEvents or {}) do
			fullEvents[name] = true
		end
		applyIngestSettings(body)
		rollouts = {}
		applyRollouts(body.rollouts or {})
	else
		warn("[RoSignal] could not load settings — is Allow HTTP Requests on?")
	end
end

-- Announcements and acknowledgements -----------------------------------------

local function fireAnnouncements(text)
	for _, fn in ipairs(announcementHandlers) do
		task.spawn(fn, text)
	end
end

local function ack(runId, actionId)
	task.spawn(function()
		pcall(function()
			HttpService:RequestAsync({
				Url = ACK_URL,
				Method = "POST",
				Headers = {
					["Content-Type"] = "application/json",
					["x-rosignal-key"] = GAME_KEY,
				},
				Body = HttpService:JSONEncode({
					runId = runId,
					actionId = actionId,
					jobId = game.JobId,
				}),
			})
		end)
	end)
end

local function ackAnnouncement(announcementId)
	task.spawn(function()
		pcall(function()
			HttpService:RequestAsync({
				Url = ACK_URL,
				Method = "POST",
				Headers = {
					["Content-Type"] = "application/json",
					["x-rosignal-key"] = GAME_KEY,
				},
				Body = HttpService:JSONEncode({
					announcementId = announcementId,
					jobId = game.JobId,
				}),
			})
		end)
	end)
end

local function startStudioPolling()
	local seenAnnouncements = {}
	task.spawn(function()
		local wait = 1
		while true do
			task.wait(wait)
			local ok, body = pcall(requestConfig)
			if ok and body then
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
			else
				wait = math.min(wait * 2, 30)
			end
		end
	end)
end

-- Player traits ---------------------------------------------------------------

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
				Headers = {
					["Content-Type"] = "application/json",
					["x-rosignal-key"] = GAME_KEY,
				},
				Body = HttpService:JSONEncode({ players = batch }),
			})
		end)
	end)
end

-- Live messages and moderation ------------------------------------------------

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

local function handleLiveMessage(message)
	local raw = message.Data
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(raw)
	end)

	if ok and type(decoded) == "table" and decoded.kind == "config" then
		applyValues(decoded.values or {})
		applyOverrides(decoded.overrides or {})
		if decoded.rollouts ~= nil then
			applyRollouts(decoded.rollouts)
		end
		return
	end

	if ok and type(decoded) == "table" and decoded.kind == "moderation" then
		handleModeration(decoded)
		return
	end

	if ok and type(decoded) == "table" and decoded.kind == "announcement" then
		fireAnnouncements(tostring(decoded.text or ""))
		return
	end

	local topic, data, target = nil, raw, nil
	if ok and type(decoded) == "table" and decoded.kind == "message" then
		topic, data, target = decoded.topic, decoded.data, decoded.target
	end

	if target and target.kind == "segment" then
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
	if ok and type(decoded) == "table" and decoded.kind == "config" then
		applyValues(decoded.values or {})
		applyOverrides(decoded.overrides or {})
		if decoded.rollouts ~= nil then
			applyRollouts(decoded.rollouts)
		end
	end
end

local function subscribeLiveMessaging()
	MessagingService:SubscribeAsync(GAME_TOPIC, handleLiveMessage)
	MessagingService:SubscribeAsync(GAME_TOPIC .. ":config", handleLegacyConfigMessage)
end

-- Event aggregation -----------------------------------------------------------

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

	return {
		counters = counters,
		players = players,
		cells = cells,
		samples = samples or {},
		cell = mapCell,
	}
end

local function send(payload, ignoreBackoff)
	if not ignoreBackoff and os.time() < backoffUntil then
		return false
	end

	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = AGG_URL,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
				["x-rosignal-key"] = GAME_KEY,
			},
			Body = HttpService:JSONEncode(payload),
		})
	end)

	if not ok or type(res) ~= "table" then
		backoffStep = math.min(backoffStep + 1, 6)
		backoffUntil = os.time() + math.min(300, 15 * (2 ^ (backoffStep - 1)))
		return false
	end

	if res.StatusCode == 429 or res.StatusCode >= 500 then
		backoffStep = math.min(backoffStep + 1, 6)
		backoffUntil = os.time() + math.min(300, 15 * (2 ^ (backoffStep - 1)))
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
		userId = tostring(typeof(player) == "Instance" and player.UserId or player)
		local id = userId .. SEP .. name
		state.players[id] = (state.players[id] or 0) + 1

		if wantsMap(name, options) then
			local character = typeof(player) == "Instance" and player.Character or nil
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root then
				local gx = math.floor(root.Position.X / mapCell)
				local gz = math.floor(root.Position.Z / mapCell)
				local id2 = name .. SEP .. gx .. SEP .. gz
				state.cells[id2] = (state.cells[id2] or 0) + 1
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

local function startEventAggregation()
	local ok, map = pcall(function()
		return MemoryStoreService:GetHashMap("RoSignalAgg")
	end)
	if ok then
		store = map
	end

	task.spawn(function()
		while true do
			task.wait(FLUSH_SECONDS)
			pcall(tick)
		end
	end)
end

local function bindShutdownFlush()
	game:BindToClose(function()
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
	end)
end

-- Public API ------------------------------------------------------------------
-- Keep every method developers call in one place. Private implementation
-- helpers stay above this section so the API surface is easy to audit.

local function installPublicApi()
	--- Read a setting, falling back to a default.
	function RoSignal.Get(key, default)
		local value = cache[key]
		if value == nil then
			return default
		end
		return value
	end

	--- Deprecated alias for Get.
	RoSignal.GetConfig = RoSignal.Get

	--- Read the value that applies to one player.
	function RoSignal.GetFor(player, key, default)
		local userId = typeof(player) == "Instance" and player.UserId or player
		local forPlayer = overrides[tostring(userId)]
		if forPlayer ~= nil and forPlayer[key] ~= nil then
			return forPlayer[key]
		end
		if inRollout(key, userId) then
			return rollouts[key].value
		end
		return RoSignal.Get(key, default)
	end

	--- True when this player has an explicit override for the key.
	function RoSignal.HasOverride(player, key)
		local userId = typeof(player) == "Instance" and player.UserId or player
		local forPlayer = overrides[tostring(userId)]
		return forPlayer ~= nil and forPlayer[key] ~= nil
	end

	--- True when this player receives the active rollout value.
	function RoSignal.InRollout(player, key)
		local userId = typeof(player) == "Instance" and player.UserId or player
		return inRollout(key, userId)
	end

	--- Describe a player so segments can use the traits.
	function RoSignal.SetTraits(player, traits)
		if type(traits) ~= "table" then
			return
		end
		local userId = tostring(typeof(player) == "Instance" and player.UserId or player)
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

	--- Run now with the current value, then again on every change.
	function RoSignal.Bind(key, fn)
		keyChange[key] = keyChange[key] or {}
		table.insert(keyChange[key], fn)
		task.spawn(fn, cache[key])
	end

	--- Run only when one setting changes.
	function RoSignal.OnKeyChange(key, fn)
		keyChange[key] = keyChange[key] or {}
		table.insert(keyChange[key], fn)
	end

	--- OnChange(fn) for every setting, or OnChange({ Damage = fn, Speed = fn }).
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

	--- OnMessage("StartEvent", fn) for one topic, or OnMessage(fn) for all.
	function RoSignal.OnMessage(target, maybeFn)
		if type(target) == "function" then
			table.insert(anyMessage, target)
		else
			topicMessage[target] = topicMessage[target] or {}
			table.insert(topicMessage[target], maybeFn)
		end
	end

	--- Run when RoSignal sends a topic-less announcement.
	function RoSignal.OnAnnouncement(fn)
		table.insert(announcementHandlers, fn)
	end

	--- Report something that happened.
	function RoSignal.Track(name, props, player, options)
		pcall(trackInternal, name, props, player, options)
	end

	--- Rank a player into a linked group role.
	function RoSignal.SetRank(player, role, options)
		local userId = tostring(typeof(player) == "Instance" and player.UserId or player)
		options = type(options) == "table" and options or {}

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
			return false, "Pass a role name or roleId."
		end
		body.onlyPromote = options.onlyPromote ~= false

		local ok, res = pcall(function()
			return HttpService:RequestAsync({
				Url = GROUPS_URL,
				Method = "POST",
				Headers = {
					["Content-Type"] = "application/json",
					["x-rosignal-key"] = GAME_KEY,
				},
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
		return false,
			(type(decoded) == "table" and decoded.error)
				or ("Rank change failed (" .. res.StatusCode .. ").")
	end
end

-- Startup ---------------------------------------------------------------------

local function startRuntime()
	fetchConfig()
	inStudio = RunService:IsStudio()

	if inStudio then
		startStudioPolling()
	else
		subscribeLiveMessaging()
	end

	startEventAggregation()
	bindShutdownFlush()
end

installPublicApi()
startRuntime()

return RoSignal
