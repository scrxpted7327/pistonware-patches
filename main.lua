if not shared.PistonwareAuthenticated then
	warn('[pistonware] not authenticated -- run the pistonware loader and enter your key')
	return
end

-- pcall'd: after a teleport shared.vape can still point at the previous server's instance,
-- whose GUI and connections no longer exist. An error walking that corpse would abort main.lua
-- on line one and leave the queued re-injection doing nothing at all.
if shared.vape then pcall(function() shared.vape:Uninject() end) end

local vape
local loadstring = function(...)
	local res, err = loadstring(...)
	if err and vape then
		vape:CreateNotification('Pistonware', 'Failed to load : '..err, 30, 'alert')
	end
	return res
end
local queue_on_teleport = queue_on_teleport or syn and syn.queue_on_teleport
local hasQueueOnTeleport = queue_on_teleport ~= nil
queue_on_teleport = queue_on_teleport or function() end
local isfile = isfile or function(file)
	local suc, res = pcall(function()
		return readfile(file)
	end)
	return suc and res ~= nil and res ~= ''
end
local cloneref = cloneref or function(obj)
	return obj
end
local playersService = cloneref(game:GetService('Players'))

-- isfile is not the question. A zero-byte file reads back as PRESENT through every executor's
-- real isfile, and only the fallback above treats empty as absent -- so on executors that ship
-- one (most of them), an interrupted write leaves a truncated file that nothing ever repairs.
--
-- That is not hypothetical: cancelling, crashing or teleporting during the concurrent asset
-- prefetch below leaves a half-written PNG. From then on prefetchFolder skips it, downloadFile
-- skips it, getcustomasset hands the corrupt file to the client, and the resulting invalid
-- content id throws 'ContentId formatting failed' at the assignment -- taking the whole GUI
-- chunk with it. Every route that could have fixed it asked isfile and was told the file was
-- fine, which is why the only known remedy was reinstalling the entire script.
--
-- Treating empty as missing makes it repair itself on the next run instead.
local function hasContent(path)
	if not isfile(path) then return false end
	local ok, body = pcall(readfile, path)
	return ok and type(body) == 'string' and body ~= ''
end

local function downloadFile(path, func)
	if not hasContent(path) then
		-- bedwars.lua only exists in the GitLab repo (kept separate/obfuscated there), at that
		-- repo's ROOT even though it caches locally under games/; everything else lives in the
		-- GitHub repo.
		local relPath = select(1, path:gsub('pistonware/', ''))
		local isBedwars = relPath == 'games/bedwars.lua'
		-- Retried a few times: raw file hosts intermittently fail, returning an empty body that
		-- would otherwise get cached as a corrupt/empty file.
		local content
		for attempt = 1, 4 do
			local suc, res = pcall(function()
				if isBedwars then
					return game:HttpGet('https://gitlab.com/pistonware/pistonware/-/raw/main/bedwars.lua', true)
				end
				return game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/'..relPath, true)
			end)
			-- For .lua files, a compile check too: an outage can hand back the 503/error page
			-- as the body, and caching that would poison the install silently (cache-first
			-- means it would never be refetched).
			if suc and res and res ~= '' and res ~= '404: Not Found' and (not path:find('.lua') or loadstring(res) ~= nil) then
				content = res
				break
			end
			if attempt < 4 then
				task.wait(attempt)
			end
		end
		if not content then
			error('failed to download '..path..' after 4 attempts')
		end
		if path:find('.lua') then
			content = '--This watermark is used to delete the file if its cached, remove it to make the file persist after vape updates.\n'..content
		end
		writefile(path, content)
	end
	return (func or readfile)(path)
end

-- Standalone progress label for the prefetch phase, since it runs before the GUI framework
-- (and its own downloader label) exists yet.
local downloaderGui, downloaderLabel
local function updateDownloader(text)
	if not downloaderGui then
		downloaderGui = Instance.new('ScreenGui')
		downloaderGui.Name = 'PistonwareDownloader'
		downloaderGui.ResetOnSpawn = false
		downloaderGui.Parent = cloneref(game:GetService('CoreGui'))
		downloaderLabel = Instance.new('TextLabel')
		downloaderLabel.Size = UDim2.new(1, 0, 0, 40)
		downloaderLabel.BackgroundTransparency = 1
		downloaderLabel.TextStrokeTransparency = 0
		downloaderLabel.TextSize = 20
		downloaderLabel.TextColor3 = Color3.new(1, 1, 1)
		downloaderLabel.Parent = downloaderGui
	end
	downloaderLabel.Text = text
end
local function destroyDownloader()
	if downloaderGui then
		downloaderGui:Destroy()
		downloaderGui, downloaderLabel = nil, nil
	end
end

-- Downloads every file in a repo folder concurrently instead of one HttpGet per getcustomasset call,
-- so GUI construction reads already-cached files instead of blocking on ~190 sequential round trips.
local function prefetchFolder(folder)
	local reqSuc, res = pcall(function()
		return game:HttpGet('https://api.github.com/repos/themagicpiston/pistonware/contents/'..folder, true)
	end)
	if not (reqSuc and res and res ~= '404: Not Found') then return end
	local bodySuc, body = pcall(function()
		return cloneref(game:GetService('HttpService')):JSONDecode(res)
	end)
	if not (bodySuc and body and typeof(body) == 'table') then return end

	local toFetch = {}
	for _, v in body do
		-- hasContent, not isfile: a truncated asset from an interrupted prefetch must be picked
		-- up again here rather than skipped forever. See the note on hasContent.
		if v.type == 'file' and not hasContent('pistonware/'..folder..'/'..v.name) then
			table.insert(toFetch, v.name)
		end
	end
	if #toFetch <= 0 then return end

	local completed, pending, total = 0, #toFetch, #toFetch
	local done = Instance.new('BindableEvent')
	updateDownloader('Downloading '..folder..' ('..completed..'/'..total..')')
	for _, name in toFetch do
		task.spawn(function()
			pcall(downloadFile, 'pistonware/'..folder..'/'..name)
			completed += 1
			pending -= 1
			-- pcall'd and after the counters: if this ever threw, the task would die
			-- before releasing the wait below and the boot would hang on a GUI error
			pcall(updateDownloader, 'Downloading '..folder..' ('..completed..'/'..total..')')
			if pending <= 0 then
				done:Fire()
			end
		end)
	end
	-- Only wait when something is still outstanding. task.spawn runs each task inline
	-- until it yields, so on executors where HttpGet does NOT yield the scheduler every
	-- download finishes inside the loop above -- done:Fire() then lands with nothing
	-- listening yet, and an unconditional Wait() blocks forever with the label frozen at
	-- total/total. Same guard the loader's downloaders already use.
	if pending > 0 then
		done.Event:Wait()
	end
	done:Destroy()
end

-- False while a game script is still registering its modules on its own thread. A fast game
-- script sets this back to true before runGameScript even returns, so the common path never
-- observes it as false. finishLoading needs it because two of the things it starts are unsafe
-- until every module exists: the autosave loop, and the profile it applies.
local gameScriptFinished = true

-- Set once the profile has been applied against the full module set. Every Save() is gated on
-- this rather than on gameScriptFinished: a protected payload never sets that flag, so gating
-- saves on it would mean BedWars never autosaved or persisted a config change at all.
local profileApplied = false

local function finishLoading()
	vape.Init = nil
	-- shared.VapeCustomProfile is a ONE-SHOT hint for the load that immediately follows
	-- (set by the loader's first-run config chooser, or by the teleport handler below).
	-- Capture and clear it up front: getgenv()/shared persists across a reinject, so a
	-- value left over from an earlier teleport would keep forcing that old profile and
	-- override the config you actually switched to -- that stale value was the reinject
	-- 'loads the wrong config' bug. Cleared here, a plain reinject always falls through to
	-- the profile saved in gui.txt (i.e. whatever you last switched to).
	local customProfile = shared.VapeCustomProfile
	shared.VapeCustomProfile = nil
	if customProfile == '' then customProfile = nil end

	--[[
		The profile is applied EXACTLY ONCE, and only after every module exists.

		Loading it early and re-applying afterwards was tried and is wrong in both directions.
		Too early and the payload's modules do not exist yet, so they load on defaults; and the
		second pass needed to fix that would happily overwrite anything you had changed by hand
		in the meantime -- a toggle flipped at 10s silently reverting at 30s is a far worse bug
		than a config that arrives late. One load, once everything is registered, is the only
		version that cannot fight the user.

		Save() has the same constraint from the other side: it serialises the module list as it
		stands, so any save taken before the payload finishes writes a profile missing every
		module yet to appear -- destroying those settings on disk. Both the initial save and the
		autosave loop therefore sit behind the same wait.

		A normal game script has already finished by the time we get here (task.spawn runs it
		inline until it yields, and only bedwars.lua yields), so this whole block runs
		synchronously and behaves exactly as it always did.
	]]
	local function applyProfile()
		-- A session LuaArmor refused registered no game modules at all (see the session
		-- block at the top of bedwars.lua). Loading a profile against that empty set would
		-- bring everything up on defaults, and the Save below would write those defaults
		-- back -- deleting the user's real config. Withholding the modules is the intended
		-- consequence of a refusal; deleting configs is not, so do neither here.
		if shared.PistonwareSessionRejected then
			warn('[pistonware] session was not authorised -- leaving profiles untouched')
			return
		end
		vape:Load(nil, customProfile)
		profileApplied = true
		-- Persist the applied profile so a reinject before the first autosave tick still comes
		-- back to the same config.
		if customProfile then
			pcall(function() vape:Save() end)
		end
		-- Only now is autosaving safe, and only now is there a profile worth saving.
		-- The rejection check repeats inside the wait as well as at the top: a key can be
		-- revoked mid-session, and when that happens bedwars.lua switches every module off.
		-- Catching the flag only once per cycle would leave up to ten seconds in which this
		-- loop could persist that switched-off state over a good config.
		task.spawn(function()
			while vape.Loaded and not shared.PistonwareSessionRejected do
				vape:Save()
				for _ = 1, 10 do
					task.wait(1)
					if not vape.Loaded or shared.PistonwareSessionRejected then break end
				end
			end
		end)
	end

	-- Waits until the game script has finished registering its modules, because the profile can
	-- only be applied to modules that exist.
	--
	-- There are exactly two ways that finish is observable, and no third:
	--   * an ordinary game script RETURNS, which sets gameScriptFinished
	--   * BedWars pulls in a LuaArmor-protected payload which never returns (the VM keeps the
	--     thread it was invoked on), so bedwars.lua sets shared.PistonwareBedwarsLoaded as its
	--     final statement
	--
	-- An earlier version tried to infer completion by watching the module count go quiet. It
	-- does not work, and cannot be made to: the first seconds of downloadBedwars() are pure
	-- network, so nothing registers, and "nothing registering" is indistinguishable from
	-- "finished". It declared victory at 4s -- before the payload had started -- and every
	-- module that appeared afterwards was left on defaults. Guessing is worse than waiting.
	--
	-- The timeout is a backstop, not a mechanism. It only matters when the payload on LuaArmor
	-- predates the completion flag; re-upload bedwars.lua and this returns the moment it lands.
	local function waitForModules()
		if gameScriptFinished then return end
		local started = os.clock()
		repeat
			task.wait(0.1)
		until gameScriptFinished
			or shared.PistonwareBedwarsLoaded
			or os.clock() - started > 120
		local count = 0
		for _ in vape.Modules do count += 1 end
		local how = shared.PistonwareBedwarsLoaded and 'payload signalled'
			or gameScriptFinished and 'game script returned'
			or 'TIMED OUT after 120s -- re-upload bedwars.lua to LuaArmor so it can signal when it is done'
		warn(('[pistonware] %d modules in %.1fs (%s) -- applying profile'):format(count, os.clock() - started, how))
	end

	if gameScriptFinished then
		applyProfile()
	else
		task.spawn(function()
			waitForModules()
			applyProfile()
		end)
	end

	local teleportedServers
	vape:Clean(playersService.LocalPlayer.OnTeleport:Connect(function()
		if (not teleportedServers) and (not shared.VapeIndependent) then
			teleportedServers = true
			-- Re-runs main.lua, not the loader. The loader is a full boot -- duplicate-run
			-- guard, GitHub API calls for the update check, the console window, the config
			-- prompt -- and any one of those bailing on the new server leaves the script
			-- uninjected. main.lua only needs the files the loader already cached, so it
			-- comes back reliably; the loader still runs on a manual execute.
			local teleportScript = [[
				shared.vapereload = true
				local cached = isfile and isfile('pistonware/main.lua') and readfile('pistonware/main.lua')
				if cached and cached ~= '' then
					loadstring(cached, 'main')()
				else
					loadstring(game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/main.lua', true), 'main')()
				end
			]]
			-- Globals and shared do not survive a teleport, and the new server re-runs main.lua
			-- directly rather than the loader -- so the key gate's output has to be re-published
			-- by hand here. Without it the guard at the top of this file would reject the
			-- re-injection, and bedwars.lua would be handed to loadstring with no script_key.
			-- %q so a key containing a quote or backslash still produces a valid chunk.
			if shared.PistonwareKey then
				local quoted = string.format('%q', shared.PistonwareKey)
				teleportScript = 'script_key = '..quoted..'\nshared.PistonwareKey = '..quoted..'\nshared.PistonwareAuthenticated = true\n'..teleportScript
			end
			if shared.PistonwareDeveloper then
				teleportScript = 'shared.PistonwareDeveloper = true\n'..teleportScript
			end
			if shared.VapeSmoothBoot then
				teleportScript = 'shared.VapeSmoothBoot = true\n'..teleportScript
			end
			-- %q, matching the key above: profile names are user-supplied (the Profiles tab lets
			-- you name one anything), and a name containing a quote or backslash used to produce
			-- a chunk that would not compile -- which silently costs the whole re-injection, not
			-- just the profile.
			-- customProfile is the fallback rather than shared.VapeCustomProfile (cleared above):
			-- queueing before the payload has finished means vape.Profile is not set yet, and
			-- without this the next server would be told to load 'default'.
			teleportScript = 'shared.VapeCustomProfile = '..string.format('%q', vape.Profile or customProfile or 'default')..'\n'..teleportScript
			-- Same rule as everywhere else: saving before the profile has been applied against the
			-- full module set would write one missing every module still to appear. Queueing
			-- straight into a match is exactly when that happens, so skip the save rather than
			-- corrupt the config -- what is on disk is already correct, there is simply nothing
			-- new worth recording yet.
			if profileApplied then
				vape:Save()
			end
			if not hasQueueOnTeleport then
				vape:CreateNotification('Pistonware', 'queue_on_teleport is not supported by your executor -- Vape will not re-inject automatically after this teleport (e.g. queueing into a match). You will need to re-run your loadstring manually.', 15, 'alert')
			end
			queue_on_teleport(teleportScript)
		end
	end))

	if shared.PistonwareSyncResult then
		vape:CreateNotification('Pistonware', shared.PistonwareSyncResult, 15, shared.PistonwareSyncResult:find('failed') and 'alert' or nil)
		shared.PistonwareSyncResult = nil
	end

	if not shared.vapereload then
		if not vape.Categories then return end
		if vape.Categories.Main.Options['GUI bind indicator'].Enabled then
			vape:CreateNotification('Pistonware | Finished Loading', vape.VapeButton and 'Press the button in the top right to open GUI' or 'Press '..table.concat(vape.Keybind, ' + '):upper()..' to open GUI', 5)
		end
	end
end

	if not isfile('pistonware/profiles/gui.txt') then
		writefile('pistonware/profiles/gui.txt', 'new')
	end
	local gui = readfile('pistonware/profiles/gui.txt')

	if not isfolder('pistonware/assets/'..gui) then
		makefolder('pistonware/assets/'..gui)
	end
	pcall(prefetchFolder, 'assets/'..gui)
	if gui ~= 'new' then
		pcall(prefetchFolder, 'assets/new')
	end
	destroyDownloader()
	vape = loadstring(downloadFile('pistonware/guis/'..gui..'.lua'), 'gui')()
	shared.vape = vape

if not shared.VapeIndependent then
	-- downloading doesn't need the game loaded; only wait here, right before touching game/character state
	if not game:IsLoaded() then
		repeat task.wait() until game:IsLoaded()
		-- identifyexecutor is absent on some executors (common on mobile); calling it
		-- unguarded errors here and aborts everything below, including the game script.
		local executorName = ''
		pcall(function() executorName = identifyexecutor and identifyexecutor() or '' end)
		task.wait(executorName == 'Opiumware' and 30 or 5)
	end
	-- pcall'd: an error thrown while universal.lua *executes* would otherwise propagate out of
	-- main.lua entirely, skipping the game script below and finishLoading() with it.
	pcall(function()
		loadstring(downloadFile('pistonware/games/universal.lua'), 'universal')()
	end)

	-- Started, never waited on. There is no deadline here by design: a deadline would only be a
	-- guess at how long the payload needs, and whatever number it held would become the time
	-- your profile takes to load. Nothing below depends on this having finished -- finishLoading
	-- applies your profile to the modules that exist now, and re-applies it the moment the rest
	-- register (see finishLoading).
	--
	-- This costs nothing for a normal game script: task.spawn runs the function inline until it
	-- yields, so anything that registers its modules without yielding -- which is every game
	-- file except BedWars -- has already set gameScriptFinished before we get past this line,
	-- and finishLoading takes the single-pass path exactly as it always did.
	--
	-- BedWars is the exception. bedwars.lua is 425KB interpreted by a LuaArmor VM and takes
	-- ~30s, and none of its modules can exist until it finishes -- that part is not fixable from
	-- here. What it must not do is hold up the GUI, the universal modules and your config, none
	-- of which have anything to do with it.
	--
	-- Varargs are packed because '...' is only valid directly in this chunk, never inside the
	-- nested function the spawn needs.
	local gameArgs = table.pack(...)
	local function runGameScript(source, chunkname)
		local fn = loadstring(source, chunkname)
		if not fn then return end
		gameScriptFinished = false
		-- Cleared per run, not just per session: shared survives a reinject, and a leftover true
		-- from the previous injection would tell waitForModules the payload had already finished
		-- before it had even started re-registering.
		shared.PistonwareBedwarsLoaded = nil
		-- Same reasoning for the refusal flag: bedwars.lua sets it from a fresh verdict every
		-- run, but a game script that never sets it at all (the lobby) would otherwise inherit
		-- a true left behind by a revoked BedWars session and refuse to save profiles there.
		shared.PistonwareSessionRejected = nil

		-- Re-publish the key immediately before the game script runs. LuaArmor blanks the global
		-- script_key once it has authenticated, so it is single-use per session and any later
		-- load finds nothing -- which is not a soft failure, it kicks the player.
		--
		-- games/6872274481.lua does this too, closer to the payload, but that file is CACHED:
		-- anyone still holding a copy from before it gained that call would never get it. This
		-- file is the one that is reliably current, so the safety net belongs here as well.
		--
		-- Written to all three tables because executors disagree on what a loadstring'd chunk's
		-- environment is -- on several mobile executors a bare global, getgenv() and _G are
		-- genuinely different tables, and the payload only reads one of them.
		if type(shared.PistonwareKey) == 'string' and shared.PistonwareKey ~= '' then
			local key = shared.PistonwareKey
			script_key = key
			pcall(function() getgenv().script_key = key end)
			pcall(function() _G.script_key = key end)
		end

		local started = os.clock()
		task.spawn(function()
			local ok, err = pcall(fn, table.unpack(gameArgs, 1, gameArgs.n))
			gameScriptFinished = true
			-- Only for a payload slow enough that the split-load path actually engaged; a normal
			-- game script never trips it. Keeps the real cost of protecting bedwars.lua visible
			-- instead of guessed at.
			local elapsed = os.clock() - started
			if elapsed > 5 then
				warn(('[pistonware] %s finished in %.1fs -- its modules now have their saved settings'):format(chunkname, elapsed))
			end
			if not ok then
				warn('[pistonware] '..chunkname..' errored: '..tostring(err))
			end
		end)
	end

	local gamePath = 'pistonware/games/'..game.PlaceId..'.lua'
	-- A cached-but-empty file is treated as missing and refetched: a truncated write from an
	-- earlier failed download reads back as "present", and loadstring('') silently does
	-- nothing -- indistinguishable from the game script never loading at all.
	local cached = isfile(gamePath) and readfile(gamePath) or nil
	if cached and cached:gsub('%s', '') ~= '' then
		runGameScript(cached, tostring(game.PlaceId))
	elseif not shared.PistonwareDeveloper then
		-- Single fetch (the old code requested this URL twice: once to probe, then again
		-- inside downloadFile) and load straight from the response, so a stale/corrupt
		-- cache file can't shadow what we just downloaded.
		local suc, res = pcall(function()
			return game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/games/'..game.PlaceId..'.lua', true)
		end)
		if suc and res and res ~= '' and res ~= '404: Not Found' then
			pcall(writefile, gamePath, '--This watermark is used to delete the file if its cached, remove it to make the file persist after vape updates.\n'..res)
			runGameScript(res, tostring(game.PlaceId))
		end
	end
	finishLoading()
else
	vape.Init = finishLoading
	return vape
end
