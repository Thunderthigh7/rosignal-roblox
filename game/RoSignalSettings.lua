--[[ RoSignal settings — this file is yours. The plugin never overwrites it.

	MapByDefault  when true, events that include a player also send that
	              player's position, so they appear on the Analytics map.
	MapEvents     optional allow-list. When set, ONLY these events send a
	              position, whatever MapByDefault says.
	MapExclude    events that never send a position.

	You can also decide per call: RoSignal.Track(name, props, player, { map = false })
]]

return {
	MapByDefault = true,
	MapEvents = nil,
	MapExclude = {},
}
