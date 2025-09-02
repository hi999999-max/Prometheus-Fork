-- Improved ConstantArray.lua
-- Part of the Prometheus Obfuscator by Levno_710
-- Improvements:
--  * Added "xor" encoding (default) that XORs bytes with a random single-byte key and then ascii85-encodes the result
--  * Runtime decoder supports ascii85 decode and XOR decryption with fallbacks (bit32/bit/luau operator or arithmetic)
--  * Keeps original API and setting names (to avoid breaking)
--  * Minor cleanup and safety improvements
-- NOTE: This file intentionally preserves original field names (e.g., "Treshold") to avoid breaking external callers.

local Step = require("prometheus.step");
local Ast = require("prometheus.ast");
local Scope = require("prometheus.scope");
local visitast = require("prometheus.visitast");
local util     = require("prometheus.util")
local Parser   = require("prometheus.parser");
local enums = require("prometheus.enums")

local LuaVersion = enums.LuaVersion;
local AstKind = Ast.AstKind;

local ConstantArray = Step:extend();
ConstantArray.Description = "This Step will Extract all Constants and put them into an Array at the beginning of the script";
ConstantArray.Name = "Constant Array";

-- Keep original setting names so existing pipelines won't break
ConstantArray.SettingsDescriptor = {
    Treshold = {
        name = "Treshold",
        description = "The relative amount of nodes that will be affected",
        type = "number",
        default = 1,
        min = 0,
        max = 1,
    },
    StringsOnly = {
        name = "StringsOnly",
        description = "Wether to only Extract Strings",
        type = "boolean",
        default = true,
    },
    Shuffle = {
        name = "Shuffle",
        description = "Wether to shuffle the order of Elements in the Array",
        type = "boolean",
        default = true,
    },
    Rotate = {
        name = "Rotate",
        description = "Wether to rotate the String Array by a specific (random) amount. This will be undone on runtime.",
        type = "boolean",
        default = true,
    },
    LocalWrapperTreshold = {
        name = "LocalWrapperTreshold",
        description = "The relative amount of nodes functions, that will get local wrappers",
        type = "number",
        default = 1,
        min = 0,
        max = 1,
    },
    LocalWrapperCount = {
        name = "LocalWrapperCount",
        description = "The number of Local wrapper Functions per scope. This only applies if LocalWrapperTreshold is greater than 0",
        type = "number",
        min = 0,
        max = 512,
        default = 333,
    },
    LocalWrapperArgCount = {
        name = "LocalWrapperArgCount",
        description = "The number of Arguments to the Local wrapper Functions",
        type = "number",
        min = 1,
        default = 192,
        max = 200,
    },
    MaxWrapperOffset = {
        name = "MaxWrapperOffset",
        description = "The Max Offset for the Wrapper Functions",
        type = "number",
        min = 0,
        default = 65535,
    },
    Encoding = {
        name = "Encoding",
        description = "The Encoding to use for the Strings",
        type = "enum",
        -- default changed to "xor" (user requested default to r2/xor)
        default = "xor",
        values = {
            "none",
            "ascii85",
            "xor",
        },
    },
}

local function callNameGenerator(generatorFunction, ...)
    if (type(generatorFunction) == "table") then
        generatorFunction = generatorFunction.generateName;
    end
    return generatorFunction(...);
end

function ConstantArray:init(settings)
    -- nothing to init specifically here; settings are expected to be injected onto self
end

-- create the AST table constructor for the array (encodes strings as required)
function ConstantArray:createArray()
    local entries = {};
    for i, v in ipairs(self.constants) do
        local nodeVal = v;
        if type(nodeVal) == "string" then
            nodeVal = self:encode(nodeVal);
        end
        entries[i] = Ast.TableEntry(Ast.ConstantNode(nodeVal));
    end
    return Ast.TableConstructorExpression(entries);
end

function ConstantArray:indexing(index, data)
    if self.LocalWrapperCount > 0 and data.functionData.local_wrappers then
        local wrappers = data.functionData.local_wrappers;
        local wrapper = wrappers[math.random(#wrappers)];

        local args = {};
        local ofs = index - self.wrapperOffset - wrapper.offset;
        for i = 1, self.LocalWrapperArgCount, 1 do
            if i == wrapper.arg then
                args[i] = Ast.NumberExpression(ofs);
            else
                args[i] = Ast.NumberExpression(math.random(ofs - 1024, ofs + 1024));
            end
        end

        data.scope:addReferenceToHigherScope(wrappers.scope, wrappers.id);
        return Ast.FunctionCallExpression(Ast.IndexExpression(
            Ast.VariableExpression(wrappers.scope, wrappers.id),
            Ast.StringExpression(wrapper.index)
        ), args);
    else
        data.scope:addReferenceToHigherScope(self.rootScope,  self.wrapperId);
        return Ast.FunctionCallExpression(Ast.VariableExpression(self.rootScope, self.wrapperId), {
            Ast.NumberExpression(index - self.wrapperOffset);
        });
    end
end

function ConstantArray:getConstant(value, data)
    if (self.lookup[value]) then
        return self:indexing(self.lookup[value], data)
    end
    local idx = #self.constants + 1;
    self.constants[idx] = value;
    self.lookup[value] = idx;
    return self:indexing(idx, data);
end

function ConstantArray:addConstant(value)
    if (self.lookup[value]) then
        return
    end
    local idx = #self.constants + 1;
    self.constants[idx] = value;
    self.lookup[value] = idx;
end

local function reverse(t, i, j)
    while i < j do
        t[i], t[j] = t[j], t[i]
        i, j = i+1, j-1
    end
end

local function rotate(t, d, n)
    n = n or #t
    if n == 0 then return end
    d = (d or 1) % n
    if d == 0 then return end
    reverse(t, 1, n)
    reverse(t, 1, d)
    reverse(t, d+1, n)
end

local rotateCode = [=[
for i, v in ipairs({{1, LEN}, {1, SHIFT}, {SHIFT + 1, LEN}}) do
    while v[1] < v[2] do
        ARR[v[1]], ARR[v[2]], v[1], v[2] = ARR[v[2]], ARR[v[1]], v[1] + 1, v[2] - 1
    end
end
]=];

function ConstantArray:addRotateCode(ast, shift)
    local parser = Parser:new({
        LuaVersion = LuaVersion.Lua51;
    });

    local newAst = parser:parse(string.gsub(string.gsub(rotateCode, "SHIFT", tostring(shift)), "LEN", tostring(#self.constants)));
    local forStat = newAst.body.statements[1];
    forStat.body.scope:setParent(ast.body.scope);
    visitast(newAst, nil, function(node, data)
        if (node.kind == AstKind.VariableExpression) then
            if (node.scope:getVariableName(node.id) == "ARR") then
                data.scope:removeReferenceToHigherScope(node.scope, node.id);
                data.scope:addReferenceToHigherScope(self.rootScope, self.arrId);
                node.scope = self.rootScope;
                node.id    = self.arrId;
            end
        end
    end)

    table.insert(ast.body.statements, 1, forStat);
end

-- Adds runtime decode code for ascii85 and optional xor decryption.
function ConstantArray:addDecodeCode(ast)
    if self.Encoding == "none" then
        return
    end

    -- Build appropriate decode code string; we will replace ARR and KEY (if used)
    local ascii85_decode_snip = [[
local function ascii85_decode(str)
    local res = {}
    local i = 1
    local len = #str
    while i <= len do
        local c = string.sub(str, i, i)
        if c == 'z' then
            table.insert(res, string.char(0,0,0,0))
            i = i + 1
        elseif c:match("%s") then
            i = i + 1
        else
            local group = {}
            local j = 0
            while j < 5 and i + j <= len do
                local ch = string.sub(str, i + j, i + j)
                if ch == 'z' or ch:match("%s") then
                    break
                end
                group[#group + 1] = ch
                j = j + 1
            end
            local groupLen = #group
            for _ = groupLen + 1, 5 do
                group[#group + 1] = 'u'
            end
            local chunk = 0
            for k = 1, 5 do
                chunk = chunk * 85 + (string.byte(group[k]) - 33)
            end
            local bytesToOutput = groupLen - 1
            for b = 3, 3 - (bytesToOutput - 1), -1 do
                local byte = math.floor(chunk / (256 ^ b)) % 256
                table.insert(res, string.char(byte))
            end
            i = i + groupLen
        end
    end
    return table.concat(res)
end
]]

    local xor_snip = [[
local function bxor(a, b)
    -- try common bit libraries/operators first for speed
    if bit32 and bit32.bxor then return bit32.bxor(a, b) end
    if bit and bit.bxor then return bit.bxor(a, b) end
    local ok, op = pcall(function() return a ~ b end)
    if ok then return op end
    -- fallback: arithmetic per-bit XOR (works in plain Lua 5.1)
    local res = 0
    local bitval = 1
    for i = 0, 7 do
        local abit = a % 2
        local bbit = b % 2
        if ((abit + bbit) % 2) == 1 then
            res = res + bitval
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bitval = bitval * 2
    end
    return res
end

for i = 1, #ARR do
    local data = ARR[i]
    if type(data) == "string" then
        local decoded = ascii85_decode(data)
        local out = {}
        for j = 1, #decoded do
            local b = string.byte(decoded, j)
            out[j] = string.char(bxor(b, KEY))
        end
        ARR[i] = table.concat(out)
    end
end
]]

    local ascii_snip_loop = [[
for i = 1, #ARR do
    local data = ARR[i]
    if type(data) == "string" then
        ARR[i] = ascii85_decode(data)
    end
end
]]

    -- choose final code
    local finalCode
    if self.Encoding == "ascii85" then
        finalCode = ascii85_decode_snip .. "\n" .. ascii_snip_loop
    elseif self.Encoding == "xor" then
        finalCode = ascii85_decode_snip .. "\n" .. xor_snip
    else
        -- should not happen (handled earlier), but safe fallback
        finalCode = ""
    end

    -- insert into AST if we have runtime code to inject
    if finalCode ~= "" then
        -- If using xor, we must replace the placeholder KEY with an actual numeric key literal
        if self.Encoding == "xor" then
            finalCode = string.gsub(finalCode, "KEY", tostring(self.xor_key or 0))
        end

        local parser = Parser:new({
            LuaVersion = LuaVersion.Lua51;
        })

        local newAst = parser:parse(finalCode)
        local forStat = newAst.body.statements[1] or newAst.body.statements[2] -- ascii85_decode_snip is a function + loop; we insert the first statement relevant to arr handling
        -- ensure we attach the runtime scopes properly
        if forStat and forStat.body and forStat.body.scope then
            forStat.body.scope:setParent(ast.body.scope)
        end

        visitast(newAst, nil, function(node, data)
            if node.kind == AstKind.VariableExpression then
                if node.scope:getVariableName(node.id) == "ARR" then
                    data.scope:removeReferenceToHigherScope(node.scope, node.id)
                    data.scope:addReferenceToHigherScope(self.rootScope, self.arrId)
                    node.scope = self.rootScope
                    node.id = self.arrId
                end
            end
        end)

        -- Insert all function/loop statements at the start in the same order they appear
        for i = #newAst.body.statements, 1, -1 do
            local st = newAst.body.statements[i]
            table.insert(ast.body.statements, 1, st)
        end
    end
end

-- create a keyed table for base64 lookup (unused by new features but kept)
function ConstantArray:createBase64Lookup()
    local entries = {};
    local i = 0;
    for char in string.gmatch(self.base64chars, ".") do
        table.insert(entries, Ast.KeyedTableEntry(Ast.StringExpression(char), Ast.NumberExpression(i)));
        i = i + 1;
    end
    util.shuffle(entries);
    return Ast.TableConstructorExpression(entries);
end

-- encoding helper: supports 'ascii85' and 'xor' (xor->ascii85) and 'none'
function ConstantArray:encode(str)
    -- ascii85 encoder (handles arbitrary bytes)
    local function ascii85_encode(data)
        local result = {}
        local len = #data
        local i = 1

        while i <= len do
            local chunk = 0
            local chunkSize = math.min(4, len - i + 1)

            for j = 0, 3 do
                local byte = 0
                if j < chunkSize then
                    byte = string.byte(data, i + j)
                end
                chunk = chunk * 256 + byte
            end

            if chunk == 0 and chunkSize == 4 then
                table.insert(result, 'z')
            else
                local encoded = {}
                for _ = 1, 5 do
                    encoded[#encoded + 1] = string.char((chunk % 85) + 33)
                    chunk = math.floor(chunk / 85)
                end
                local encodedStr = table.concat(encoded, '')
                encodedStr = encodedStr:reverse()
                if chunkSize < 4 then
                    encodedStr = encodedStr:sub(1, chunkSize + 1)
                end
                table.insert(result, encodedStr)
            end

            i = i + 4
        end

        return table.concat(result)
    end

    if self.Encoding == "none" then
        return str
    elseif self.Encoding == "ascii85" then
        return ascii85_encode(str)
    elseif self.Encoding == "xor" then
        -- XOR bytes with single-byte key, then ascii85 encode result to keep it ASCII-safe
        local key = self.xor_key or 0
        local out = {}
        for i = 1, #str do
            local b = string.byte(str, i)
            local xb = b
            -- XOR using simple arithmetic fallback (works regardless of runtime bit libraries)
            -- prefer fast libs if available at build time, but we're doing it at encoding time so just use bitwise through arithmetic
            local res = 0
            local a = b
            local bb = key
            local bitval = 1
            for bit = 0, 7 do
                local abit = a % 2
                local bbit = bb % 2
                if ((abit + bbit) % 2) == 1 then
                    res = res + bitval
                end
                a = math.floor(a / 2)
                bb = math.floor(bb / 2)
                bitval = bitval * 2
            end
            xb = res
            out[i] = string.char(xb)
        end
        return ascii85_encode(table.concat(out))
    else
        -- unknown encoding: fallback to ascii85
        return ascii85_encode(str)
    end
end

function ConstantArray:apply(ast, pipeline)
    self.rootScope = ast.body.scope;
    self.arrId     = self.rootScope:addVariable();

    -- If using xor encoding, pick a single byte key now
    if self.Encoding == "xor" then
        -- key in range 1..255 (avoid zero because XOR zero is noop)
        self.xor_key = math.random(1, 255)
    end

    self.base64chars = table.concat(util.shuffle{
        "A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z",
        "a","b","c","d","e","f","g","h","i","j","k","l","m","n","o","p","q","r","s","t","u","v","w","x","y","z",
        "0","1","2","3","4","5","6","7","8","9",
        "+","/",
    });

    self.constants = {};
    self.lookup    = {};

    -- Extract Constants
    visitast(ast, nil, function(node, data)
        -- Apply only to some nodes
        if math.random() <= self.Treshold then
            node.__apply_constant_array = true;
            if node.kind == AstKind.StringExpression then
                self:addConstant(node.value);
            elseif not self.StringsOnly then
                if node.isConstant then
                    if node.value ~= nil then
                        self:addConstant(node.value);
                    end
                end
            end
        end
    end);

    -- Shuffle Array
    if self.Shuffle then
        self.constants = util.shuffle(self.constants);
        self.lookup    = {};
        for i, v in ipairs(self.constants) do
            self.lookup[v] = i;
        end
    end

    -- Set Wrapper Function Offset
    self.wrapperOffset = math.random(-self.MaxWrapperOffset, self.MaxWrapperOffset);
    self.wrapperId     = self.rootScope:addVariable();

    visitast(ast, function(node, data)
        -- Add Local Wrapper Functions
        if self.LocalWrapperCount > 0 and node.kind == AstKind.Block and node.isFunctionBlock and math.random() <= self.LocalWrapperTreshold then
            local id = node.scope:addVariable()
            data.functionData.local_wrappers = {
                id = id;
                scope = node.scope,
            };
            local nameLookup = {};
            for i = 1, self.LocalWrapperCount, 1 do
                local name;
                repeat
                    name = callNameGenerator(pipeline.namegenerator, math.random(1, self.LocalWrapperArgCount * 16));
                until not nameLookup[name];
                nameLookup[name] = true;

                local offset = math.random(-self.MaxWrapperOffset, self.MaxWrapperOffset);
                local argPos = math.random(1, self.LocalWrapperArgCount);

                data.functionData.local_wrappers[i] = {
                    arg   = argPos,
                    index = name,
                    offset =  offset,
                };
                data.functionData.__used = false;
            end
        end
        if node.__apply_constant_array then
            data.functionData.__used = true;
        end
    end, function(node, data)
        -- Actually insert Statements to get the Constant Values
        if node.__apply_constant_array then
            if node.kind == AstKind.StringExpression then
                return self:getConstant(node.value, data);
            elseif not self.StringsOnly then
                if node.isConstant then
                    return node.value ~= nil and self:getConstant(node.value, data);
                end
            end
            node.__apply_constant_array = nil;
        end

        -- Insert Local Wrapper Declarations
        if self.LocalWrapperCount > 0 and node.kind == AstKind.Block and node.isFunctionBlock and data.functionData.local_wrappers and data.functionData.__used then
            data.functionData.__used = nil;
            local elems = {};
            local wrappers = data.functionData.local_wrappers;
            for i = 1, self.LocalWrapperCount, 1 do
                local wrapper = wrappers[i];
                local argPos = wrapper.arg;
                local offset = wrapper.offset;
                local name   = wrapper.index;

                local funcScope = Scope:new(node.scope);

                local arg = nil;
                local args = {};

                for k = 1, self.LocalWrapperArgCount, 1 do
                    args[k] = funcScope:addVariable();
                    if k == argPos then
                        arg = args[k];
                    end
                end

                local addSubArg;

                -- Create add and Subtract code
                if offset < 0 then
                    addSubArg = Ast.SubExpression(Ast.VariableExpression(funcScope, arg), Ast.NumberExpression(-offset));
                else
                    addSubArg = Ast.AddExpression(Ast.VariableExpression(funcScope, arg), Ast.NumberExpression(offset));
                end

                funcScope:addReferenceToHigherScope(self.rootScope, self.wrapperId);
                local callArg = Ast.FunctionCallExpression(Ast.VariableExpression(self.rootScope, self.wrapperId), {
                    addSubArg
                });

                local fargs = {};
                for ii, v in ipairs(args) do
                    fargs[ii] = Ast.VariableExpression(funcScope, v);
                end

                elems[i] = Ast.KeyedTableEntry(
                    Ast.StringExpression(name),
                    Ast.FunctionLiteralExpression(fargs, Ast.Block({
                        Ast.ReturnStatement({
                            callArg
                        });
                    }, funcScope))
                )
            end
            table.insert(node.statements, 1, Ast.LocalVariableDeclaration(node.scope, {
                wrappers.id
            }, {
                Ast.TableConstructorExpression(elems)
            }));
        end
    end);

    -- Add runtime decode code (ascii85 and optional xor)
    self:addDecodeCode(ast);

    local steps = util.shuffle({
        -- Add Wrapper Function Code
        function()
            local funcScope = Scope:new(self.rootScope);
            -- Add Reference to Array
            funcScope:addReferenceToHigherScope(self.rootScope, self.arrId);

            local arg = funcScope:addVariable();
            local addSubArg;

            -- Create add and Subtract code
            if self.wrapperOffset < 0 then
                addSubArg = Ast.SubExpression(Ast.VariableExpression(funcScope, arg), Ast.NumberExpression(-self.wrapperOffset));
            else
                addSubArg = Ast.AddExpression(Ast.VariableExpression(funcScope, arg), Ast.NumberExpression(self.wrapperOffset));
            end

            -- Create and Add the Function Declaration
            table.insert(ast.body.statements, 1, Ast.LocalFunctionDeclaration(self.rootScope, self.wrapperId, {
                Ast.VariableExpression(funcScope, arg)
            }, Ast.Block({
                Ast.ReturnStatement({
                    Ast.IndexExpression(
                        Ast.VariableExpression(self.rootScope, self.arrId),
                        addSubArg
                    )
                });
            }, funcScope)));
        end,
        -- Rotate Array and Add unrotate code
        function()
            if self.Rotate and #self.constants > 1 then
                local shift = math.random(1, #self.constants - 1);

                rotate(self.constants, -shift);
                self:addRotateCode(ast, shift);
            end
        end,
    });

    for i, f in ipairs(steps) do
        f();
    end

    -- Add the Array Declaration
    table.insert(ast.body.statements, 1, Ast.LocalVariableDeclaration(self.rootScope, {self.arrId}, {self:createArray()}));

    -- clean up
    self.rootScope = nil;
    self.arrId     = nil;

    self.constants = nil;
    self.lookup    = nil;
end

return ConstantArray;
