-- NumbersToExpressions.lua

unpack = unpack or table.unpack

local Step = require("prometheus.step")
local Ast = require("prometheus.ast")
local visitast = require("prometheus.visitast")
local util = require("prometheus.util")

local AstKind = Ast.AstKind

local NumbersToExpressions = Step:extend()
NumbersToExpressions.Description = "This Step Converts number Literals to Expressions"
NumbersToExpressions.Name = "Numbers To Expressions"

NumbersToExpressions.SettingsDescriptor = {
    Treshold = {                -- kept original name to avoid breaking callers
        type = "number",
        default = 0.3,         -- corrected from 3 -> 0.3
        min = 0,
        max = 1,
    },
    InternalTreshold = {
        type = "number",
        default = 0.2,
        min = 0,
        max = 0.8,
    }
}

local function clamp(n, lo, hi)
    if type(n) ~= "number" then return lo end
    if lo and n < lo then return lo end
    if hi and n > hi then return hi end
    return n
end

function NumbersToExpressions:init(settings)
    settings = settings or {}

    -- initialize settings with safe fallbacks and clamping
    local sd = NumbersToExpressions.SettingsDescriptor
    local t_default = (sd.Treshold and sd.Treshold.default) or 0.3
    local it_default = (sd.InternalTreshold and sd.InternalTreshold.default) or 0.2

    self.Treshold = clamp(settings.Treshold or t_default, sd.Treshold.min, sd.Treshold.max)
    self.InternalTreshold = clamp(settings.InternalTreshold or it_default, sd.InternalTreshold.min, sd.InternalTreshold.max)

    -- expression generators
    self.ExpressionGenerators = {
        function(val, depth) -- Multiplication
            local nval = tonumber(val) or 0
            local ndept = tonumber(depth) or 0

            if nval == 0 then
                return Ast.NumberExpression(nval)
            end

            local max_factor = 128
            for _ = 1, 10 do
                local factor = math.random(1, max_factor)
                if factor ~= 0 then
                    -- use math.abs on numeric value to handle negatives
                    local abs_nval = math.abs(nval)
                    -- ensure modulo arithmetic on numbers only
                    if abs_nval % factor == 0 then
                        local other = nval / factor
                        if type(other) == "number" and tonumber(factor) and tonumber(other) and (tonumber(factor) * tonumber(other) == nval) then
                            return Ast.MulExpression(
                                self:CreateNumberExpression(factor, ndept),
                                self:CreateNumberExpression(other, ndept),
                                false
                            )
                        end
                    end
                end
            end

            return Ast.NumberExpression(nval)
        end,
        function(val, depth) -- Division
            local nval = tonumber(val) or 0
            local ndept = tonumber(depth) or 0

            if nval == 0 then
                return Ast.NumberExpression(nval)
            end

            local max_factor = 128
            for _ = 1, 10 do
                local divisor = math.random(1, max_factor)
                if divisor ~= 0 then
                    local numerator = nval * divisor
                    -- ensure tonumber safety for divisor/numerator
                    local nd = tonumber(divisor)
                    local nn = tonumber(numerator)
                    if nn and nd and (nd ~= 0) and (nn / nd == nval) then
                        return Ast.DivExpression(
                            self:CreateNumberExpression(nn, ndept),
                            self:CreateNumberExpression(nd, ndept),
                            false
                        )
                    end
                end
            end

            return Ast.NumberExpression(nval)
        end
    }
end

function NumbersToExpressions:CreateNumberExpression(val, depth)
    local nval = tonumber(val) or 0
    local ndept = tonumber(depth) or 0

    -- use InternalTreshold safely (already set in init)
    if (ndept > 0 and math.random() >= (self.InternalTreshold or 0)) or ndept >= 15 then
        return Ast.NumberExpression(nval)
    end

    local generators = util.shuffle({unpack(self.ExpressionGenerators)})
    for _, generator in ipairs(generators) do
        -- call the generator with sanitized numbers
        local ok, node = pcall(generator, nval, ndept + 1)
        if ok and node then
            return node
        end
        -- if the generator errored, swallow it and continue to other generators
    end

    return Ast.NumberExpression(nval)
end

function NumbersToExpressions:evaluateIfConstant(node)
    if not node then return nil end

    if node.kind == AstKind.NumberExpression then
        return node.value
    elseif node.kind == AstKind.MulExpression or node.kind == AstKind.DivExpression then
        local left = self:evaluateIfConstant(node.left)
        local right = self:evaluateIfConstant(node.right)
        if type(left) ~= "number" or type(right) ~= "number" then return nil end
        if node.kind == AstKind.MulExpression then
            return left * right
        elseif node.kind == AstKind.DivExpression then
            return right ~= 0 and left / right or nil
        end
    end

    return nil
end

function NumbersToExpressions:apply(ast)
    visitast(ast, nil, function(node)
        if not node then return end
        if node.kind == AstKind.NumberExpression then
            if type(node.value) == "number" and math.random() <= (self.Treshold or 0) then
                return self:CreateNumberExpression(node.value, 0)
            end
        elseif node.kind == AstKind.MulExpression or node.kind == AstKind.DivExpression then
            local value = self:evaluateIfConstant(node)
            if type(value) == "number" and math.random() <= (self.Treshold or 0) then
                return self:CreateNumberExpression(value, 0)
            end
        end
    end)
end

return NumbersToExpressions
