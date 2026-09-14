--[[
	RoSignal Studio plugin — source for the plugin published to the Creator Store.

	What it does:
	  1. Checks it can reach RoSignal (this is what makes Studio show the
	     "allow this plugin to access rosignal.app" prompt, before anything else).
	  2. Asks for the one-time pairing code shown on the RoSignal setup page.
	  3. Swaps that code for a game key and the latest runtime script.
	  4. Inserts ServerScriptService/RoSignal (runtime),
	     ServerScriptService/RoSignalHandlers (the developer's file) and
	     ServerScriptService/RoSignalSettings (yours, never overwritten).
	  5. Exports place geometry so events show up on the RoSignal map.

	Every action is wrapped so a failure can never leave the plugin stuck: the
	buttons always come back, the last pairing response is cached so a failed
	insert can be retried without a new code, and a paired place can reinstall
	its scripts at any time with Repair setup.

	Publish this as a plugin from Roblox Studio (right-click the script ->
	Save as Local Plugin, or Publish as Plugin to the Creator Store).
]]

local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")
local Selection = game:GetService("Selection")

local PLUGIN_VERSION = "1.2.0"
local BASE_URL = "https://rosignal.app"
local PAIR_URL = BASE_URL .. "/api/public/pair"

-- How many parts one export may contain before we stop walking the tree.
local MAX_BOXES = 60000
local SETTING_KEY = "rosignal_link_" .. tostring(game.GameId)
local CACHE_KEY = "rosignal_pending_" .. tostring(game.GameId)

local toolbar = plugin:CreateToolbar("RoSignal")
local button = toolbar:CreateButton("Setup RoSignal", "Connect this place to RoSignal", "rbxassetid://0")
button.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGui(
	"RoSignalSetup",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, true, 340, 460, 300, 360)
)
widget.Title = "Setup RoSignal"

-- UI --------------------------------------------------------------------------

local function label(parent, order, text, size)
	local item = Instance.new("TextLabel")
	item.LayoutOrder = order
	item.Size = UDim2.new(1, 0, 0, size or 30)
	item.BackgroundTransparency = 1
	item.TextXAlignment = Enum.TextXAlignment.Left
	item.TextYAlignment = Enum.TextYAlignment.Top
	item.TextWrapped = true
	item.Font = Enum.Font.GothamMedium
	item.TextSize = 13
	item.TextColor3 = Color3.fromRGB(226, 232, 240)
	item.Text = text
	item.Parent = parent
	return item
end

local function textButton(parent, order, text, primary)
	local item = Instance.new("TextButton")
	item.LayoutOrder = order
	item.Size = UDim2.new(1, 0, 0, primary and 34 or 30)
	item.BackgroundColor3 = primary and Color3.fromRGB(56, 189, 168) or Color3.fromRGB(37, 41, 49)
	item.BorderSizePixel = 0
	item.Font = Enum.Font.GothamMedium
	item.TextSize = primary and 14 or 13
	item.TextColor3 = primary and Color3.fromRGB(8, 12, 14) or Color3.fromRGB(226, 232, 240)
	item.AutoButtonColor = true
	item.Text = text
	item.Parent = parent
	return item
end

local function buildUi()
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(24, 26, 31)
	frame.BorderSizePixel = 0
	frame.Parent = widget

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 16)
	padding.PaddingBottom = UDim.new(0, 16)
	padding.PaddingLeft = UDim.new(0, 16)
	padding.PaddingRight = UDim.new(0, 16)
	padding.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame

	local state = label(frame, 1, "Checking connection...", 20)
	state.Font = Enum.Font.Gotham
	state.TextSize = 12
	state.TextColor3 = Color3.fromRGB(148, 163, 184)

	local title = label(frame, 2, "Paste the pairing code from your RoSignal setup page.", 34)

	local box = Instance.new("TextBox")
	box.LayoutOrder = 3
	box.Size = UDim2.new(1, 0, 0, 34)
	box.BackgroundColor3 = Color3.fromRGB(15, 17, 21)
	box.BorderSizePixel = 0
	box.Font = Enum.Font.RobotoMono
	box.TextSize = 16
	box.TextColor3 = Color3.fromRGB(240, 244, 248)
	box.PlaceholderText = "PAIRING CODE"
	box.Text = ""
	box.ClearTextOnFocus = false
	box.Parent = frame

	local go = textButton(frame, 4, "Setup RoSignal", true)
	local repairButton = textButton(frame, 5, "Repair setup (reinstall scripts)")
	local retryButton = textButton(frame, 6, "Retry connection")

	local divider = Instance.new("Frame")
	divider.LayoutOrder = 7
	divider.Size = UDim2.new(1, 0, 0, 1)
	divider.BackgroundColor3 = Color3.fromRGB(45, 49, 57)
	divider.BorderSizePixel = 0
	divider.Parent = frame

	label(frame, 8, "Send your place to the RoSignal map.", 24)
	local exportSelection = textButton(frame, 9, "Export selection")
	local exportPlace = textButton(frame, 10, "Export whole place")

	local status = label(frame, 11, "", 74)
	status.Font = Enum.Font.Gotham
	status.TextSize = 12
	status.TextColor3 = Color3.fromRGB(148, 163, 184)

	local version = label(frame, 12, "RoSignal plugin v" .. PLUGIN_VERSION, 16)
	version.Font = Enum.Font.Gotham
	version.TextSize = 11
	version.TextColor3 = Color3.fromRGB(100, 116, 139)

	return {
		state = state,
		box = box,
		go = go,
		repairButton = repairButton,
		retryButton = retryButton,
		exportSelection = exportSelection,
		exportPlace = exportPlace,
		status = status,
	}
end

local ui = buildUi()

local function say(text, isError)
	ui.status.Text = text or ""
	ui.status.TextColor3 = isError and Color3.fromRGB(248, 113, 113) or Color3.fromRGB(148, 163, 184)
end

local function readLink()
	local link = plugin:GetSetting(SETTING_KEY)
	if type(link) == "table" and type(link.key) == "string" then
		return link
	end
	return nil
end

local function refreshState(extra)
	local link = readLink()
	local text
	if link then
		text = ("Paired to %s."):format(link.gameName or "this place")
	else
		text = "Not paired yet."
	end
	ui.state.Text = extra and (text .. " " .. extra) or text
	ui.repairButton.Visible = link ~= nil
end

-- Never let a click leave the plugin in a stuck state ---------------------------

local busy = false

--- Runs `action` with every button disabled, and always restores them, even if
--- the action raises. Any unexpected Lua error becomes a readable status line.
local function protect(labelText, target, action)
	if busy then
		say("Still working on the last action — one moment.")
		return
	end
	busy = true
	local originalText = target and target.Text or nil
	if target then
		target.Text = labelText
	end
	ui.go.Active = false
	ui.repairButton.Active = false
	ui.retryButton.Active = false
	ui.exportSelection.Active = false
	ui.exportPlace.Active = false

	local ok, err = pcall(action)

	busy = false
	if target and originalText then
		target.Text = originalText
	end
	ui.go.Active = true
	ui.repairButton.Active = true
	ui.retryButton.Active = true
	ui.exportSelection.Active = true
	ui.exportPlace.Active = true
	refreshState()

	if not ok then
		say("Something went wrong: " .. tostring(err) .. " Nothing was left half-done — press the button again.", true)
	end
end

-- Networking -------------------------------------------------------------------

--- Turns a failed HttpService call into the one instruction that actually fixes it.
local function describeHttpFailure(message)
	message = tostring(message or ""):lower()
	if message:find("not enabled") or message:find("http requests") then
		return "HTTP requests are off. Game Settings -> Security -> Allow HTTP Requests, then press Retry connection."
	end
	if message:find("permission") or message:find("denied") or message:find("not allowed") then
		return "Studio blocked the plugin from reaching rosignal.app. Press Retry connection and choose Allow, or enable it in Plugins -> Manage Plugins -> RoSignal -> Permissions."
	end
	return "Could not reach RoSignal (" .. tostring(message) .. "). Check your internet, then press Retry connection."
end

local function request(options)
	local ok, res = pcall(function()
		return HttpService:RequestAsync(options)
	end)
	if not ok then
		return nil, describeHttpFailure(res)
	end

	local decoded = nil
	pcall(function()
		decoded = HttpService:JSONDecode(res.Body)
	end)
	if not res.Success then
		return nil, (decoded and decoded.error) or ("RoSignal replied with an error (" .. res.StatusCode .. ")."),
			decoded
	end
	if type(decoded) ~= "table" then
		return nil, "RoSignal sent something unexpected. Try again in a moment."
	end
	return decoded, nil
end

--- Cheap GET. Doing this first is what makes Studio's permission prompt appear
--- before a pairing code can be burned.
local function checkConnection(quiet)
	local data, err = request({ Url = PAIR_URL, Method = "GET" })
	if not data then
		refreshState("Connection blocked.")
		say(err, true)
		return false
	end
	if not quiet then
		say("Connected to RoSignal. Enter your pairing code.")
	end
	refreshState()
	return true
end

-- Script insertion --------------------------------------------------------------

--- Write a script into `parent` (ServerScriptService by default). Developer-owned
--- files (keepExisting) are created once and never touched again.
local function writeScript(className, name, source, keepExisting, parent)
	if type(name) ~= "string" or type(source) ~= "string" then
		error("RoSignal sent an incomplete script payload", 0)
	end
	parent = parent or ServerScriptService

	local existing = parent:FindFirstChild(name)
	if existing and existing.ClassName ~= className then
		local removed = pcall(function()
			existing:Destroy()
		end)
		if not removed then
			error(
				("%s.%s already exists and is a %s that cannot be removed. Rename or delete it, then run setup again."):format(
					parent.Name,
					name,
					existing.ClassName
				),
				0
			)
		end
		existing = nil
	end

	if existing then
		if className == "ModuleScript" and not keepExisting then
			local wrote = pcall(function()
				existing.Source = source -- runtime is always refreshed
			end)
			if not wrote then
				error(
					("Could not update %s.%s. It may be locked by another plugin or a team-create session."):format(
						parent.Name,
						name
					),
					0
				)
			end
		end
		return existing, false
	end

	local created
	local ok = pcall(function()
		created = Instance.new(className)
		created.Name = name
		created.Source = source
		created.Parent = parent
	end)
	if not ok or not created then
		if created then
			pcall(function()
				created:Destroy()
			end)
		end
		error(("Could not insert %s.%s. Check you have edit access to this place."):format(parent.Name, name), 0)
	end
	return created, true
end

--- Applies a pairing/repair payload to the place. Safe to run repeatedly.
local function applyPayload(data)
	writeScript("ModuleScript", data.moduleName, data.moduleSource)
	if data.settingsName and data.settingsSource then
		writeScript("ModuleScript", data.settingsName, data.settingsSource, true)
	end
	local handlers, created = writeScript("Script", data.handlersName, data.handlersSource)

	-- Starter demo UI lives inside the handlers script, so their entry point
	-- stays short. It is theirs once written: we never overwrite it.
	if handlers and data.demoName and data.demoSource then
		writeScript("ModuleScript", data.demoName, data.demoSource, true, handlers)
	end

	if data.gameKey and data.mapUrl then
		pcall(function()
			plugin:SetSetting(SETTING_KEY, { key = data.gameKey, mapUrl = data.mapUrl, gameName = data.gameName })
		end)
	end
	-- The payload is applied; drop the retry cache.
	pcall(function()
		plugin:SetSetting(CACHE_KEY, nil)
	end)

	pcall(function()
		Selection:Set({ handlers })
	end)

	say(
		("Connected to %s. Edit ServerScriptService.%s%s Publish the place to go live.")
			:format(data.gameName or "your game", data.handlersName, created and " — it's selected for you." or ".")
	)
end

local function cachedPayload()
	local cached = plugin:GetSetting(CACHE_KEY)
	if type(cached) == "table" and type(cached.moduleSource) == "string" then
		return cached
	end
	return nil
end

local function runSetup()
	protect("Setting up...", ui.go, function()
		-- A previous attempt fetched a payload but failed to insert it: reuse it
		-- instead of asking for another code.
		local pendingPayload = cachedPayload()
		if pendingPayload then
			say("Finishing the setup that was interrupted...")
			applyPayload(pendingPayload)
			ui.box.Text = ""
			return
		end

		local code = tostring(ui.box.Text):gsub("%s", "")
		if #code < 6 then
			say("Enter the pairing code from the RoSignal setup page.", true)
			return
		end

		say("Talking to RoSignal...")
		local data, err = request({
			Url = PAIR_URL,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode({ code = code, universeId = tostring(game.GameId) }),
		})
		if not data then
			say(err, true)
			return
		end

		-- Cache before touching the place, so a failed insert is retryable.
		pcall(function()
			plugin:SetSetting(CACHE_KEY, data)
		end)

		applyPayload(data)
		ui.box.Text = ""
	end)
end

local function runRepair()
	protect("Repairing...", ui.repairButton, function()
		local pendingPayload = cachedPayload()
		if pendingPayload then
			applyPayload(pendingPayload)
			return
		end

		local link = readLink()
		if not link then
			say("This place is not paired yet. Enter a pairing code first.", true)
			return
		end

		say("Fetching the latest scripts...")
		local data, err = request({
			Url = PAIR_URL,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode({ gameKey = link.key }),
		})
		if not data then
			say(err, true)
			return
		end

		pcall(function()
			plugin:SetSetting(CACHE_KEY, data)
		end)
		applyPayload(data)
	end)
end

ui.go.MouseButton1Click:Connect(runSetup)
ui.repairButton.MouseButton1Click:Connect(runRepair)
ui.retryButton.MouseButton1Click:Connect(function()
	protect("Checking...", ui.retryButton, function()
		checkConnection(false)
	end)
end)
ui.box.FocusLost:Connect(function(enterPressed)
	if enterPressed then
		runSetup()
	end
end)

button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
	if widget.Enabled then
		refreshState()
		task.spawn(function()
			protect("Checking...", ui.retryButton, function()
				checkConnection(true)
			end)
		end)
	end
end)

refreshState()
if cachedPayload() then
	say("Your last setup was interrupted. Press Setup RoSignal to finish it — no new code needed.")
end

-- Map export ------------------------------------------------------------------

-- Every rendered part becomes one axis-aligned block: centre, size, colour bucket.
local function collect(roots)
	local boxes = {}
	local truncated = false
	local scanned = 0

	local function visit(instance)
		if #boxes >= MAX_BOXES then
			truncated = true
			return
		end
		scanned += 1
		-- Keep Studio responsive on very large places.
		if scanned % 4000 == 0 then
			task.wait()
		end
		if instance:IsA("BasePart") and instance.Transparency < 1 and not instance:IsA("Terrain") then
			local size = instance.Size
			-- Skip specks — they add bandwidth and never read on the map.
			if size.X * size.Y * size.Z >= 1 then
				local cf = instance.CFrame
				local pos = cf.Position
				-- Axis-aligned extent of the rotated part.
				local sx = math.abs(cf.RightVector.X) * size.X
					+ math.abs(cf.UpVector.X) * size.Y
					+ math.abs(cf.LookVector.X) * size.Z
				local sy = math.abs(cf.RightVector.Y) * size.X
					+ math.abs(cf.UpVector.Y) * size.Y
					+ math.abs(cf.LookVector.Y) * size.Z
				local sz = math.abs(cf.RightVector.Z) * size.X
					+ math.abs(cf.UpVector.Z) * size.Y
					+ math.abs(cf.LookVector.Z) * size.Z
				local colour = instance.Color
				local bucket = math.floor(((colour.R + colour.G + colour.B) / 3) * 7 + 0.5)
				table.insert(boxes, {
					math.floor(pos.X * 100) / 100,
					math.floor(pos.Y * 100) / 100,
					math.floor(pos.Z * 100) / 100,
					math.floor(sx * 100) / 100,
					math.floor(sy * 100) / 100,
					math.floor(sz * 100) / 100,
					bucket,
				})
			end
		end
		for _, child in ipairs(instance:GetChildren()) do
			visit(child)
		end
	end

	for _, root in ipairs(roots) do
		visit(root)
	end
	return boxes, truncated
end

local function exportMap(source, target)
	protect("Exporting...", target, function()
		local link = readLink()
		if not link or not link.key or not link.mapUrl then
			say("Pair this place with RoSignal first, then export.", true)
			return
		end

		local roots
		local name
		if source == "selection" then
			roots = Selection:Get()
			if #roots == 0 then
				say("Select something in the Explorer first, then export.", true)
				return
			end
			name = roots[1].Name
		else
			roots = { workspace }
			name = game.Name
		end

		say("Reading parts...")
		local boxes, truncated = collect(roots)
		if #boxes == 0 then
			say("Nothing to export — that selection has no visible parts.", true)
			return
		end

		say(("Uploading %d blocks..."):format(#boxes))
		local decoded, err = request({
			Url = link.mapUrl,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json", ["x-rosignal-key"] = link.key },
			Body = HttpService:JSONEncode({
				name = name,
				source = source,
				placeVersion = game.PlaceVersion,
				boxes = boxes,
			}),
		})
		if not decoded then
			say(err, true)
			return
		end

		local stored = decoded.stored or #boxes
		local note = ""
		if truncated or decoded.truncated then
			note = " Your plan's block limit trimmed the rest."
		end
		say(("Map updated with %d blocks. Open Analytics -> Map on RoSignal.%s"):format(stored, note))
	end
end

ui.exportSelection.MouseButton1Click:Connect(function()
	exportMap("selection", ui.exportSelection)
end)
ui.exportPlace.MouseButton1Click:Connect(function()
	exportMap("workspace", ui.exportPlace)
end)
