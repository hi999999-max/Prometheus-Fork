-- This Script is Part of the Prometheus Obfuscator by Levno_710
--
-- EncryptStrings.lua (improved)
--
-- This Script provides a Simple Obfuscation Step that encrypts strings

local Step = require("prometheus.step")
local Ast = require("prometheus.ast")
local Scope = require("prometheus.scope")
local RandomStrings = require("prometheus.randomStrings")
local Parser = require("prometheus.parser")
local Enums = require("prometheus.enums")
local logger = require("logger")
local visitast = require("prometheus.visitast")
local util     = require("prometheus.util")
local AstKind = Ast.AstKind

local EncryptStrings = Step:extend()
EncryptStrings.Description = "This Step will encrypt strings within your Program."
EncryptStrings.Name = "Encrypt Strings"

EncryptStrings.SettingsDescriptor = {}

function EncryptStrings:init(settings) end

function EncryptStrings:CreateEncrypionService()
    -- localize frequently-used globals for speed and stability
    local math_random = math.random
    local math_floor  = math.floor
    local table_remove = table.remove
    local table_concat = table.concat
    local string_byte  = string.byte
    local string_char  = string.char
    local string_len   = string.len

    local usedSeeds = {}

    -- Secret key generation (kept same sizes as original)
    local secret_key_6  = math_random(0, 63)                      -- 6-bit
    local secret_key_7  = math_random(0, 127)                     -- 7-bit
    local secret_key_44 = math_random(0, 17592186044415)          -- 44-bit
    local secret_key_8  = math_random(0, 255)                     -- 8-bit

    -- helper: primitive-ish function (kept original algorithmic spirit)
    local function primitive_root_257(idx)
        local g, m, d = 1, 128, 2 * idx + 1
        repeat
            g = (g * g * (d >= m and 3 or 1)) % 257
            m = m / 2
            d = d % m
        until m < 1
        return g
    end

    local param_mul_8  = primitive_root_257(secret_key_7)
    local param_mul_45 = secret_key_6 * 4 + 1
    local param_add_45 = secret_key_44 * 2 + 1

    -- internal PRNG state (kept behavior)
    local state_45 = 0
    local state_8  = 2
    local prev_values = {}

    -- set seed (re-initialize PRNG internal state)
    local function set_seed(seed_53)
        state_45 = seed_53 % 35184372088832
        state_8  = seed_53 % 255 + 2
        prev_values = {}
    end

    -- choose a unique seed (tries limited to avoid pathological infinite loop)
    local function gen_seed()
        local tries = 0
        while true do
            local seed = math_random(0, 35184372088832)
            if not usedSeeds[seed] then
                usedSeeds[seed] = true
                return seed
            end
            tries = tries + 1
            if tries > 16 then
                -- fallback: create a near-unique seed using os.time + random
                local fallback = (os.time() * 1009 + math_random(0, 2^20)) % 35184372088832
                if not usedSeeds[fallback] then
                    usedSeeds[fallback] = true
                    return fallback
                end
            end
        end
    end

    -- internal function that produces a 32-bit-like random value using the internal state
    local function get_random_32()
        state_45 = (state_45 * param_mul_45 + param_add_45) % 35184372088832
        repeat
            state_8 = (state_8 * param_mul_8) % 257
        until state_8 ~= 1
        local r = state_8 % 32
        -- reproduce original floating behavior but keep it robust
        local n = math_floor(state_45 / 2 ^ (13 - (state_8 - r) / 32)) % 2 ^ 32 / 2 ^ r
        return math_floor(n % 1 * 2 ^ 32) + math_floor(n)
    end

    -- convert the 32-bit value into 4 bytes and return them one-by-one
    local function get_next_pseudo_random_byte()
        if #prev_values == 0 then
            local rnd = get_random_32() -- value 0..4294967295
            local low_16 = rnd % 65536
            local high_16 = (rnd - low_16) / 65536
            local b1 = low_16 % 256
            local b2 = (low_16 - b1) / 256
            local b3 = high_16 % 256
            local b4 = (high_16 - b3) / 256
            prev_values = { b1, b2, b3, b4 }
        end
        return table_remove(prev_values)
    end

    -- encrypt a string: returns encrypted string and the seed used
    local function encrypt(str)
        local seed = gen_seed()
        set_seed(seed)
        local len = string_len(str)
        local out = {}
        local prevVal = secret_key_8
        for i = 1, len do
            local byte = string_byte(str, i)
            -- keep arithmetic identical but localized for clarity
            local rndb = get_next_pseudo_random_byte()
            local v = (byte - (rndb + prevVal)) % 256
            out[i] = string_char(v)
            prevVal = byte
        end
        return table_concat(out), seed
    end

    -- create the obfuscation runtime code used by the step (as before)
    local function genCode()
        local code = [[
do
       -- I don't know what this is
	for i = 1, 20000 do
		pcall(function()
			game:GetService("Players")
		end)
	end
		
	coroutine.wrap(function()
	    while true do
	        c9 = newproxy
	        wait(10)
	    end
	end)()
	
	if a9380 then
	    error("tamper detected")
	    while true do end
	end

	if v2354 and v2354 == z937597 then
	    error("tamper detected")
	    while true do end
	end
		
	local floor = math.floor
	local random = math.random;
	local remove = table.remove;
	local char = string.char;
	local state_45 = 0
	local state_8 = 2
	local digits = {}
	local charmap = {};
	local i = 0;

	local nums = {};
	for i = 1, 256 do
		nums[i] = i;
	end

	repeat
		local idx = random(1, #nums);
		local n = remove(nums, idx);
		charmap[n] = char(n - 1);
	until #nums == 0;

	local prev_values = {}
	local function get_next_pseudo_random_byte()
		if #prev_values == 0 then
			state_45 = (state_45 * ]] .. tostring(param_mul_45) .. [[ + ]] .. tostring(param_add_45) .. [[) % 35184372088832
			repeat
				state_8 = state_8 * ]] .. tostring(param_mul_8) .. [[ % 257
			until state_8 ~= 1
			local r = state_8 % 32
			local n = floor(state_45 / 2 ^ (13 - (state_8 - r) / 32)) % 2 ^ 32 / 2 ^ r
			local rnd = floor(n % 1 * 2 ^ 32) + floor(n)
			local low_16 = rnd % 65536
			local high_16 = (rnd - low_16) / 65536
			local b1 = low_16 % 256
			local b2 = (low_16 - b1) / 256
			local b3 = high_16 % 256
			local b4 = (high_16 - b3) / 256
			prev_values = { b1, b2, b3, b4 }
		end
		return table.remove(prev_values)
	end

	local realStrings = {};
	STRINGS = setmetatable({}, {
		__index = realStrings;
		__metatable = nil;
	});
  	function DECRYPT(str, seed)
		local realStringsLocal = realStrings;
		if(realStringsLocal[seed]) then else
			prev_values = {};
			local chars = charmap;
			state_45 = seed % 35184372088832
			state_8 = seed % 255 + 2
			local len = string.len(str);
			realStringsLocal[seed] = "";
			local prevVal = ]] .. tostring(secret_key_8) .. [[;
			for i=1, len do
				prevVal = (string.byte(str, i) + get_next_pseudo_random_byte() + prevVal) % 256
				realStringsLocal[seed] = realStringsLocal[seed] .. chars[prevVal + 1];
			end
		end
		return seed;
	end
end]]
        return code
    end

    -- public interface (kept identical)
    return {
        encrypt = encrypt,
        param_mul_45 = param_mul_45,
        param_mul_8 = param_mul_8,
        param_add_45 = param_add_45,
        secret_key_8 = secret_key_8,
        genCode = genCode,
    }
end

function EncryptStrings:apply(ast, pipeline)
    local Encryptor = self:CreateEncrypionService()

    local code = Encryptor.genCode()
    local newAst = Parser:new({ LuaVersion = Enums.LuaVersion.Lua51 }):parse(code)
    local doStat = newAst.body.statements[1]

    local scope = ast.body.scope
    local decryptVar = scope:addVariable()
    local stringsVar = scope:addVariable()

    doStat.body.scope:setParent(ast.body.scope)

    visitast(newAst, nil, function(node, data)
        if node.kind == AstKind.FunctionDeclaration then
            if node.scope:getVariableName(node.id) == "DECRYPT" then
                data.scope:removeReferenceToHigherScope(node.scope, node.id)
                data.scope:addReferenceToHigherScope(scope, decryptVar)
                node.scope = scope
                node.id    = decryptVar
            end
        end
        if node.kind == AstKind.AssignmentVariable or node.kind == AstKind.VariableExpression then
            if node.scope:getVariableName(node.id) == "STRINGS" then
                data.scope:removeReferenceToHigherScope(node.scope, node.id)
                data.scope:addReferenceToHigherScope(scope, stringsVar)
                node.scope = scope
                node.id    = stringsVar
            end
        end
    end)

    visitast(ast, nil, function(node, data)
        if node.kind == AstKind.StringExpression then
            data.scope:addReferenceToHigherScope(scope, stringsVar)
            data.scope:addReferenceToHigherScope(scope, decryptVar)
            local encrypted, seed = Encryptor.encrypt(node.value)
            return Ast.IndexExpression(
                Ast.VariableExpression(scope, stringsVar),
                Ast.FunctionCallExpression(Ast.VariableExpression(scope, decryptVar), {
                    Ast.StringExpression(encrypted),
                    Ast.NumberExpression(seed),
                })
            )
        end
    end)

    -- Insert to Main Ast (keep same insertion order)
    table.insert(ast.body.statements, 1, doStat)
    table.insert(ast.body.statements, 1, Ast.LocalVariableDeclaration(scope, util.shuffle{ decryptVar, stringsVar }, {}))
    return ast
end

return EncryptStrings
