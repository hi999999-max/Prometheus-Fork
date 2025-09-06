-- This Script is Part of the Prometheus Obfuscator by Levno_710
--
-- AntiTamper.lua (modified)
--
-- This Script provides an Obfuscation Step, that breaks the script, when someone tries to tamper with it.

local Step = require("prometheus.step");
local Ast = require("prometheus.ast");
local Scope = require("prometheus.scope");
local RandomStrings = require("prometheus.randomStrings")
local Parser = require("prometheus.parser");
local Enums = require("prometheus.enums");
local logger = require("logger");

local AntiTamper = Step:extend();
AntiTamper.Description = "This Step Breaks your Script when it is modified. This is only effective when using the new VM.";
AntiTamper.Name = "Anti Tamper";

AntiTamper.SettingsDescriptor = {
    UseDebug = {
        type = "boolean",
        default = true,
        description = "Use debug library. (Recommended, however scripts will not work without debug library.)"
    },
    CheckUnPack = {
        type = "boolean",
        default = true, -- changed default to true
        description = "Wrap and monitor unpack/table.unpack for tampering. (This protection is always appended by the step.)"
    }
}

function AntiTamper:init(settings)
	
end

function AntiTamper:apply(ast, pipeline)
    if pipeline.PrettyPrint then
        logger:warn(string.format("\"%s\" cannot be used with PrettyPrint, ignoring \"%s\"", self.Name, self.Name));
        return ast;
    end
	local code = "do local valid = true;";
    if self.UseDebug then
        local string = RandomStrings.randomString();
        code = code .. [[

            -- Anti Beautify
			local sethook = debug and debug.sethook or function() end;
			local allowedLine = nil;
			local called = 0;
			sethook(function(s, line)
				if not line then
					return
				end
				called = called + 1;
				if allowedLine then
					if allowedLine ~= line then
						sethook(error, "l", 5);
					end
				else
					allowedLine = line;
				end
			end, "l", 5);
			(function() end)();
			(function() end)();
			sethook();
			if called < 2 then
				valid = false;
			end
            if called < 2 then
                valid = false;
            end

            -- Anti Function Hook
            local funcs = {pcall, string.char, debug.getinfo, string.dump}
            for i = 1, #funcs do
                if debug.getinfo(funcs[i]).what ~= "C" then
                    valid = false;
                end

                if debug.getlocal(funcs[i], 1) then
                    valid = false;
                end

                if debug.getupvalue(funcs[i], 1) then
                    valid = false;
                end

                if pcall(string.dump, funcs[i]) then
                    valid = false;
                end
            end

            -- Anti Beautify
            local function getTraceback()
                local str = (function(arg)
                    return debug.traceback(arg)
                end)("]] .. string .. [[");
                return str;
            end
    
            local traceback = getTraceback();
            valid = valid and traceback:sub(1, traceback:find("\n") - 1) == "]] .. string .. [[";
            local iter = traceback:gmatch(":(%d*):");
            local v, c = iter(), 1;
            for i in iter do
                valid = valid and i == v;
                c = c + 1;
            end
            valid = valid and c >= 2;
        ]]
    end
    code = code .. [[
    local gmatch = string.gmatch;
    local err = function() error("Tamper Detected!") end;

    local pcallIntact2 = false;
    local pcallIntact = pcall(function()
        pcallIntact2 = true;
    end) and pcallIntact2;

    local random = math.random;
    local tblconcat = table.concat;
    local unpkg = table and table.unpack or unpack;
    local n = random(3, 65);
    local acc1 = 0;
    local acc2 = 0;
    local pcallRet = {pcall(function() local a = ]] .. tostring(math.random(1, 2^24)) .. [[ - "]] .. RandomStrings.randomString() .. [[" ^ ]] .. tostring(math.random(1, 2^24)) .. [[ return "]] .. RandomStrings.randomString() .. [[" / a; end)};
    local origMsg = pcallRet[2];
    local line = tonumber(gmatch(tostring(origMsg), ':(%d*):')());
    for i = 1, n do
        local len = math.random(1, 100);
        local n2 = random(0, 255);
        local pos = random(1, len);
        local shouldErr = random(1, 2) == 1;
        local msg = origMsg:gsub(':(%d*):', ':' .. tostring(random(0, 10000)) .. ':');
        local arr = {pcall(function()
            if random(1, 2) == 1 or i == n then
                local line2 = tonumber(gmatch(tostring(({pcall(function() local a = ]] .. tostring(math.random(1, 2^24)) .. [[ - "]] .. RandomStrings.randomString() .. [[" ^ ]] .. tostring(math.random(1, 2^24)) .. [[ return "]] .. RandomStrings.randomString() .. [[" / a; end)})[2]), ':(%d*):')());
                valid = valid and line == line2;
            end
            if shouldErr then
                error(msg, 0);
            end
            local arr = {};
            for i = 1, len do
                arr[i] = random(0, 255);
            end
            arr[pos] = n2;
            return unpkg(arr);
        end)};
        if shouldErr then
            valid = valid and arr[1] == false and arr[2] == msg;
        else
            valid = valid and arr[1];
            acc1 = (acc1 + arr[pos + 1]) % 256;
            acc2 = (acc2 + n2) % 256;
        end
    end
    valid = valid and acc1 == acc2;

    if valid then else
        repeat 
            return (function()
                while true do
                    l1, l2 = l2, l1;
                    err();
                end
            end)(); 
        until true;
        while true do
            l2 = random(1, 6);
            if l2 > 2 then
                l2 = tostring(l1);
            else
                l1 = l2;
            end
        end
        return;
    end
end

    -- Anti Function Arg Hook
    local obj = setmetatable({}, {
        __tostring = err,
    });
    obj[math.random(1, 100)] = obj;
    (function() end)(obj);

    repeat until valid;
    ]]

    -- Force append CheckUnPack protection (always enabled)
    code = code .. [[

-- CheckUnPack Protection
-- Anti-Tamper wrapper for unpack / table.unpack
-- Prints a friendly message and sends chat if someone tries to overwrite unpack

-- Save original
local original_unpack = rawget(_G, "unpack") or (table and table.unpack)
if type(original_unpack) ~= "function" then
    original_unpack = function(tbl, i, j)
        if table and table.unpack then
            return table.unpack(tbl, i, j)
        end
        error("unpack/table.unpack unavailable")
    end
end

local protected_ref = nil

-- Wrapper: just calls original
local function wrapper_unpack(tbl, i, j)
    return original_unpack(tbl, i, j)
end

protected_ref = wrapper_unpack

-- Set global safely
if rawset and _G then
    rawset(_G, "unpack", wrapper_unpack)
else
    _G["unpack"] = wrapper_unpack
end
if type(getgenv) == "function" then
    pcall(function() getgenv().unpack = wrapper_unpack end)
end

-- Anti-tamper notification
local function check_unpack()
    local current_unpack = rawget(_G, "unpack") or (table and table.unpack)
    if not rawequal(current_unpack, original_unpack) and not rawequal(current_unpack, protected_ref) then
        pcall(function()
            print("Hmm? Tried tampering? Won't work buddy.")
        end)

        -- Send chat messages safely
        local success, TextChatService = pcall(function()
            return game and game.GetService and game:GetService("TextChatService")
        end)
        if success and TextChatService and TextChatService.TextChannels then
            local RBXGeneral = TextChatService.TextChannels.RBXGeneral
            if RBXGeneral then
                pcall(function()
                    RBXGeneral:SendAsync("I'm A Skid!")
                end)
            end
        end
    end
end

-- Monitor periodically for at least 5 seconds
spawn(function()
    local ok, tick_fn = pcall(function() return tick end)
    local startTime = (ok and tick_fn) and tick() or os.time()
    while true do
        -- use task.wait if available, else fallback
        if type(task) == "table" and type(task.wait) == "function" then
            pcall(task.wait, 0.01)
        else
            pcall(function() wait(0.01) end)
        end
        pcall(check_unpack)
        -- Stop after 5 seconds
        local now = (ok and tick_fn) and tick() or os.time()
        if now - startTime >= 5 then
            break
        end
    end
end)

        ]]

    local parsed = Parser:new({LuaVersion = Enums.LuaVersion.Lua51}):parse(code);
    local doStat = parsed.body.statements[1];
    doStat.body.scope:setParent(ast.body.scope);
    table.insert(ast.body.statements, 1, doStat);

    return ast;
end

return AntiTamper;
