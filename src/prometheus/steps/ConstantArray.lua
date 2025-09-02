-- This Script is Part of the Prometheus Obfuscator by Levno_710
--
-- ConstantArray.lua (improved)
--
-- This Script provides a Simple Obfuscation Step that wraps the entire Script into a function

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

-- NOTE: kept all setting keys unchanged to avoid breaking external config
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
	};
	MaxWrapperOffset = {
		name = "MaxWrapperOffset",
		description = "The Max Offset for the Wrapper Functions",
		type = "number",
		min = 0,
		default = 65535,
	};
	Encoding = {
		name = "Encoding",
		description = "The Encoding to use for the Strings",
		type = "enum",
		default = "ascii85",
		values = {
			"none",
			"ascii85",
		},
	}
}

local function callNameGenerator(generatorFunction, ...)
	if(type(generatorFunction) == "table") then
		generatorFunction = generatorFunction.generateName;
	end
	return generatorFunction(...);
end

function ConstantArray:init(settings)
	-- no-op (kept for compatibility)
end

-- create the AST table constructor for the constants
function ConstantArray:createArray()
	local entries = {};
	for i, v in ipairs(self.constants) do
		if type(v) == "string" then
			v = self:encode(v);
		end
		entries[i] = Ast.TableEntry(Ast.ConstantNode(v));
	end
	return Ast.TableConstructorExpression(entries);
end

-- helper used to replace constant references with wrapper calls
function ConstantArray:indexing(index, data)
	-- local wrapper path (per-function table of wrapper functions)
	if self.LocalWrapperCount > 0 and data.functionData.local_wrappers then
		local wrappers = data.functionData.local_wrappers;
		-- robust: ensure numeric portion exists
		if #wrappers > 0 then
			local wrapper = wrappers[math.random(#wrappers)];

			local args = {};
			local ofs = index - self.wrapperOffset - (wrapper.offset or 0);
			for i = 1, self.LocalWrapperArgCount, 1 do
				if i == wrapper.arg then
					args[i] = Ast.NumberExpression(ofs);
				else
					args[i] = Ast.NumberExpression(math.random(ofs - 1024, ofs + 1024));
				end
			end

			-- add reference to the wrapper table in the current scope
			data.scope:addReferenceToHigherScope(wrappers.scope, wrappers.id);
			return Ast.FunctionCallExpression(Ast.IndexExpression(
				Ast.VariableExpression(wrappers.scope, wrappers.id),
				Ast.StringExpression(wrapper.index)
			), args);
		end
	end

	-- global wrapper path
	data.scope:addReferenceToHigherScope(self.rootScope,  self.wrapperId);
	return Ast.FunctionCallExpression(Ast.VariableExpression(self.rootScope, self.wrapperId), {
		Ast.NumberExpression(index - (self.wrapperOffset or 0));
	});
end

function ConstantArray:getConstant(value, data)
	-- only handle primitive values (strings, numbers, booleans, nil)
	local vType = type(value)
	if vType ~= "string" and vType ~= "number" and vType ~= "boolean" and value ~= nil then
		-- avoid attempting to index with tables/functions — store by tostring fallback
		value = tostring(value)
	end

	if(self.lookup[value]) then
		return self:indexing(self.lookup[value], data)
	end
	local idx = #self.constants + 1;
	self.constants[idx] = value;
	self.lookup[value] = idx;
	return self:indexing(idx, data);
end

function ConstantArray:addConstant(value)
	local vType = type(value)
	if vType ~= "string" and vType ~= "number" and vType ~= "boolean" and value ~= nil then
		value = tostring(value)
	end
	if(self.lookup[value]) then
		return
	end
	local idx = #self.constants + 1;
	self.constants[idx] = value;
	self.lookup[value] = idx;
end

-- efficient in-place reverse and rotate helpers
local function reverse(t, i, j)
	while i < j do
	  t[i], t[j] = t[j], t[i]
	  i, j = i+1, j-1
	end
end

local function rotate(t, d, n)
	n = n or #t
	if n <= 1 then return end
	d = (d or 1) % n
	if d == 0 then return end
	reverse(t, 1, n)
	reverse(t, 1, d)
	reverse(t, d+1, n)
end

-- rotate runtime snippet (kept simple)
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

	local code = rotateCode:gsub("SHIFT", tostring(shift)):gsub("LEN", tostring(#self.constants));
	local newAst = parser:parse(code);
	local forStat = newAst.body.statements[1];
	forStat.body.scope:setParent(ast.body.scope);

	visitast(newAst, nil, function(node, data)
		if(node.kind == AstKind.VariableExpression) then
			if(node.scope:getVariableName(node.id) == "ARR") then
				data.scope:removeReferenceToHigherScope(node.scope, node.id);
				data.scope:addReferenceToHigherScope(self.rootScope, self.arrId);
				node.scope = self.rootScope;
				node.id    = self.arrId;
			end
		end
	end)

	table.insert(ast.body.statements, 1, forStat);
end

-- ASCII85 decode injector — localized & slightly hardened
function ConstantArray:addDecodeCode(ast)
    local ascii85DecodeCode = [[
    do
        local arr = ARR;
        local function ascii85_decode(str)
            local out = {};
            local i = 1;
            local len = #str;
            while i <= len do
                local c = string.sub(str, i, i);
                if c == 'z' then
                    out[#out+1] = string.char(0,0,0,0);
                    i = i + 1;
                elseif c:match("%s") then
                    i = i + 1;
                else
                    local group = {};
                    local j = 0;
                    while j < 5 and i + j <= len do
                        local ch = string.sub(str, i + j, i + j);
                        if ch == 'z' or ch:match("%s") then
                            break;
                        end
                        group[#group + 1] = ch;
                        j = j + 1;
                    end

                    local groupLen = #group;
                    for _ = groupLen + 1, 5 do
                        group[#group + 1] = 'u';
                    end

                    local chunk = 0;
                    for k = 1, 5 do
                        chunk = chunk * 85 + (string.byte(group[k]) - 33);
                    end

                    local bytesToOutput = groupLen - 1;
                    -- produce bytes from most-significant to least
                    for b = 3, 3 - (bytesToOutput - 1), -1 do
                        local byte = math.floor(chunk / (256 ^ b)) % 256;
                        out[#out + 1] = string.char(byte);
                    end

                    i = i + groupLen;
                end
            end
            return table.concat(out);
        end

        for i = 1, #arr do
            local data = arr[i];
            if type(data) == "string" then
                arr[i] = ascii85_decode(data) or "";
            end
        end
    end
    ]]

    local parser = Parser:new({
        LuaVersion = LuaVersion.Lua51;
    })

    local newAst = parser:parse(ascii85DecodeCode)
    local forStat = newAst.body.statements[1]
    forStat.body.scope:setParent(ast.body.scope)

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

    table.insert(ast.body.statements, 1, forStat)
end

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

-- ascii85 encoder used for stored constants; keeps behavior but robust
function ConstantArray:encode(str)
    if self.Encoding == "ascii85" then
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
                        byte = string.byte(data, i + j) or 0
                    end
                    chunk = chunk * 256 + byte
                end

                if chunk == 0 and chunkSize == 4 then
                    result[#result + 1] = 'z'
                else
                    local encoded = {}
                    for _ = 1, 5 do
                        encoded[#encoded + 1] = string.char((chunk % 85) + 33)
                        chunk = math.floor(chunk / 85)
                    end
                    local encodedStr = table.concat(encoded, '')
                    encodedStr = string.reverse(encodedStr)
                    if chunkSize < 4 then
                        encodedStr = encodedStr:sub(1, chunkSize + 1)
                    end
                    result[#result + 1] = encodedStr
                end

                i = i + 4
            end

            return table.concat(result)
        end

        return ascii85_encode(str)
    end

    -- default: return original when encoding disabled or unknown
    return str
end

function ConstantArray:apply(ast, pipeline)
	-- localize often-used globals to reduce lookups
	local rnd = math.random
	local tconcat = table.concat

	self.rootScope = ast.body.scope;
	self.arrId     = self.rootScope:addVariable();

	-- shuffled base64 char set used by other components (kept for compatibility)
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
		-- Apply only to a subset controlled by threshold
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

	-- Shuffle Array if requested
	if self.Shuffle then
		self.constants = util.shuffle(self.constants);
		self.lookup    = {};
		for i, v in ipairs(self.constants) do
			self.lookup[v] = i;
		end
	end

	-- Set Wrapper Function Offset and wrapper id
	self.wrapperOffset = math.random(-self.MaxWrapperOffset, self.MaxWrapperOffset);
	self.wrapperId     = self.rootScope:addVariable();

	-- First pass: create local wrapper metadata per function block
	visitast(ast, function(node, data)
		-- Add Local Wrapper Functions metadata for function blocks
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
		-- Second pass (replacement & insertion)

		-- Replace marked nodes with wrapper calls
		if node.__apply_constant_array then
			if node.kind == AstKind.StringExpression then
				-- returns AST node that replaces the string expression
				local replacement = self:getConstant(node.value, data);
				node.__apply_constant_array = nil;
				return replacement;
			elseif not self.StringsOnly then
				if node.isConstant then
					node.__apply_constant_array = nil;
					return node.value ~= nil and self:getConstant(node.value, data);
				end
			end
			node.__apply_constant_array = nil;
		end

		-- Insert Local Wrapper Declarations if used in this function
		if self.LocalWrapperCount > 0 and node.kind == AstKind.Block and node.isFunctionBlock and data.functionData.local_wrappers and data.functionData.__used then
			data.functionData.__used = nil;
			local elems = {};
			local wrappers = data.functionData.local_wrappers;
			for i = 1, self.LocalWrapperCount, 1 do
				local wrapper = wrappers[i];
				local argPos = wrapper.arg;
				local offset = wrapper.offset;
				local name   = wrapper.index;

				-- create a new scope for the function literal
				local funcScope = Scope:new(node.scope);

				local arg = nil;
				local args = {};

				for j = 1, self.LocalWrapperArgCount, 1 do
					args[j] = funcScope:addVariable();
					if j == argPos then
						arg = args[j];
					end
				end

				local addSubArg;

				-- Create add/subtract expression for offset
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

	-- add decoding runtime code (ascii85 -> original strings)
	self:addDecodeCode(ast);

	-- two-step insertion operations (wrapper function, rotate) in randomized order for variety
	local steps = util.shuffle({
		-- Add global wrapper function that maps index->ARR[index + offset]
		function()
			local funcScope = Scope:new(self.rootScope);
			-- Add Reference to Array
			funcScope:addReferenceToHigherScope(self.rootScope, self.arrId);

			local arg = funcScope:addVariable();
			local addSubArg;

			-- Create add and Subtract code according to wrapperOffset
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
		-- Rotate Array and add the runtime unrotate snippet
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

	-- Finally add the actual array declaration at top
	table.insert(ast.body.statements, 1, Ast.LocalVariableDeclaration(self.rootScope, {self.arrId}, {self:createArray()}));

	-- clean up internal state
	self.rootScope = nil;
	self.arrId     = nil;

	self.constants = nil;
	self.lookup    = nil;
end

return ConstantArray;
