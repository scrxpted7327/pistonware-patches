local SCHEMA = 2

return function(adapter)
	assert(type(adapter) == 'table', 'capability adapter must be a table')
	local environment = assert(adapter.environment, 'missing executor environment')
	local buffer = adapter.buffer
	local gameObject = adapter.game
	local instanceLibrary = adapter.Instance
	local flags, results = {}, {}
	local probes, order, groups = {}, {}, {}

	local function environmentValue(path)
		local value = environment
		for name in tostring(path):gmatch('[^.]+') do
			if type(value) ~= 'table' then return nil end
			local ok, result = pcall(function() return value[name] end)
			if not ok then return nil end
			value = result
		end
		return value
	end

	local function bufferCall(method, event, message, details)
		local callback = type(buffer) == 'table' and buffer[method] or nil
		if type(callback) == 'function' then
			pcall(callback, event, message, details)
		end
	end

	local function register(id, callback, options)
		assert(type(id) == 'string' and probes[id] == nil, 'duplicate capability: '..tostring(id))
		probes[id] = {callback = callback, deferred = options and options.deferred == true}
		order[#order + 1] = id
		flags[id] = false
		results[id] = {status = probes[id].deferred and 'deferred' or 'pending'}
	end

	local function execute(id)
		local probe = probes[id]
		if not probe then
			flags[id] = false
			results[id] = {status = 'missing', reason = 'capability is not registered'}
			return false
		end

		local cleanup = {}
		local function restore(callback)
			cleanup[#cleanup + 1] = callback
		end
		local started = os.clock()
		local ok, supported, reason, details = xpcall(function()
			return probe.callback(environmentValue, restore)
		end, function(err)
			local traceback
			pcall(function()
				traceback = debug and type(debug.traceback) == 'function'
					and debug.traceback(tostring(err), 2)
			end)
			return traceback or tostring(err)
		end)

		local cleanupErrors = {}
		for index = #cleanup, 1, -1 do
			local cleanupOk, cleanupError = pcall(cleanup[index])
			if not cleanupOk then cleanupErrors[#cleanupErrors + 1] = tostring(cleanupError) end
		end

		if not ok then
			reason = supported
			supported = false
		elseif #cleanupErrors > 0 then
			supported = false
			reason = 'cleanup failed: '..table.concat(cleanupErrors, '; ')
		else
			supported = supported == true
		end

		local duration = os.clock() - started
		flags[id] = supported
		local status = supported and 'passed' or 'failed'
		if not supported and type(details) == 'table'
			and (details.status == 'missing' or details.status == 'blocked') then
			status = details.status
		end
		results[id] = {
			status = status,
			reason = supported and 'behavior verified' or tostring(reason or 'behavior mismatch'),
			duration = duration,
			details = type(details) == 'table' and details or nil
		}
		bufferCall(supported and 'print' or 'warn', 'executor.capability',
			id..': '..(supported and 'PASS' or 'FAIL'), {
				reason = results[id].reason,
				duration = duration
			})
		return supported
	end

	local function requireFunction(value, path)
		local callback = value(path)
		if type(callback) ~= 'function' then return nil, 'missing '..path end
		return callback
	end

	local function debugFixture()
		local captured = 'pistonware-debug-upvalue'
		local function sample(replacement)
			if replacement ~= nil then captured = replacement end
			local function nested() return 'pistonware-debug-proto' end
			return captured, 'pistonware-debug-constant', nested
		end
		return sample, captured
	end

	local function findValue(values, expected)
		if type(values) ~= 'table' then return nil end
		for index, value in values do
			if value == expected then return index end
		end
	end

	register('environment.getgenv', function(value)
		local getgenv, reason = requireFunction(value, 'getgenv')
		if not getgenv then return false, reason end
		local firstOk, first = pcall(getgenv)
		local secondOk, second = pcall(getgenv)
		return firstOk and secondOk and type(first) == 'table' and first == second,
			'getgenv did not return one stable table'
	end)

	register('code.loadstring', function(value)
		local loadstring, reason = requireFunction(value, 'loadstring')
		if not loadstring then return false, reason end
		local compileOk, chunk = pcall(loadstring, "return 'pistonware-capability'", 'capability-probe')
		if not compileOk or type(chunk) ~= 'function' then return false, 'loadstring did not compile' end
		local runOk, result = pcall(chunk)
		return runOk and result == 'pistonware-capability', 'compiled chunk returned the wrong value'
	end)

	register('debug.library', function(value)
		return type(value('debug')) == 'table', 'missing debug table'
	end)

	register('debug.getinfo', function(value)
		local callback, reason = requireFunction(value, 'debug.getinfo')
		if not callback then return false, reason end
		local sample = debugFixture()
		local ok, result = pcall(callback, sample, 'sna')
		return ok and type(result) == 'table', 'debug.getinfo returned no table'
	end)

	register('debug.getconstants', function(value)
		local callback, reason = requireFunction(value, 'debug.getconstants')
		if not callback then return false, reason end
		local sample = debugFixture()
		local ok, constants = pcall(callback, sample)
		return ok and findValue(constants, 'pistonware-debug-constant') ~= nil,
			'debug.getconstants did not return the probe constant'
	end)

	register('debug.getconstant', function(value)
		local getconstants, firstReason = requireFunction(value, 'debug.getconstants')
		local getconstant, secondReason = requireFunction(value, 'debug.getconstant')
		if not getconstants then return false, firstReason end
		if not getconstant then return false, secondReason end
		local sample = debugFixture()
		local constantsOk, constants = pcall(getconstants, sample)
		local index = constantsOk and findValue(constants, 'pistonware-debug-constant') or nil
		if not index then return false, 'probe constant was not found' end
		local ok, result = pcall(getconstant, sample, index)
		return ok and result == 'pistonware-debug-constant', 'debug.getconstant returned the wrong value'
	end)

	register('debug.setconstant', function(value, restore)
		local getconstants, firstReason = requireFunction(value, 'debug.getconstants')
		local setconstant, secondReason = requireFunction(value, 'debug.setconstant')
		if not getconstants then return false, firstReason end
		if not setconstant then return false, secondReason end
		local sample = debugFixture()
		local constantsOk, constants = pcall(getconstants, sample)
		local index = constantsOk and findValue(constants, 'pistonware-debug-constant') or nil
		if not index then return false, 'probe constant was not found' end
		restore(function() setconstant(sample, index, 'pistonware-debug-constant') end)
		local ok = pcall(setconstant, sample, index, 'pistonware-debug-updated')
		return ok and select(2, sample()) == 'pistonware-debug-updated',
			'debug.setconstant did not change the probe'
	end)

	register('debug.getupvalues', function(value)
		local callback, reason = requireFunction(value, 'debug.getupvalues')
		if not callback then return false, reason end
		local sample, captured = debugFixture()
		local ok, upvalues = pcall(callback, sample)
		return ok and findValue(upvalues, captured) ~= nil,
			'debug.getupvalues did not return the probe upvalue'
	end)

	register('debug.getupvalue', function(value)
		local getupvalues, firstReason = requireFunction(value, 'debug.getupvalues')
		local getupvalue, secondReason = requireFunction(value, 'debug.getupvalue')
		if not getupvalues then return false, firstReason end
		if not getupvalue then return false, secondReason end
		local sample, captured = debugFixture()
		local upvaluesOk, upvalues = pcall(getupvalues, sample)
		local index = upvaluesOk and findValue(upvalues, captured) or nil
		if not index then return false, 'probe upvalue was not found' end
		local ok, result = pcall(getupvalue, sample, index)
		return ok and result == captured, 'debug.getupvalue returned the wrong value'
	end)

	register('debug.setupvalue', function(value, restore)
		local getupvalues, firstReason = requireFunction(value, 'debug.getupvalues')
		local setupvalue, secondReason = requireFunction(value, 'debug.setupvalue')
		if not getupvalues then return false, firstReason end
		if not setupvalue then return false, secondReason end
		local sample, captured = debugFixture()
		local upvaluesOk, upvalues = pcall(getupvalues, sample)
		local index = upvaluesOk and findValue(upvalues, captured) or nil
		if not index then return false, 'probe upvalue was not found' end
		restore(function() setupvalue(sample, index, captured) end)
		local ok = pcall(setupvalue, sample, index, 'pistonware-debug-updated')
		return ok and select(1, sample()) == 'pistonware-debug-updated',
			'debug.setupvalue did not change the probe'
	end)

	register('debug.getprotos', function(value)
		local callback, reason = requireFunction(value, 'debug.getprotos')
		if not callback then return false, reason end
		local sample = debugFixture()
		local ok, protos = pcall(callback, sample)
		return ok and type(protos) == 'table' and type(protos[1]) == 'function',
			'debug.getprotos returned no nested function'
	end)

	register('debug.getproto', function(value)
		local callback, reason = requireFunction(value, 'debug.getproto')
		if not callback then return false, reason end
		local sample = debugFixture()
		local ok, proto = pcall(callback, sample, 1)
		return ok and (type(proto) == 'function' or type(proto) == 'table'),
			'debug.getproto returned no nested function'
	end)

	register('debug.getstack', function(value)
		local callback, reason = requireFunction(value, 'debug.getstack')
		if not callback then return false, reason end
		for level = 0, 4 do
			local ok, stack = pcall(callback, level)
			if ok and type(stack) == 'table' then return true end
		end
		return false, 'debug.getstack returned no stack table'
	end)

	register('debug.setstack', function(value)
		local getstack, firstReason = requireFunction(value, 'debug.getstack')
		local setstack, secondReason = requireFunction(value, 'debug.setstack')
		if not getstack then return false, firstReason end
		if not setstack then return false, secondReason end
		local before, after = {}, {}
		local function stackProbe(marker)
			local index = findValue(getstack(1), before)
			if not index then return false end
			setstack(1, index, after)
			return marker == after
		end
		local ok, changed = pcall(stackProbe, before)
		return ok and changed == true, 'debug.setstack did not change a local value'
	end)

	register('hookfunction', function(value)
		local hookfunction, reason = requireFunction(value, 'hookfunction')
		if not hookfunction then return false, reason end
		local function target(input) return 'original:'..input end
		local ok, original = pcall(hookfunction, target, function(input) return 'hooked:'..input end)
		if not ok or type(original) ~= 'function' then return false, 'hookfunction returned no original' end
		local callOk, result = pcall(target, 'probe')
		return callOk and result == 'hooked:probe', 'hooked function did not run'
	end)

	register('restorefunction', function(value)
		local hookfunction, firstReason = requireFunction(value, 'hookfunction')
		local restorefunction, secondReason = requireFunction(value, 'restorefunction')
		if not hookfunction then return false, firstReason end
		if not restorefunction then return false, secondReason end
		local function target() return 'original' end
		local hookOk = pcall(hookfunction, target, function() return 'hooked' end)
		if not hookOk or target() ~= 'hooked' then return false, 'setup hook failed' end
		local restoreOk = pcall(restorefunction, target)
		return restoreOk and target() == 'original', 'original function was not restored'
	end)

	register('closure.islua', function(value)
		local islclosure, reason = requireFunction(value, 'islclosure')
		if not islclosure then return false, reason end
		local ok, result = pcall(islclosure, function() end)
		return ok and result == true, 'islclosure rejected a Luau closure'
	end)

	register('closure.isc', function(value)
		local iscclosure, reason = requireFunction(value, 'iscclosure')
		if not iscclosure then return false, reason end
		local ok, result = pcall(iscclosure, tostring)
		return ok and result == true, 'iscclosure rejected a native closure'
	end)

	register('closure.newc', function(value)
		local newcclosure, reason = requireFunction(value, 'newcclosure')
		if not newcclosure then return false, reason end
		local ok, closure = pcall(newcclosure, function(input) return input end)
		if not ok or type(closure) ~= 'function' then
			return false, 'newcclosure returned no callable closure'
		end
		local callOk, result = pcall(closure, 'probe')
		return callOk and result == 'probe',
			'newcclosure returned no callable closure'
	end)

	register('closure.checkcaller', function(value)
		local checkcaller, reason = requireFunction(value, 'checkcaller')
		if not checkcaller then return false, reason end
		local ok, result = pcall(checkcaller)
		return ok and result == true, 'checkcaller did not identify the executor thread'
	end)

	register('metatable.getraw.table', function(value)
		local getrawmetatable, reason = requireFunction(value, 'getrawmetatable')
		if not getrawmetatable then return false, reason end
		local expected = {__metatable = 'locked', __index = function(_, key) return 'first:'..key end}
		local object = setmetatable({}, expected)
		local ok, result = pcall(getrawmetatable, object)
		return ok and result == expected and getmetatable(object) == 'locked',
			'getrawmetatable did not bypass protection'
	end)

	register('metatable.getraw.instance', function(value)
		local getrawmetatable, reason = requireFunction(value, 'getrawmetatable')
		if not getrawmetatable then return false, reason end
		if not gameObject then return false, 'missing game object' end
		local ok, result = pcall(getrawmetatable, gameObject)
		return ok and type(result) == 'table' and type(result.__namecall) == 'function',
			'getrawmetatable returned no Instance metatable'
	end)

	register('metatable.setraw', function(value, restore)
		local getrawmetatable, firstReason = requireFunction(value, 'getrawmetatable')
		local setrawmetatable, secondReason = requireFunction(value, 'setrawmetatable')
		if not getrawmetatable then return false, firstReason end
		if not setrawmetatable then return false, secondReason end
		local first = {__index = function(_, key) return 'first:'..key end}
		local second = {__index = function(_, key) return 'second:'..key end}
		local object = setmetatable({}, first)
		restore(function() setrawmetatable(object, first) end)
		local ok = pcall(setrawmetatable, object, second)
		return ok and getrawmetatable(object) == second and object.probe == 'second:probe',
			'raw metatable replacement failed'
	end)

	register('metatable.setreadonly', function(value, restore)
		local setreadonly, reason = requireFunction(value, 'setreadonly')
		if not setreadonly then return false, reason end
		local object = {value = 'first'}
		restore(function() pcall(setreadonly, object, false) end)
		local lockOk = pcall(setreadonly, object, true)
		local writeWhileLocked = pcall(function() object.value = 'locked-write' end)
		local unlockOk = pcall(setreadonly, object, false)
		local writeAfterUnlock = pcall(function() object.value = 'second' end)
		return lockOk and not writeWhileLocked and unlockOk and writeAfterUnlock and object.value == 'second',
			'setreadonly did not enforce and restore table writes'
	end)

	register('metatable.hook.table', function(value, restore)
		local hookmetamethod, reason = requireFunction(value, 'hookmetamethod')
		if not hookmetamethod then return false, reason end
		local object = setmetatable({}, {__index = function(_, key) return 'original:'..key end})
		local ok, original = pcall(hookmetamethod, object, '__index', function(_, key) return 'hooked:'..key end)
		if not ok or type(original) ~= 'function' then return false, 'hookmetamethod returned no original' end
		restore(function() hookmetamethod(object, '__index', original) end)
		local callOk, result = pcall(function() return object.probe end)
		return callOk and result == 'hooked:probe', 'table metamethod hook did not run'
	end)

	register('metatable.hook.instance', function(value, restore)
		local hookmetamethod, reason = requireFunction(value, 'hookmetamethod')
		if not hookmetamethod then return false, reason end
		if not gameObject then return false, 'missing game object' end
		local observed, original
		local ok, result = pcall(function()
			original = hookmetamethod(gameObject, '__index', function(self, key)
				if self == gameObject and key == 'PlaceId' then observed = true end
				return original(self, key)
			end)
			return original
		end)
		if not ok or type(result) ~= 'function' then return false, 'could not hook Instance __index' end
		restore(function() hookmetamethod(gameObject, '__index', original) end)
		local readOk = pcall(function() return gameObject.PlaceId end)
		return readOk and observed == true, 'Instance metamethod hook did not observe __index'
	end)

	local namecallBlocked

	local function probeNamecall(value, provider)
		local details = {provider = provider}
		if namecallBlocked then
			details.status = 'blocked'
			return false, namecallBlocked, details
		end
		local required = provider == 'native'
			and {'getrawmetatable', 'newcclosure', 'hookmetamethod'}
			or {'getrawmetatable', 'newcclosure', 'setreadonly', 'isreadonly'}
		local api = {}
		for _, name in required do
			local callback, reason = requireFunction(value, name)
			if not callback then
				details.status = 'missing'
				return false, reason, details
			end
			api[name] = callback
		end
		if not gameObject then
			details.status = 'blocked'
			return false, 'missing game object', details
		end
		local mt = api.getrawmetatable(gameObject)
		if type(mt) ~= 'table' or type(mt.__namecall) ~= 'function' then
			return false, 'Instance metatable has no callable __namecall', details
		end
		local before = mt.__namecall
		local readonly
		if provider == 'raw' then
			readonly = api.isreadonly(mt)
			if type(readonly) ~= 'boolean' then
				details.status = 'blocked'
				return false, 'cannot determine original readonly state', details
			end
		end
		local expected = gameObject.GetService(gameObject, 'Players')
		if expected == nil then
			return false, 'baseline GetService returned nil', details
		end
		local getMethod = value('getnamecallmethod')
		local original, active, nativeOriginal = before, nil, nil
		local calls, probing = 0, false
		local methodOk, method = false, 'method was not observed'
		local replacement = api.newcclosure(function(self, ...)
			if self == gameObject then
				calls += 1
				if probing and type(getMethod) == 'function' then
					methodOk, method = pcall(getMethod)
				end
			end
			return original(self, ...)
		end)
		if type(replacement) ~= 'function' then
			return false, 'newcclosure returned no callable closure', details
		end

		local function cleanup()
			if provider == 'native' then
				assert(type(nativeOriginal) == 'function',
					'native installation did not return an original function')
				assert(mt.__namecall == active, 'native namecall ownership changed')
				api.hookmetamethod(gameObject, '__namecall', nativeOriginal)
			else
				local slotOk, slotError = pcall(function()
					if mt.__namecall == replacement then
						api.setreadonly(mt, false)
						mt.__namecall = before
					else
						assert(mt.__namecall == before, 'raw namecall ownership changed')
					end
				end)
				local lockOk, lockError = pcall(api.setreadonly, mt, readonly)
				assert(slotOk, tostring(slotError))
				assert(lockOk, tostring(lockError))
				assert(mt.__namecall == before, 'raw namecall restoration failed')
				assert(api.isreadonly(mt) == readonly, 'readonly restoration failed')
			end
			local previousCalls = calls
			assert(gameObject:GetService('Players') == expected,
				'restored GetService returned the wrong service')
			assert(calls == previousCalls, 'probe interceptor remains active')
		end

		local ok, err = pcall(function()
			if provider == 'native' then
				nativeOriginal = api.hookmetamethod(gameObject, '__namecall', replacement)
				assert(type(nativeOriginal) == 'function',
					'hookmetamethod returned no original function')
				original = nativeOriginal
				active = mt.__namecall
			else
				api.setreadonly(mt, false)
				mt.__namecall = replacement
				api.setreadonly(mt, readonly)
			end
			probing = true
			local result = gameObject:GetService('Players')
			probing = false
			assert(calls > 0, 'namecall interceptor did not run')
			assert(result == expected, 'intercepted GetService returned the wrong service')
		end)
		probing = false
		local cleanupOk, cleanupError = pcall(cleanup)
		if not cleanupOk then
			namecallBlocked = 'namecall cleanup failed: '..tostring(cleanupError)
			details.status = 'blocked'
			return false, namecallBlocked, details
		end
		if not ok then return false, tostring(err), details end
		details.methodSupported = methodOk and method == 'GetService'
		details.methodReason = type(getMethod) ~= 'function'
			and 'missing getnamecallmethod'
			or (details.methodSupported and 'observed GetService' or tostring(method))
		return true, nil, details
	end

	register('namecall.hook.native', function(value)
		return probeNamecall(value, 'native')
	end, {deferred = true})

	register('namecall.hook.raw', function(value)
		return probeNamecall(value, 'raw')
	end, {deferred = true})

	register('namecall.getmethod', function(value)
		if namecallBlocked then
			return false, namecallBlocked, {status = 'blocked'}
		end
		if type(value('getnamecallmethod')) ~= 'function' then
			return false, 'missing getnamecallmethod', {status = 'missing'}
		end
		local reasons, intercepted = {}, false
		for _, id in {'namecall.hook.native', 'namecall.hook.raw'} do
			local supported = execute(id)
			local result = results[id]
			if namecallBlocked then
				return false, namecallBlocked, {status = 'blocked'}
			end
			if supported then
				intercepted = true
				if result.details.methodSupported then
					return true, nil, {provider = result.details.provider}
				end
			end
			reasons[#reasons + 1] = id..': '..tostring(
				supported and result.details.methodReason or result.reason
			)
		end
		return false, table.concat(reasons, '; '), {
			status = intercepted and 'failed' or 'blocked'
		}
	end)

	local function identityFunctions(value)
		local getIdentity = type(value('getidentity')) == 'function' and value('getidentity') or value('getthreadidentity')
		local setIdentity = type(value('setidentity')) == 'function' and value('setidentity') or value('setthreadidentity')
		return getIdentity, setIdentity
	end

	register('thread.getidentity', function(value)
		local getIdentity = identityFunctions(value)
		if type(getIdentity) ~= 'function' then return false, 'missing identity getter' end
		local ok, identity = pcall(getIdentity)
		return ok and type(identity) == 'number', 'identity getter returned no number'
	end)

	register('thread.setidentity', function(value, restore)
		local getIdentity, setIdentity = identityFunctions(value)
		if type(getIdentity) ~= 'function' then return false, 'missing identity getter' end
		if type(setIdentity) ~= 'function' then return false, 'missing identity setter' end
		local originalOk, original = pcall(getIdentity)
		if not originalOk or type(original) ~= 'number' then return false, 'could not read original identity' end
		restore(function() setIdentity(original) end)
		local setOk = pcall(setIdentity, 2)
		local readOk, current = pcall(getIdentity)
		return setOk and readOk and current == 2, 'identity did not change to 2'
	end)

	register('thread.restore', function(value)
		local getIdentity, setIdentity = identityFunctions(value)
		if type(getIdentity) ~= 'function' or type(setIdentity) ~= 'function' then
			return false, 'missing identity getter or setter'
		end
		local originalOk, original = pcall(getIdentity)
		if not originalOk or type(original) ~= 'number' then return false, 'could not read original identity' end
		local target = original == 2 and 3 or 2
		local setOk = pcall(setIdentity, target)
		local restoreOk = pcall(setIdentity, original)
		local readOk, restored = pcall(getIdentity)
		return setOk and restoreOk and readOk and restored == original,
			'identity was not restored'
	end)

	register('thread.coregui', function(value, restore)
		local getIdentity, setIdentity = identityFunctions(value)
		if type(getIdentity) ~= 'function' or type(setIdentity) ~= 'function' then
			return false, 'missing identity getter or setter'
		end
		if not gameObject or not instanceLibrary then return false, 'missing Roblox adapter' end
		local originalOk, original = pcall(getIdentity)
		if not originalOk then return false, 'could not read original identity' end
		restore(function() setIdentity(original) end)
		if not pcall(setIdentity, 8) then return false, 'could not set identity 8' end
		local folder = instanceLibrary.new('Folder')
		restore(function() folder:Destroy() end)
		local coreGui = gameObject:GetService('CoreGui')
		local ok = pcall(function() folder.Parent = coreGui end)
		return ok and folder.Parent == coreGui, 'identity 8 could not write CoreGui'
	end)

	local function signalFixture()
		if not instanceLibrary then return nil, 'missing Instance library' end
		return instanceLibrary.new('BindableEvent')
	end

	register('signal.getconnections', function(value, restore)
		local getconnections, reason = requireFunction(value, 'getconnections')
		if not getconnections then return false, reason end
		local bindable, fixtureReason = signalFixture()
		if not bindable then return false, fixtureReason end
		restore(function() bindable:Destroy() end)
		local callback = function() end
		local connection = bindable.Event:Connect(callback)
		restore(function() connection:Disconnect() end)
		local ok, connections = pcall(getconnections, bindable.Event)
		if not ok or type(connections) ~= 'table' then return false, 'getconnections returned no table' end
		for _, candidate in connections do
			if candidate.Function == callback or candidate.Callback == callback then return true end
		end
		return false, 'probe connection was not returned'
	end)

	register('signal.fire', function(value, restore)
		local firesignal, reason = requireFunction(value, 'firesignal')
		if not firesignal then return false, reason end
		local bindable, fixtureReason = signalFixture()
		if not bindable then return false, fixtureReason end
		restore(function() bindable:Destroy() end)
		local received
		local connection = bindable.Event:Connect(function(input) received = input end)
		restore(function() connection:Disconnect() end)
		local ok = pcall(firesignal, bindable.Event, 'pistonware-signal-probe')
		return ok and received == 'pistonware-signal-probe', 'firesignal did not run the connection'
	end)

	for _, method in {'Disable', 'Enable', 'Fire'} do
		register('signal.connection.'..method:lower(), function(value, restore)
			local getconnections, reason = requireFunction(value, 'getconnections')
			if not getconnections then return false, reason end
			local bindable, fixtureReason = signalFixture()
			if not bindable then return false, fixtureReason end
			restore(function() bindable:Destroy() end)
			local connection = bindable.Event:Connect(function() end)
			restore(function() connection:Disconnect() end)
			local connections = getconnections(bindable.Event)
			local candidate = type(connections) == 'table' and connections[1] or nil
			local callback = candidate and candidate[method]
			if type(callback) ~= 'function' then return false, 'connection has no '..method end
			local ok = pcall(callback, candidate)
			return ok, method..' failed on the connection object'
		end)
	end

	register('gc.get.functions', function(value)
		local getgc, reason = requireFunction(value, 'getgc')
		if not getgc then return false, reason end
		local sentinel = function() return true end
		local ok, objects = pcall(getgc, false)
		if not ok or type(objects) ~= 'table' then return false, 'getgc returned no table' end
		for _, object in objects do if object == sentinel then return true end end
		return false, 'getgc did not return the probe closure'
	end)

	register('gc.get.tables', function(value)
		local getgc, reason = requireFunction(value, 'getgc')
		if not getgc then return false, reason end
		local sentinel = {pistonwareCapability = true}
		local ok, objects = pcall(getgc, true)
		if not ok or type(objects) ~= 'table' then return false, 'getgc(true) returned no table' end
		for _, object in objects do if object == sentinel then return true end end
		return false, 'getgc(true) did not return the probe table'
	end)

	register('script.getenvironment', function(value)
		local getrenv, reason = requireFunction(value, 'getrenv')
		if not getrenv then return false, reason end
		local ok, result = pcall(getrenv)
		return ok and type(result) == 'table', 'getrenv returned no table'
	end)

	local function findScripts()
		local scripts = {}
		if not gameObject then return scripts end
		local ok, playerScripts = pcall(function()
			local player = gameObject:GetService('Players').LocalPlayer
			return player and player:FindFirstChildOfClass('PlayerScripts')
		end)
		if not ok or not playerScripts then return scripts end
		local descendantsOk, descendants = pcall(function() return playerScripts:GetDescendants() end)
		if not descendantsOk then return scripts end
		for _, object in descendants do
			if object:IsA('LocalScript') or object:IsA('ModuleScript') then
				scripts[#scripts + 1] = object
			end
		end
		return scripts
	end

	register('script.getbytecode', function(value)
		local getscriptbytecode, reason = requireFunction(value, 'getscriptbytecode')
		if not getscriptbytecode then return false, reason end
		local scripts = findScripts()
		if #scripts == 0 then return false, 'no safe script target was available' end
		for _, scriptObject in scripts do
			local ok, bytecode = pcall(getscriptbytecode, scriptObject)
			if ok and type(bytecode) == 'string' and #bytecode > 0 then return true end
		end
		return false, 'getscriptbytecode returned no bytecode for any safe target'
	end)

	register('script.getclosure', function(value)
		local getscriptclosure, reason = requireFunction(value, 'getscriptclosure')
		if not getscriptclosure then return false, reason end
		local scripts = findScripts()
		if #scripts == 0 then return false, 'no safe script target was available' end
		for _, scriptObject in scripts do
			local ok, closure = pcall(getscriptclosure, scriptObject)
			if ok and type(closure) == 'function' then return true end
		end
		return false, 'getscriptclosure returned no function for any safe target'
	end)

	register('signal.replicate', function(value)
		local replicatesignal, reason = requireFunction(value, 'replicatesignal')
		if not replicatesignal then return false, reason end
		local bindable, fixtureReason = signalFixture()
		if not bindable then return false, fixtureReason end
		local ok = pcall(replicatesignal, bindable.Event, 'pistonware-replication-probe')
		bindable:Destroy()
		return ok, 'replicatesignal rejected an isolated signal'
	end, {deferred = true})

	local function probeFile(prefix)
		return 'pistonware/.'..prefix..'-'..tostring(os.time())..'-'..tostring(math.floor(os.clock() * 100000))
	end

	register('filesystem.writefile', function(value, restore)
		local writefile, reason = requireFunction(value, 'writefile')
		local readfile = value('readfile')
		local delfile = value('delfile')
		if not writefile then return false, reason end
		if type(readfile) ~= 'function' or type(delfile) ~= 'function' then
			return false, 'writefile cannot be safely verified without readfile and delfile'
		end
		local path = probeFile('capability-write')
		restore(function() if type(delfile) == 'function' then delfile(path) end end)
		local ok = pcall(writefile, path, 'pistonware-write-probe')
		local readOk, body = pcall(readfile, path)
		return ok and readOk and body == 'pistonware-write-probe', 'write/read round trip failed'
	end)

	register('filesystem.readfile', function(value, restore)
		local writefile = value('writefile')
		local readfile, reason = requireFunction(value, 'readfile')
		local delfile = value('delfile')
		if not readfile then return false, reason end
		if type(writefile) ~= 'function' or type(delfile) ~= 'function' then
			return false, 'readfile cannot be safely verified without writefile and delfile'
		end
		local path = probeFile('capability-read')
		restore(function() delfile(path) end)
		writefile(path, 'pistonware-read-probe')
		local ok, body = pcall(readfile, path)
		return ok and body == 'pistonware-read-probe', 'readfile returned the wrong body'
	end)

	register('filesystem.isfile', function(value, restore)
		local writefile = value('writefile')
		local isfile, reason = requireFunction(value, 'isfile')
		local delfile = value('delfile')
		if not isfile then return false, reason end
		if type(writefile) ~= 'function' or type(delfile) ~= 'function' then
			return false, 'isfile cannot be safely verified without writefile and delfile'
		end
		local path = probeFile('capability-isfile')
		restore(function() delfile(path) end)
		writefile(path, 'probe')
		local ok, present = pcall(isfile, path)
		return ok and present == true, 'isfile did not find the probe file'
	end)

	register('filesystem.appendfile', function(value, restore)
		local writefile = value('writefile')
		local readfile = value('readfile')
		local appendfile, reason = requireFunction(value, 'appendfile')
		local delfile = value('delfile')
		if not appendfile then return false, reason end
		if type(writefile) ~= 'function' or type(readfile) ~= 'function' or type(delfile) ~= 'function' then
			return false, 'appendfile cannot be safely verified without file round-trip functions'
		end
		local path = probeFile('capability-append')
		restore(function() delfile(path) end)
		writefile(path, 'first')
		local ok = pcall(appendfile, path, '-second')
		local readOk, body = pcall(readfile, path)
		return ok and readOk and body == 'first-second', 'appendfile produced the wrong body'
	end)

	register('filesystem.delfile', function(value)
		local writefile = value('writefile')
		local isfile = value('isfile')
		local delfile, reason = requireFunction(value, 'delfile')
		if not delfile then return false, reason end
		if type(writefile) ~= 'function' or type(isfile) ~= 'function' then
			return false, 'delfile cannot be verified without writefile and isfile'
		end
		local path = probeFile('capability-delete')
		writefile(path, 'probe')
		local ok = pcall(delfile, path)
		local checkOk, present = pcall(isfile, path)
		return ok and checkOk and present == false, 'delfile did not remove the probe file'
	end)

	register('filesystem.makefolder', function(value, restore)
		local makefolder, reason = requireFunction(value, 'makefolder')
		local isfolder = value('isfolder')
		local delfolder = value('delfolder')
		if not makefolder then return false, reason end
		if type(isfolder) ~= 'function' or type(delfolder) ~= 'function' then
			return false, 'makefolder cannot be safely verified without isfolder and delfolder'
		end
		local path = probeFile('capability-folder')
		restore(function() delfolder(path) end)
		local ok = pcall(makefolder, path)
		local checkOk, present = pcall(isfolder, path)
		return ok and checkOk and present == true, 'makefolder did not create the probe folder'
	end)

	register('filesystem.isfolder', function(value, restore)
		local makefolder = value('makefolder')
		local isfolder, reason = requireFunction(value, 'isfolder')
		local delfolder = value('delfolder')
		if not isfolder then return false, reason end
		if type(makefolder) ~= 'function' or type(delfolder) ~= 'function' then
			return false, 'isfolder cannot be safely verified without makefolder and delfolder'
		end
		local path = probeFile('capability-isfolder')
		restore(function() delfolder(path) end)
		makefolder(path)
		local ok, present = pcall(isfolder, path)
		return ok and present == true, 'isfolder did not find the probe folder'
	end)

	register('filesystem.listfiles', function(value, restore)
		local makefolder = value('makefolder')
		local writefile = value('writefile')
		local listfiles, reason = requireFunction(value, 'listfiles')
		local delfile = value('delfile')
		local delfolder = value('delfolder')
		if not listfiles then return false, reason end
		if type(makefolder) ~= 'function' or type(writefile) ~= 'function'
			or type(delfile) ~= 'function' or type(delfolder) ~= 'function' then
			return false, 'listfiles cannot be safely verified without folder cleanup functions'
		end
		local path = probeFile('capability-list')
		local file = path..'/probe.txt'
		restore(function() delfile(file) delfolder(path) end)
		makefolder(path)
		writefile(file, 'probe')
		local ok, files = pcall(listfiles, path)
		if not ok or type(files) ~= 'table' then return false, 'listfiles returned no table' end
		for _, candidate in files do
			if type(candidate) == 'string' then
				local normalized = candidate:gsub('\\', '/'):gsub('^%./', '')
				if normalized == file or normalized == 'probe.txt'
					or normalized:sub(-#file - 1) == '/'..file then
					return true
				end
			end
		end
		return false, 'listfiles did not return the probe file'
	end)

	register('filesystem.delfolder', function(value)
		local makefolder = value('makefolder')
		local isfolder = value('isfolder')
		local delfolder, reason = requireFunction(value, 'delfolder')
		if not delfolder then return false, reason end
		if type(makefolder) ~= 'function' or type(isfolder) ~= 'function' then
			return false, 'delfolder cannot be verified without makefolder and isfolder'
		end
		local path = probeFile('capability-delfolder')
		makefolder(path)
		local ok = pcall(delfolder, path)
		local checkOk, present = pcall(isfolder, path)
		return ok and checkOk and present == false, 'delfolder did not remove the probe folder'
	end)

	register('runtime.cloneref', function(value)
		local cloneref, reason = requireFunction(value, 'cloneref')
		if not cloneref then return false, reason end
		if not gameObject then return false, 'missing game object' end
		local service = gameObject:GetService('Players')
		local ok, clone = pcall(cloneref, service)
		local readOk = ok and pcall(function() return clone.LocalPlayer end)
		return ok and clone ~= nil and readOk, 'cloneref returned an unusable reference'
	end)

	register('runtime.gethui', function(value)
		local gethui, reason = requireFunction(value, 'gethui')
		if not gethui then return false, reason end
		local ok, result = pcall(gethui)
		return ok and result ~= nil and type(result.GetChildren) == 'function', 'gethui returned no container'
	end)

	register('runtime.drawing', function(value)
		local drawing = value('Drawing')
		if type(drawing) ~= 'table' or type(drawing.new) ~= 'function' then return false, 'missing Drawing.new' end
		local ok, object = pcall(drawing.new, 'Line')
		if not ok or object == nil then return false, 'Drawing.new failed' end
		local configured = pcall(function() object.Visible = false end)
		local removed = pcall(function() object:Remove() end)
		return configured and removed, 'Drawing object could not be configured and removed'
	end)

	for _, id in {
		'runtime.getcustomasset', 'runtime.networkowner', 'runtime.windowactive',
		'input.mouse', 'input.touch', 'input.proximity', 'http.gameget', 'http.request',
		'clipboard.read', 'clipboard.write', 'teleport.queue', 'script.decompile'
	} do
		register(id, function()
			return false, 'requires an explicit first-use or live-runtime probe'
		end, {deferred = true})
	end

	groups.DEBUG = {
		'debug.getconstant', 'debug.getconstants', 'debug.getinfo', 'debug.getproto',
		'debug.getprotos', 'debug.getstack', 'debug.getupvalue', 'debug.getupvalues',
		'debug.setconstant', 'debug.setstack', 'debug.setupvalue'
	}
	groups.HOOKFUNCTION = {'hookfunction', 'restorefunction'}
	groups.METATABLE = {'metatable.getraw.table', 'metatable.setraw'}
	groups.METAMETHOD = {'metatable.hook.instance', 'namecall.getmethod'}
	groups.THREAD = {'thread.getidentity', 'thread.setidentity', 'thread.restore'}
	groups.SIGNAL = {'signal.getconnections', 'signal.fire'}
	groups.GC = {'gc.get.functions', 'gc.get.tables', 'closure.islua'}
	groups.SCRIPT = {'script.getenvironment', 'script.getbytecode', 'script.getclosure'}
	groups.REPLICATION = {'signal.replicate'}

	local capabilities = {schema = SCHEMA, flags = flags, results = results}

	function capabilities:run()
		for _, id in order do
			if not probes[id].deferred then execute(id) end
		end
		local exec = type(environment.exec) == 'table' and environment.exec or {}
		environment.exec = exec
		for name in groups do exec[name] = self:has(name) end
		return self:snapshot()
	end

	function capabilities:verify(id)
		return execute(id)
	end

	function capabilities:has(id)
		local group = groups[id]
		if group then
			for _, child in group do if flags[child] ~= true then return false end end
			return true
		end
		return flags[id] == true
	end

	function capabilities:evaluate(required)
		local visiting = {}
		local function evaluate(node)
			if type(node) == 'string' then
				if self:has(node) then return true, {} end
				return false, {node}
			end
			if type(node) ~= 'table' or visiting[node] then
				return false, {'invalid capability requirement'}
			end
			visiting[node] = true
			local any = node.AnyOf ~= nil
			local children = any and node.AnyOf or node.AllOf or node
			if type(children) ~= 'table' or (any and node.AllOf ~= nil) then
				visiting[node] = nil
				return false, {'invalid capability expression'}
			end
			local count = 0
			for key in children do
				if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then
					visiting[node] = nil
					return false, {'capability requirements must be a list'}
				end
				count += 1
			end
			for index = 1, count do
				if children[index] == nil then
					visiting[node] = nil
					return false, {'capability requirements must be a dense list'}
				end
			end
			local missing = {}
			for index = 1, count do
				local supported, reasons = evaluate(children[index])
				if any and supported then
					visiting[node] = nil
					return true, {}
				end
				if not supported then
					for _, reason in reasons do
						missing[#missing + 1] = reason
					end
				end
			end
			visiting[node] = nil
			if any then
				return false, {
					count == 0 and 'AnyOf has no alternatives'
						or 'any of ('..table.concat(missing, '; ')..')'
				}
			end
			return #missing == 0, missing
		end
		return evaluate(required)
	end

	function capabilities:require(scope, required)
		local supported, missing = self:evaluate(required)
		if supported then return true end
		local message = tostring(scope)..' requires: '..table.concat(missing, ', ')
		bufferCall('warn', 'executor.unsupported', message, {
			scope = tostring(scope),
			missing = table.concat(missing, ',')
		})
		if type(adapter.onMissing) == 'function' then pcall(adapter.onMissing, scope, missing, message) end
		return false, missing
	end

	function capabilities:observe(id, supported, reason, details)
		assert(probes[id] ~= nil, 'capability is not registered: '..tostring(id))
		supported = supported == true
		flags[id] = supported
		results[id] = {
			status = supported and 'passed' or 'failed',
			reason = tostring(reason or (supported and 'behavior observed' or 'behavior failed')),
			details = type(details) == 'table' and details or nil
		}
		bufferCall(supported and 'print' or 'warn', 'executor.capability',
			id..': '..(supported and 'PASS' or 'FAIL'), {
				reason = results[id].reason,
				observed = true
			})
		return supported
	end

	function capabilities:result(id)
		return results[id]
	end

	function capabilities:snapshot()
		local snapshot = {}
		for id, result in results do
			snapshot[id] = {
				supported = flags[id] == true,
				status = result.status,
				reason = result.reason,
				duration = result.duration,
				details = result.details
			}
		end
		return snapshot
	end

	return capabilities
end
