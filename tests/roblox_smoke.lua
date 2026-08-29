local sources = {}

--[[ PISTONWARE_SOURCES ]]

local warnings = {}

local function expect(condition, message)
	if not condition then
		error(message, 0)
	end
end

local function compile(name)
	local chunk, message = loadstring(sources[name], name)
	expect(chunk ~= nil, name..': '..tostring(message))
	return chunk
end

local function execute(name)
	local ok, result = pcall(compile(name))
	expect(ok, name..' raised while executing: '..tostring(result))
	return result
end

local function warningText()
	local messages = {}
	for index, message in warnings do
		messages[index] = tostring(message)
	end
	return table.concat(messages, ' ')
end

local function expectWarnings(name, expected)
	expect(#warnings == expected, name..' emitted '..tostring(#warnings)..' warning(s): '..warningText())
end

local function makeSignal()
	local records = {}
	local signal = {}
	function signal:Connect(callback)
		local record = {Callback = callback, Connected = true}
		records[#records + 1] = record
		return {
			Disconnect = function()
				record.Connected = false
			end
		}
	end
	function signal:Fire(...)
		for _, record in records do
			if record.Connected then
				record.Callback(...)
			end
		end
	end
	signal.Wait = function() end
	return signal
end

local function makeVector3(x, y, z)
	local value = {X = x or 0, Y = y or 0, Z = z or 0}
	return setmetatable(value, {
		__index = function(self, key)
			if key == 'Magnitude' then
				return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
			elseif key == 'Unit' then
				local magnitude = self.Magnitude
				return magnitude == 0 and makeVector3(0, 0, 0) or makeVector3(self.X / magnitude, self.Y / magnitude, self.Z / magnitude)
			elseif key == 'Dot' then
				return function(_, other)
					return self.X * other.X + self.Y * other.Y + self.Z * other.Z
				end
			end
		end,
		__add = function(left, right)
			return makeVector3(left.X + right.X, left.Y + right.Y, left.Z + right.Z)
		end,
		__sub = function(left, right)
			return makeVector3(left.X - right.X, left.Y - right.Y, left.Z - right.Z)
		end,
		__mul = function(left, right)
			if type(left) == 'number' then
				return makeVector3(left * right.X, left * right.Y, left * right.Z)
			end
			return makeVector3(left.X * right, left.Y * right, left.Z * right)
		end,
		__div = function(left, right)
			return makeVector3(left.X / right, left.Y / right, left.Z / right)
		end
	})
end

local function makeVector2(x, y)
	local value = {X = x or 0, Y = y or 0, x = x or 0, y = y or 0}
	return setmetatable(value, {
		__index = function(self, key)
			if key == 'Magnitude' then
				return math.sqrt(self.X * self.X + self.Y * self.Y)
			end
		end,
		__truediv = function(left, right)
			return makeVector2(left.X / right, left.Y / right)
		end
	})
end

local function resetRoblox()
	warnings = {}
	shared = {}
	warn = function(...)
		local messages = {}
		for _, message in {...} do
			messages[#messages + 1] = tostring(message)
		end
		warnings[#warnings + 1] = table.concat(messages, ' ')
	end

	Vector3 = {new = makeVector3}
	Vector3.zero = makeVector3(0, 0, 0)
	Vector2 = {new = makeVector2}
	Color3 = {
		new = function(r, g, b) return {R = r, G = g, B = b} end,
		fromRGB = function(r, g, b) return {R = r / 255, G = g / 255, B = b / 255} end,
		fromHSV = function(h, s, v) return {H = h, S = s, V = v} end
	}
	UDim = {new = function(scale, offset) return {Scale = scale, Offset = offset} end}
	UDim2 = {new = function(...) return {...} end, fromOffset = function(x, y) return {X = x, Y = y} end}
	CFrame = {new = function(...) return {...} end}
	Rect = {new = function(...) return {...} end}
	Enum = {
		HumanoidRigType = {R6 = 'R6', R15 = 'R15'},
		TeleportState = {Failed = 'Failed'},
		ScaleType = {Slice = 'Slice'}
	}
	RaycastParams = {new = function() return {} end}
	Instance = {new = function(className) return {ClassName = className} end}
	task = {
		wait = function() return 0 end,
		spawn = function(callback, ...) return callback(...) end,
		defer = function(callback, ...) return callback(...) end,
		delay = function(_, callback, ...) return callback(...) end,
		cancel = function() end
	}
	getgenv = function() return _G end

	local players = {
		LocalPlayer = {Team = nil, Character = nil},
		PlayerAdded = makeSignal(),
		PlayerRemoving = makeSignal(),
		GetPlayers = function() return {} end
	}
	local services = {
		Players = players,
		UserInputService = {
			TouchEnabled = false,
			GetMouseLocation = function() return makeVector2(0, 0) end
		},
		RunService = {Heartbeat = makeSignal(), RenderStepped = makeSignal()},
		HttpService = {GenerateGUID = function() return 'test-guid' end},
		ReplicatedStorage = {},
		CoreGui = {},
		TweenService = {},
		TextService = {},
		Teams = {},
		CollectionService = {},
		ContextActionService = {},
		Stats = {
			FindFirstChild = function(_, name)
				if name ~= 'PerformanceStats' then return end
				return {
					FindFirstChild = function(_, statName)
						local value = statName == 'Ping' and 42 or statName == 'Memory' and 768
						return value and {GetValue = function() return value end} or nil
					end
				}
			end,
			GetTotalMemoryUsageMb = function() return 768 end
		}
	}
	game = {
		PlaceId = 6872274481,
		GameId = 6872274481,
		GetService = function(_, name) return services[name] or {} end
	}
	workspace = {
		CurrentCamera = {ViewportSize = makeVector2(1920, 1080)},
		GetPropertyChangedSignal = function() return makeSignal() end,
		FindFirstChildWhichIsA = function() return nil end,
		Raycast = function() return nil end
	}
end

local function expectGuarded(name)
	resetRoblox()
	local result = execute(name)
	expectWarnings(name, 1)
	expect(result == nil, name..' returned from its unauthenticated guard')
end

local function expectSourceContains(name, text)
	expect(sources[name] and sources[name]:find(text, 1, true), name..' is missing expected source: '..text)
end

expectGuarded('main.lua')
expectGuarded('NewMainScript.lua')
expectGuarded('games/6872265039.lua')
expectGuarded('games/6872274481.lua')

expectSourceContains('loader.lua', '/branches/')
expectSourceContains('loader.lua', "release.sourceRef or release.branch")
expectSourceContains('loader.lua', 'PistonwareRestoreDeveloperHook')

expectSourceContains('games/universal.lua', "local SpeedMethodList = {'Velocity'}")
expectSourceContains('games/universal.lua', 'List = SpeedMethodList')
expectSourceContains('games/universal.lua', 'if shared.PistonwareDeveloper == true then')
expectSourceContains('games/universal.lua', "Name = 'Killaura Info'")
expectSourceContains('games/universal.lua', "<b>Developer Diagnostics</b>")
expectSourceContains('games/universal.lua', 'performance:StartDiagnostics()')
expect(not sources['games/universal.lua']:find("Name = 'MotionBlur'", 1, true), 'universal.lua still registers MotionBlur')
expectSourceContains('games/6872274481.lua', 'Max = 23')
expectSourceContains('games/bedwars.lua', 'local developerBuild = shared.PistonwareDeveloper == true')
expectSourceContains('games/bedwars.lua', 'local FLY_SPEED = 22')
expectSourceContains('games/bedwars.lua', "if unsupportedExecutor then")
expectSourceContains('games/bedwars.lua', 'if not developerBuild then return end')
expectSourceContains('games/bedwars.lua', 'predictionSystem.onDamage = function(damageTable)\n            if not developerBuild then return end')
expectSourceContains('games/bedwars.lua', 'if developerBuild then\n        HitNotifications = Killaura:CreateToggle({')
expectSourceContains('games/bedwars.lua', 'RayBudgetLimit = 8')
expectSourceContains('games/bedwars.lua', 'VisibilityCacheHorizon = 0.06')
expectSourceContains('games/bedwars.lua', 'state.ClosestCandidate = closestCandidate')
expect(not sources['games/bedwars.lua']:find("instance:IsA('MeshPart') or instance:IsA('UnionOperation')", 1, true), 'bedwars.lua still attempts RenderFidelity on solid geometry')
expect(not sources['games/6872274481.lua']:find("instance:IsA('MeshPart') or instance:IsA('UnionOperation')", 1, true), '6872274481.lua still attempts RenderFidelity on solid geometry')
expectSourceContains('games/bedwars.lua', "Name = 'TestFly'")
expectSourceContains('games/bedwars.lua', 'math.max(1, Max.Value) * 100000')
expectSourceContains('games/bedwars.lua', "vape.Modules.TestFly and vape.Modules.TestFly.Enabled")
expectSourceContains('games/bedwars.lua', "vape.Modules.InfiniteFly and vape.Modules.InfiniteFly.Enabled")
expect(not sources['games/bedwars.lua']:find('disableOtherFlight', 1, true), 'bedwars.lua still contains the removed flight cleanup helper')
expectSourceContains('games/bedwars.lua', 'genv.KillauraProjectileFollowup = projectileFollowup')
expectSourceContains('games/bedwars.lua', 'local function resetRequest')
expectSourceContains('games/bedwars.lua', 'ItemOwnerToken')
expectSourceContains('games/bedwars.lua', 'req.CommitStarted')
expectSourceContains('games/bedwars.lua', 'local MAX_PROJECTILE_ENTRIES = 32')
expectSourceContains('games/bedwars.lua', 'local MAX_INVENTORY_SLOTS = 128')
expectSourceContains('games/bedwars.lua', 'self.Lifecycle += 1')
expectSourceContains('games/bedwars.lua', 'function projectileFollowup:PrepareKillaura(ent, wallChecked)')
expectSourceContains('games/bedwars.lua', 'function projectileFollowup:CommitKillaura(req, meleeSent)')
expectSourceContains('games/bedwars.lua', 'function projectileFollowup:RequestStandalone(ent)')
expectSourceContains('games/bedwars.lua', 'function projectileFollowup:RequestProjectileAura(ent)')
expectSourceContains('games/bedwars.lua', 'function projectileFollowup:CancelAll()')
expectSourceContains('games/bedwars.lua', 'RequestSlots = {')
expectSourceContains('games/bedwars.lua', 'local projectileFollowup = (function(deps)')
expectSourceContains('games/bedwars.lua', 'genv.KillauraAutoShootConfig = function()')
expectSourceContains('games/bedwars.lua', 'genv.KillauraProjectileAuraConfig = function()')
expectSourceContains('games/bedwars.lua', 'local preparedShot = projectileFollowup:PrepareKillaura(v, Targets.Walls.Enabled)')
expectSourceContains('games/bedwars.lua', 'if not pcall(AttackRemote.FireServer, AttackRemote, attackPayload) then')
expectSourceContains('games/bedwars.lua', 'projectileFollowup:CommitKillaura(preparedShot, true)')
expect(not sources['games/bedwars.lua']:find('KillauraFollowup = true', 1, true), 'bedwars.lua still uses the removed KillauraFollowup wrapper marker')
expectSourceContains('games/bedwars.lua', 'if distance <= swingRange then')
expectSourceContains('main.lua', "failBoot('game.compile', trace)")
expectSourceContains('main.lua', "failBoot('game.execute', result)")
expectSourceContains('main.lua', "failBoot('profile.apply',")
expectSourceContains('guis/newgui.lua', 'function vape:CanSave()')
expectSourceContains('guis/newgui.lua', 'function vape:BlockSaving()')
expectSourceContains('guis/newgui.lua', 'function vape:AllowSaving()')
expectSourceContains('guis/newgui.lua', 'self.PendingProfileCreate = canSave and true or nil')
expectSourceContains('games/6872274481.lua', "bootFailure('bedwars.local.compile'")
expectSourceContains('games/6872274481.lua', 'PistonwareBootFailure = true')
expectSourceContains('games/6872274481.lua', "bootFailure('bedwars.payload.execute'")
expect(not sources['games/6872274481.lua']:find('no usable local games/bedwars.lua -- using the published build', 1, true), '6872274481.lua still falls back after an invalid local payload')
expect(not sources['games/bedwars.lua']:find('sessionOk = true', 1, true), 'bedwars.lua still opens the session without a KEY_VALID verdict')
expectSourceContains('games/bedwars.lua', 'if code ~= OK then')
expect(not sources['main.lua']:find('rawset(shared, "PistonwareAuthenticated", true)', 1, true), 'main.lua still carries an unauthenticated teleport gate')
expectSourceContains('games/8444591321.lua', 'return runChunk')
expectSourceContains('games/8560631822.lua', 'return runChunk')

resetRoblox()
shared.vape = {}
shared.PistonwareDeveloper = true
execute('games/12011959048.lua')
expectWarnings('games/12011959048.lua', 0)
expect(shared.vape.Place == 11630038968, 'bridge-duel wrapper did not initialise its place')

resetRoblox()
local drawing = execute('libraries/drawing.lua')
expectWarnings('libraries/drawing.lua', 0)
expect(drawing == '1', 'drawing.lua did not use its no-communication fallback')

resetRoblox()
local entity = execute('libraries/entity.lua')
expectWarnings('libraries/entity.lua', 0)
expect(type(entity) == 'table' and entity.Running, 'entity.lua did not start with stubbed Roblox services')

local function mockEntity(player, position, target)
	return {
		Player = player,
		Character = {FindFirstChildWhichIsA = function() return nil end},
		Connections = {},
		Health = 100,
		NPC = false,
		Targetable = true,
		Target = target,
		RootPart = {Position = position}
	}
end

local nearPlayer, farPlayer = {}, {}
local near = mockEntity(nearPlayer, Vector3.new(2, 0, 0), false)
local farTarget = mockEntity(farPlayer, Vector3.new(9, 0, 0), true)
entity.List = {near, farTarget}
entity.EntityByPlayer[nearPlayer] = near
entity.EntityByPlayer[farPlayer] = farTarget
entity.EntityByCharacter[near.Character] = near
entity.EntityByCharacter[farTarget.Character] = farTarget
entity.EntityIndex[near] = 1
entity.EntityIndex[farTarget] = 2
entity.isAlive = true
entity.character = {HumanoidRootPart = {Position = Vector3.new(0, 0, 0)}, Connections = {}}

local selected = entity.EntityPosition({
	Players = true,
	Part = 'RootPart',
	Range = 10
})
expect(selected == farTarget, 'entity target priority was not preserved')
local output = {}
local all = entity.AllPosition({
	Players = true,
	Part = 'RootPart',
	Range = 10,
	Limit = 1,
	Output = output
})
expect(all == output and #all == 1 and all[1] == farTarget, 'entity output buffer was not reused')
local cachedOutput = {}
entity.Performance:SetEnabled(true)
near.Targetable = false
local cachedFirst = entity.AllPosition({
	Players = true,
	Part = 'RootPart',
	Range = 10,
	Cache = true,
	Output = cachedOutput
})
expect(#cachedFirst == 1 and cachedFirst[1] == farTarget, 'cached query did not re-filter targetability')
expect(entity.Performance.Stats.TargetCacheRefreshes == 1, 'cached query did not build its watchlist')
near.Targetable = true
local cachedSecond = entity.AllPosition({
	Players = true,
	Part = 'RootPart',
	Range = 10,
	Cache = true,
	Output = cachedOutput
})
expect(table.find(cachedSecond, near) ~= nil, 'cached query did not reuse its watchlist')
expect(entity.Performance.Stats.TargetCacheHits == 1, 'cached query did not record a cache hit')
near.RootPart.Position = Vector3.new(30, 0, 0)
local cachedThird = entity.AllPosition({
	Players = true,
	Part = 'RootPart',
	Range = 10,
	Cache = true,
	Output = cachedOutput
})
expect(table.find(cachedThird, near) == nil, 'cached query returned a stale position result')
expect(entity.Performance.Stats.TargetCacheHits == 2, 'cached query did not re-filter current positions')
near.RootPart.Position = Vector3.new(2, 0, 0)
local runService = game:GetService('RunService')
entity.Performance:StartDiagnostics()
runService.RenderStepped:Fire(0.016)
runService.RenderStepped:Fire(0.2)
runService.RenderStepped:Fire(0.016)
runService.RenderStepped:Fire(0.2)
runService.Heartbeat:Fire(0.2)
runService.Heartbeat:Fire(0.2)
runService.Heartbeat:Fire(0.2)
local diagnosticsSnapshot = entity.Performance:DiagnosticsSnapshot()
expect(diagnosticsSnapshot.Enabled and diagnosticsSnapshot.Render.Samples == 4, 'diagnostics did not sample render frames')
expect(diagnosticsSnapshot.Spikes.Render == 2, 'diagnostics did not count separated render spikes')
expect(diagnosticsSnapshot.Heartbeat.Samples == 3, 'diagnostics did not sample heartbeats')
expect(diagnosticsSnapshot.Ping.Samples == 1 and diagnosticsSnapshot.Ping.Current == 42, 'diagnostics did not sample ping')
expect(diagnosticsSnapshot.Memory == 768, 'diagnostics did not sample memory')
entity.Performance:StopDiagnostics()
expect(not entity.Performance:DiagnosticsSnapshot().Enabled, 'diagnostics did not stop cleanly')
entity.Performance:SetKillauraTelemetry(true)
entity.Performance:RecordKillauraSwing(near, 1)
entity.Performance:RecordKillauraSwing(near, 1.3)
entity.Performance:RecordKillauraHit(near.Character, 1.4)
entity.Performance:RecordKillauraHit(near.Character, 1.7)
local killauraTelemetry = entity.Performance.Killaura
expect(killauraTelemetry.SwingCount == 2 and killauraTelemetry.ConfirmedCount == 2, 'killaura telemetry did not match confirmed swings')
expect(math.abs(killauraTelemetry.AverageHitGap - 0.3) < 0.0001, 'killaura telemetry calculated the wrong hit gap')
expect(math.abs(killauraTelemetry.AverageConfirmationDelay - 0.4) < 0.0001, 'killaura telemetry calculated the wrong confirmation delay')
local killauraSnapshot = entity.Performance:KillauraSnapshot(1.7)
expect(killauraSnapshot.FinalizedCount == 2 and killauraSnapshot.Accuracy == 1 and killauraSnapshot.ProvisionalAccuracy == 1, 'killaura snapshot calculated the wrong accuracy')
entity.Performance:RecordKillauraSwing(near, 2)
local expiredSnapshot = entity.Performance:KillauraSnapshot(4.1)
expect(expiredSnapshot.ExpiredCount == 1 and expiredSnapshot.FinalizedCount == 3 and math.abs(expiredSnapshot.Accuracy - (2 / 3)) < 0.0001, 'killaura snapshot did not finalize expired attempts')
entity.Performance:SetKillauraTelemetry(false)
local found, foundIndex = entity.getEntity(farPlayer)
expect(found == farTarget and foundIndex == 2, 'entity O(1) player lookup failed')
entity.removeEntity(nearPlayer)
expect(#entity.List == 1 and entity.List[1] == farTarget and entity.EntityIndex[farTarget] == 1, 'entity swap-remove failed')
local event = entity.Events.Smoke
local calls = 0
local connection = event:Connect(function() calls += 1 end)
connection:Disconnect()
connection:Disconnect()
event:Fire()
expect(calls == 0, 'entity event disconnect was not idempotent')
event:Destroy()
connection:Disconnect()
entity.stop()
expectWarnings('libraries/entity.lua after stop', 0)

resetRoblox()
local hash = execute('libraries/hash.lua')
expectWarnings('libraries/hash.lua', 0)
expect(hash.sha256('abc') == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'hash.lua SHA-256 smoke test failed')
expectWarnings('libraries/hash.lua after sha256', 0)

resetRoblox()
local prediction = execute('libraries/prediction.lua')
expectWarnings('libraries/prediction.lua', 0)
local roots = prediction.solveQuartic(1, 0, -5, 0, 4)
expect(type(roots) == 'table' and #roots == 4, 'prediction.lua quartic smoke test failed')
local trajectory = prediction.SolveTrajectory(
	Vector3.new(0, 0, 0),
	20,
	9.8,
	Vector3.new(0, 0, 10),
	Vector3.new(0, 0, 0),
	nil,
	0,
	false,
	nil
)
expect(trajectory ~= nil and type(trajectory.X) == 'number', 'prediction.lua trajectory smoke test failed')
expectWarnings('libraries/prediction.lua after trajectory', 0)

resetRoblox()
local vm = execute('libraries/vm.lua')
expectWarnings('libraries/vm.lua', 0)
local settings = vm.luau_newsettings()
expect(settings.vectorCtor == Vector3.new, 'vm settings did not use the Roblox Vector3 constructor')
expect(settings.vectorSize == 4, 'vm settings had the wrong Luau vector width')
vm.luau_validatesettings(settings)
settings.vectorSize = 3
vm.luau_validatesettings(settings)
expectWarnings('libraries/vm.lua after validation', 0)

print('Roblox-shaped Luau load smoke passed')
