--[[
Requirements:
hookfunction, newcclosure, iscclosure, getgc, getgenv
debug.info, Instance, task
]]

local oldgetgc; oldgetgc = hookfunction(getgc, newcclosure(function(...)
    print("getgc hooked")
    local gc = oldgetgc(...)
    for i, v in next, gc do
        if v == oldgetgc then
            table.remove(gc, i)
        end
    end
    return gc
end))

print(debug.info(oldgetgc, "n"))
print(debug.info(getgc, "n"))

local ref = function() end -- created a function
local address = tostring(ref) -- saved a non object reference

local gcEvent = Instance.new("BindableEvent")

local function isProbe(value)
    return ref ~= nil
        and type(value) == "function"
        and value == ref
        and tostring(value) == address
end

local function waitForGc(...)
    local gc
    local connection = gcEvent.Event:Connect(function(candidate)
        if gc == nil then
            gc = candidate
        end
    end)

    task.spawn(getgc, ...)

    local start = tick()
    repeat
        task.wait()
    until gc ~= nil or (tick() - start) > 3

    connection:Disconnect()
    return gc
end

local _next

local bypass = false
local realgc
local function bypassedgc(...)
    if realgc then
        return realgc(...)
    else
        return waitForGc(...)
    end
end

local function _getgc(...)
    if bypass then
        return bypassedgc(...)
    else
        return getgc(...)
    end
end

local restorefunction
local function findcclosure(name)
    return restorefunction(name, true)
end

local stupidbypass = {
    "replacefunction",
    "replacefunc",
    "detourfunction",
    "detour_function",
    "hookfunc",
    "hookfunction"
}
local hookfunction

for i, v in (_next or next), stupidbypass do
    local func = getgenv()[v]
    if type(func) == "function" and debug.info(func, "n") == v and iscclosure(func) then
        hookfunction = func
        break
    end
end

if hookfunction == nil then
    warn("severe hookfunction tampering detected, unlikely to bypass")
    hookfunction = getgenv().hookfunction -- give up if someone protected their hookfunction that much
end

local bypasses = {
    ["next"] = function()
        if findcclosure("next") == nil then
            return false
        end
        _next = hookfunction(next, function(t, ...)
            for i, v in _next, t do
                if isProbe(v) then
                    gcEvent:Fire(t)
                    return nil
                end
            end
            return _next(t, ...)
        end)
        if waitForGc() ~= nil then
            return true
        else
            hookfunction(next, _next)
            return false
        end
    end,
    ["pairs"] = function()
        if findcclosure("pairs") == nil then
            return false
        end
        local _pairs; _pairs = hookfunction(pairs, function(t, ...)
            for i, v in _pairs(t) do
                if isProbe(v) then
                    gcEvent:Fire(t)
                    return nil
                end
            end
            return _pairs(t, ...)
        end)
        if waitForGc() ~= nil then
            return true
        else
            hookfunction(pairs, _pairs)
            return false
        end
    end,
    ["table.find"] = function()
        local _table_find; _table_find = hookfunction(table.find, function(t, ...)
            for i, v in (_next or next), t do
                if isProbe(v) then
                    gcEvent:Fire(t)
                    return nil
                end
            end
            return _table_find(t, ...)
        end)
        if waitForGc() ~= nil then
            return true
        else
            hookfunction(table.find, _table_find)
            return false
        end
    end,
    ["table.remove"] = function()
        if findcclosure("remove") == nil then
            return false
        end
        local _table_remove; _table_remove = hookfunction(table.remove, function(t, ...)
            for i, v in (_next or next), t do
                if isProbe(v) then
                    gcEvent:Fire(t)
                    return nil
                end
            end
            return _table_remove(t, ...)
        end)
        if waitForGc() ~= nil then
            return true
        else
            hookfunction(table.remove, _table_remove)
            return false
        end
    end
}

restorefunction = function(name, cclosure)
    local gc = _getgc()
    if type(gc) ~= "table" then
        return nil
    end

    for _, func in (_next or next), gc do
        if type(func) == "function"
            and debug.info(func, "n") == name
            and (cclosure and iscclosure(func) or not cclosure) then
            return func
        end
    end
    return nil
end

local foundgc = restorefunction("getgc", true)
if foundgc == nil or foundgc == getgc then
    warn("no getgc found, testing bypasses")
    warn("retaining detectable object while testing bypasses")
    local weaktable = setmetatable({}, { __mode = "v" })
    weaktable[1] = ref
    for key, func in (_next or next), bypasses do
        print(`[{key}] bypassing...`)
        if func() then
            warn(`[{key}] bypassed gc hook`)
            bypass = true
            break
        end
    end
    if not bypass then
        warn("failed to bypass gc hook")
        ref = nil
        local start = tick()
        repeat
            task.wait()
        until weaktable[1] == nil or (tick() - start) > 3
    end
elseif foundgc ~= getgc then
    warn("bypassed gc tamper")
    bypass = true
    realgc = foundgc
end

print("restorefunction has been created")

getgenv().restorefunction = restorefunction
