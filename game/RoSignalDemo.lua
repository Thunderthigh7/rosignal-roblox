--[[ RoSignalDemo — starter demo UI only.

	It draws a small corner label and an announcement banner so your very
	first RoSignal test is visible when you press Play. None of RoSignal
	needs it: delete this module and call your own game code from
	RoSignalHandlers whenever you are ready. ]]

local Players = game:GetService("Players")

local Demo = {}

local multiplier = 1
local bannerToken = 0

local function valueText()
	return "Multiplier: " .. tostring(multiplier)
end

local function newLabel(name, font)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundColor3 = Color3.fromRGB(15, 17, 21)
	label.BorderSizePixel = 0
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = font
	label.TextScaled = true
	return label
end

--- Build (or find) this player's demo screen. Server-created ScreenGuis live in
--- PlayerGui, which only exists once the player has loaded, so we wait for it.
local function screenFor(player)
	if not player.Parent then
		return nil
	end

	local gui = player:FindFirstChild("PlayerGui") or player:WaitForChild("PlayerGui", 10)
	if not gui then
		return nil
	end

	local existing = gui:FindFirstChild("RoSignalDemo")
	if existing then
		return existing
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "RoSignalDemo"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true

	local value = newLabel("Value", Enum.Font.Gotham)
	value.Size = UDim2.fromScale(0.16, 0.05)
	value.Position = UDim2.fromScale(0.015, 0.3)
	value.BackgroundTransparency = 0.15
	value.Text = valueText()
	value.Parent = screen

	local banner = newLabel("Banner", Enum.Font.GothamBold)
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Size = UDim2.fromScale(0.38, 0.075)
	banner.Position = UDim2.fromScale(0.5, 0.16)
	banner.BackgroundTransparency = 0.1
	banner.TextWrapped = true
	banner.Text = ""
	banner.Visible = false
	banner.Parent = screen

	screen.Parent = gui
	return screen
end

--- Run `fn` against every player's demo screen, building it if needed.
local function forEachScreen(fn)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			local screen = screenFor(player)
			if screen then
				fn(screen)
			end
		end)
	end
end

local function refreshValue()
	forEachScreen(function(screen)
		screen.Value.Text = valueText()
	end)
end

--- Show the current value of a live setting in the corner of the screen.
function Demo.SetMultiplier(value)
	multiplier = value == nil and 1 or value
	refreshValue()
end

--- Pop an announcement up for a few seconds, replacing any previous one.
function Demo.Announce(text)
	bannerToken += 1
	local token = bannerToken

	forEachScreen(function(screen)
		local banner = screen.Banner
		banner.Text = tostring(text)
		banner.Visible = true
	end)

	task.delay(6, function()
		if token ~= bannerToken then
			return
		end
		forEachScreen(function(screen)
			screen.Banner.Visible = false
		end)
	end)
end

-- Players already in the server (Studio Play) and everyone who joins later.
Players.PlayerAdded:Connect(function(player)
	task.spawn(function()
		local screen = screenFor(player)
		if screen then
			screen.Value.Text = valueText()
		end
	end)
end)
refreshValue()

return Demo
