--[[ RoSignalHandlers — this is your file. Edit it freely.
	It is where your game reacts to RoSignal.

	Three things happen below:
	  1. Bind            run code whenever a live setting changes.
	  2. OnAnnouncement  show messages you send from the site.
	  3. Track           report something that happened, for Analytics.

	RoSignalDemo (inside this script) is only a starter demo UI so your
	first test is visible. Delete it and call your own game code instead.

	Everything RoSignal can do: https://rosignal.app/docs ]]

local RoSignal = require(game.ServerScriptService.RoSignal)
local Demo = require(script.RoSignalDemo)

-- Runs now with the current value, and again every time you change it on the site.
RoSignal.Bind("Multiplier", function(value)
	Demo.SetMultiplier(value)
end)

-- Announcements sent from Messages, rules, or the guided setup.
RoSignal.OnAnnouncement(function(text)
	Demo.Announce(text)
end)

-- Report something that happened, so it shows up in Analytics.
RoSignal.Track("ServerStarted", { placeId = game.PlaceId })
