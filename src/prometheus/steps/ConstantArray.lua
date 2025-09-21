-- This Script is Part of the Prometheus Obfuscator by Levno_710
--
-- ConstantArray.lua
--
-- This Script provides a Simple Obfuscation Step that wraps the entire Script into a function
-- (now with R2 encryption instead of ascii85)

-- --------------------------------------------------------
-- Bit32 Compatibility Layer for Lua 5.3+
-- Ensures bit32.* works even if not built-in.
-- --------------------------------------------------------
if not bit32 then
    bit32 = {}

    -- mask to 32 bits
    local function band32(x) return x & 0xFFFFFFFF end

    function bit32.bxor(a, b)
        return (a ~ b) & 0xFFFFFFFF
    end

    function bit32.band(a, b)
        return (a & b) & 0xFFFFFFFF
    end

    function bit32.bor(a, b)
        return (a | b) & 0xFFFFFFFF
    end

    function bit32.bnot(a)
        return (~a) & 0xFFFFFFFF
    end

    function bit32.lshift(a, b)
        return (a << b) & 0xFFFFFFFF
    end

    function bit32.rshift(a, b)
        return (a >> b) & 0xFFFFFFFF
    end

    function bit32.arshift(a, b)
        -- preserve sign bit when shifting
        if a & 0x80000000 ~= 0 then
            return ((a >> b) | (~0 << (32 - b))) & 0xFFFFFFFF
        else
            return (a >> b) & 0xFFFFFFFF
        end
    end
end

local Step = require("prometheus.step")
local Ast = require("prometheus.ast")
local Scope = require("prometheus.scope")
local visitast = require("prometheus.visitast")
local util = require("prometheus.util")
local Parser = require("prometheus.parser")
local enums = require("prometheus.enums")

local LuaVersion = enums.LuaVersion
local AstKind = Ast.AstKind

local ConstantArray = Step:extend()
ConstantArray.Description =
    "This Step will Extract all Constants and put them into an Array at the beginning of the script"
ConstantArray.Name = "Constant Array"

ConstantArray.SettingsDescriptor = {
    Treshold = {
        name = "Treshold",
        description = "The relative amount of nodes that will be affected",
        type = "number",
        default = 1,
        min = 0,
        max = 1
    },
    StringsOnly = {
        name = "StringsOnly",
        description = "Wether to only Extract Strings",
        type = "boolean",
        default = true
    },
    Shuffle = {
        name = "Shuffle",
        description = "Wether to shuffle the order of Elements in the Array",
        type = "boolean",
        default = true
    },
    Rotate = {
        name = "Rotate",
        description = "Wether to rotate the String Array by a specific (random) amount. This will be undone on runtime.",
        type = "boolean",
        default = true
    },
    LocalWrapperTreshold = {
        name = "LocalWrapperTreshold",
        description = "The relative amount of nodes functions, that will get local wrappers",
        type = "number",
        default = 1,
        min = 0,
        max = 1
    },
    LocalWrapperCount = {
        name = "LocalWrapperCount",
        description = "The number of Local wrapper Functions per scope. This only applies if LocalWrapperTreshold is greater than 0",
        type = "number",
        min = 0,
        max = 512,
        default = 333
    },
    LocalWrapperArgCount = {
        name = "LocalWrapperArgCount",
        description = "The number of Arguments to the Local wrapper Functions",
        type = "number",
        min = 1,
        default = 192,
        max = 200
    },
    MaxWrapperOffset = {
        name = "MaxWrapperOffset",
        description = "The Max Offset for the Wrapper Functions",
        type = "number",
        min = 0,
        default = 65535
    },
    Encoding = {
        name = "Encoding",
        description = "The Encoding to use for the Strings",
        type = "enum",
        default = "r2",
        values = {"none", "r2", "base32"}
    }
}

------------------------
-- Helpers
------------------------
local base64alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function r2_encode(str, key)
    local out = {}
    key = key or 77
    for i = 1, #str do
        local b = string.byte(str, i)
        local enc = bit32.bxor(b, key)
        out[#out + 1] = base64alphabet:sub((enc % 64) + 1, (enc % 64) + 1)
    end
    return table.concat(out)
end

------------------------
-- Step Implementation
------------------------

local function callNameGenerator(generatorFunction, ...)
    if (type(generatorFunction) == "table") then
        generatorFunction = generatorFunction.generateName
    end
    return generatorFunction(...)
end

function ConstantArray:init(settings)
    -- Placeholder init
end

function ConstantArray:createArray()
    local entries = {}
    for i, v in ipairs(self.constants) do
        if type(v) == "string" then
            v = self:encode(v)
        end
        entries[i] = Ast.TableEntry(Ast.ConstantNode(v))
    end
    return Ast.TableConstructorExpression(entries)
end

function ConstantArray:indexing(index, data)
    if self.LocalWrapperCount > 0 and data.functionData.local_wrappers then
        local wrappers = data.functionData.local_wrappers
        local wrapper = wrappers[math.random(#wrappers)]

        local args = {}
        local ofs = index - self.wrapperOffset - wrapper.offset
        for i = 1, self.LocalWrapperArgCount, 1 do
            if i == wrapper.arg then
                args[i] = Ast.NumberExpression(ofs)
            else
                args[i] = Ast.NumberExpression(math.random(ofs - 1024, ofs + 1024))
            end
        end

        data.scope:addReferenceToHigherScope(wrappers.scope, wrappers.id)
        return Ast.FunctionCallExpression(
            Ast.IndexExpression(Ast.VariableExpression(wrappers.scope, wrappers.id), Ast.StringExpression(wrapper.index)),
            args
        )
    else
        data.scope:addReferenceToHigherScope(self.rootScope, self.wrapperId)
        return Ast.FunctionCallExpression(Ast.VariableExpression(self.rootScope, self.wrapperId), {
            Ast.NumberExpression(index - self.wrapperOffset)
        })
    end
end

function ConstantArray:getConstant(value, data)
    if (self.lookup[value]) then
        return self:indexing(self.lookup[value], data)
    end
    local idx = #self.constants + 1
    self.constants[idx] = value
    self.lookup[value] = idx
    return self:indexing(idx, data)
end

function ConstantArray:addConstant(value)
    if (self.lookup[value]) then
        return
    end
    local idx = #self.constants + 1
    self.constants[idx] = value
    self.lookup[value] = idx
end

------------------------
-- Rotate Helpers
------------------------
local function reverse(t, i, j)
    while i < j do
        t[i], t[j] = t[j], t[i]
        i, j = i + 1, j - 1
    end
end

local function rotate(t, d, n)
    n = n or #t
    d = (d or 1) % n
    reverse(t, 1, n)
    reverse(t, 1, d)
    reverse(t, d + 1, n)
end

local rotateCode = [=[
	for i, v in ipairs({{1, LEN}, {1, SHIFT}, {SHIFT + 1, LEN}}) do
		while v[1] < v[2] do
			ARR[v[1]], ARR[v[2]], v[1], v[2] = ARR[v[2]], ARR[v[1]], v[1] + 1, v[2] - 1
		end
	end
]=]

------------------------
-- Decoder Injection
------------------------
function ConstantArray:addRotateCode(ast, shift)
    local parser = Parser:new({LuaVersion = LuaVersion.Lua51})
    local newAst = parser:parse(
        string.gsub(string.gsub(rotateCode, "SHIFT", tostring(shift)), "LEN", tostring(#self.constants))
    )
    local forStat = newAst.body.statements[1]
    forStat.body.scope:setParent(ast.body.scope)
    visitast(
        newAst,
        nil,
        function(node, data)
            if (node.kind == AstKind.VariableExpression) then
                if (node.scope:getVariableName(node.id) == "ARR") then
                    data.scope:removeReferenceToHigherScope(node.scope, node.id)
                    data.scope:addReferenceToHigherScope(self.rootScope, self.arrId)
                    node.scope = self.rootScope
                    node.id = self.arrId
                end
            end
        end
    )
    table.insert(ast.body.statements, 1, forStat)
end

function ConstantArray:addDecodeCode(ast)
    if not self.Encoding or self.Encoding == "none" then
        return
    end

    if self.Encoding == "r2" then
        local r2DecodeCode = [[
    do
        local arr = ARR
        local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        local lookup = {}
        for i = 1, #alphabet do
            lookup[alphabet:sub(i,i)] = i - 1
        end
        local function r2_decode(str, key)
            key = key or 77
            local out = {}
            for i = 1, #str do
                local ch = str:sub(i,i)
                local val = lookup[ch] or 0
                local dec = bit32.bxor(val, key)
                out[#out+1] = string.char(dec)
            end
            return table.concat(out)
        end
        for i = 1, #arr do
            if type(arr[i]) == "string" then
                arr[i] = r2_decode(arr[i], 77)
            end
        end
    end
    ]]

        local parser = Parser:new({LuaVersion = LuaVersion.Lua51})
        local newAst = parser:parse(r2DecodeCode)
        local forStat = newAst.body.statements[1]
        forStat.body.scope:setParent(ast.body.scope)

        visitast(
            newAst,
            nil,
            function(node, data)
                if node.kind == AstKind.VariableExpression then
                    if node.scope:getVariableName(node.id) == "ARR" then
                        data.scope:removeReferenceToHigherScope(node.scope, node.id)
                        data.scope:addReferenceToHigherScope(self.rootScope, self.arrId)
                        node.scope = self.rootScope
                        node.id = self.arrId
                    end
                end
            end
        )

        table.insert(ast.body.statements, 1, forStat)
        return
    end

    if self.Encoding == "base32" then
        -- leaving your base32 logic intact
        local base32DecodeCode = [[
    do
        local arr = ARR;
        local function base32_decode(s)
            s = s:gsub("%s", ""):gsub("=", "");
            local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
            local buffer = 0;
            local bits_left = 0;
            local out = {};
            for i = 1, #s do
                local ch = s:sub(i, i):upper();
                local val = alphabet:find(ch, 1, true);
                if val then
                    val = val - 1;
                    buffer = buffer * 32 + val;
                    bits_left = bits_left + 5;
                    while bits_left >= 8 do
                        bits_left = bits_left - 8;
                        local byte = math.floor(buffer / (2 ^ bits_left)) % 256;
                        table.insert(out, string.char(byte));
                        buffer = buffer % (2 ^ bits_left);
                    end
                end
            end
            return table.concat(out);
        end
        for i = 1, #arr do
            if type(arr[i]) == "string" then
                arr[i] = base32_decode(arr[i]);
            end
        end
    end
    ]]

        local parser = Parser:new({LuaVersion = LuaVersion.Lua51})
        local newAst = parser:parse(base32DecodeCode)
        local forStat = newAst.body.statements[1]
        forStat.body.scope:setParent(ast.body.scope)

        visitast(
            newAst,
            nil,
            function(node, data)
                if node.kind == AstKind.VariableExpression then
                    if node.scope:getVariableName(node.id) == "ARR" then
                        data.scope:removeReferenceToHigherScope(node.scope, node.id)
                        data.scope:addReferenceToHigherScope(self.rootScope, self.arrId)
                        node.scope = self.rootScope
                        node.id = self.arrId
                    end
                end
            end
        )
        table.insert(ast.body.statements, 1, forStat)
        return
    end
end

------------------------
-- Encoding
------------------------
function ConstantArray:encode(str)
    if self.Encoding == "r2" then
        return r2_encode(str, 77)
    end
    -- fallback to base32 (your original code)
    if self.Encoding == "base32" then
        local function base32_encode(data)
            local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
            local out = {}
            local buffer = 0
            local bits_left = 0
            for i = 1, #data do
                buffer = buffer * 256 + string.byte(data, i)
                bits_left = bits_left + 8
                while bits_left >= 5 do
                    bits_left = bits_left - 5
                    local idx = math.floor(buffer / (2 ^ bits_left)) % 32
                    out[#out + 1] = alphabet:sub(idx + 1, idx + 1)
                    buffer = buffer % (2 ^ bits_left)
                end
            end
            if bits_left > 0 then
                local idx = math.floor(buffer * (2 ^ (5 - bits_left))) % 32
                out[#out + 1] = alphabet:sub(idx + 1, idx + 1)
            end
            return table.concat(out)
        end
        return base32_encode(str)
    end
    return str
end

------------------------
-- Apply
------------------------
function ConstantArray:apply(ast, pipeline)
    self.rootScope = ast.body.scope
    self.arrId = self.rootScope:addVariable()

    self.constants = {}
    self.lookup = {}

    -- Extract Constants
    visitast(
        ast,
        nil,
        function(node, data)
            if math.random() <= self.Treshold then
                node.__apply_constant_array = true
                if node.kind == AstKind.StringExpression then
                    self:addConstant(node.value)
                elseif not self.StringsOnly then
                    if node.isConstant and node.value ~= nil then
                        self:addConstant(node.value)
                    end
                end
            end
        end
    )

    -- Shuffle Array
    if self.Shuffle then
        self.constants = util.shuffle(self.constants)
        self.lookup = {}
        for i, v in ipairs(self.constants) do
            self.lookup[v] = i
        end
    end

    -- Wrapper Setup
    self.wrapperOffset = math.random(-self.MaxWrapperOffset, self.MaxWrapperOffset)
    self.wrapperId = self.rootScope:addVariable()

    visitast(
        ast,
        function(node, data)
            if
                self.LocalWrapperCount > 0 and node.kind == AstKind.Block and node.isFunctionBlock and
                    math.random() <= self.LocalWrapperTreshold
             then
                local id = node.scope:addVariable()
                data.functionData.local_wrappers = {
                    id = id,
                    scope = node.scope
                }
                local nameLookup = {}
                for i = 1, self.LocalWrapperCount, 1 do
                    local name
                    repeat
                        name = callNameGenerator(pipeline.namegenerator, math.random(1, self.LocalWrapperArgCount * 16))
                    until not nameLookup[name]
                    nameLookup[name] = true

                    local offset = math.random(-self.MaxWrapperOffset, self.MaxWrapperOffset)
                    local argPos = math.random(1, self.LocalWrapperArgCount)

                    data.functionData.local_wrappers[i] = {
                        arg = argPos,
                        index = name,
                        offset = offset
                    }
                    data.functionData.__used = false
                end
            end
            if node.__apply_constant_array then
                data.functionData.__used = true
            end
        end,
        function(node, data)
            if node.__apply_constant_array then
                if node.kind == AstKind.StringExpression then
                    return self:getConstant(node.value, data)
                elseif not self.StringsOnly then
                    if node.isConstant and node.value ~= nil then
                        return self:getConstant(node.value, data)
                    end
                end
                node.__apply_constant_array = nil
            end
        end
    )

    -- Inject Decoder
    self:addDecodeCode(ast)

    -- Shuffle wrapper + rotation order
    local steps =
        util.shuffle(
        {
            function()
                local funcScope = Scope:new(self.rootScope)
                funcScope:addReferenceToHigherScope(self.rootScope, self.arrId)
                local arg = funcScope:addVariable()
                local addSubArg
                if self.wrapperOffset < 0 then
                    addSubArg = Ast.SubExpression(Ast.VariableExpression(funcScope, arg), Ast.NumberExpression(-self.wrapperOffset))
                else
                    addSubArg = Ast.AddExpression(Ast.VariableExpression(funcScope, arg), Ast.NumberExpression(self.wrapperOffset))
                end
                table.insert(
                    ast.body.statements,
                    1,
                    Ast.LocalFunctionDeclaration(
                        self.rootScope,
                        self.wrapperId,
                        {Ast.VariableExpression(funcScope, arg)},
                        Ast.Block(
                            {
                                Ast.ReturnStatement(
                                    {
                                        Ast.IndexExpression(
                                            Ast.VariableExpression(self.rootScope, self.arrId),
                                            addSubArg
                                        )
                                    }
                                )
                            },
                            funcScope
                        )
                    )
                )
            end,
            function()
                if self.Rotate and #self.constants > 1 then
                    local shift = math.random(1, #self.constants - 1)
                    rotate(self.constants, -shift)
                    self:addRotateCode(ast, shift)
                end
            end
        }
    )

    for _, f in ipairs(steps) do
        f()
    end

    -- Add constant array itself
    table.insert(ast.body.statements, 1, Ast.LocalVariableDeclaration(self.rootScope, {self.arrId}, {self:createArray()}))

    self.rootScope = nil
    self.arrId = nil
    self.constants = nil
    self.lookup = nil
end

return ConstantArray
