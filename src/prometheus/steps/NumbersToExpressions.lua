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
    Treshold = {
        type = "number",
        default = 3,
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

function NumbersToExpressions:init(settings)
    self.ExpressionGenerators = {
        function(val, depth) -- Multiplication
            if type(val) ~= "number" or val == 0 then
                return Ast.NumberExpression(val or 0)
            end
            local max_factor = 128
            for _ = 1, 10 do
                local factor = math.random(1, max_factor)
                if factor ~= 0 and math.abs(val) % factor == 0 then
                    local other = val / factor
                    if type(other) == "number" and tonumber(tostring(factor)) * tonumber(tostring(other)) == val then
                        return Ast.MulExpression(
                            self:CreateNumberExpression(factor, depth),
                            self:CreateNumberExpression(other, depth),
                            false
                        )
                    end
                end
            end
            return Ast.NumberExpression(val)
        end,
        function(val, depth) -- Division
            if type(val) ~= "number" or val == 0 then
                return Ast.NumberExpression(val or 0)
            end
            local max_factor = 128
            for _ = 1, 10 do
                local divisor = math.random(1, max_factor)
                if divisor ~= 0 then
                    local numerator = val * divisor
                    if type(numerator) == "number" and tonumber(tostring(numerator)) / tonumber(tostring(divisor)) == val then
                        return Ast.DivExpression(
                            self:CreateNumberExpression(numerator, depth),
                            self:CreateNumberExpression(divisor, depth),
                            false
                        )
                    end
                end
            end
            return Ast.NumberExpression(val)
        end
    }
end

function NumbersToExpressions:CreateNumberExpression(val, depth)
    if type(val) ~= "number" then val = 0 end
    if (depth > 0 and math.random() >= self.InternalTreshold) or depth > 15 then
        return Ast.NumberExpression(val)
    end

    local generators = util.shuffle({unpack(self.ExpressionGenerators)})
    for _, generator in ipairs(generators) do
        local node = generator(val, depth + 1)
        if node then
            return node
        end
    end

    return Ast.NumberExpression(val)
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
            if type(node.value) == "number" and math.random() <= self.Treshold then
                return self:CreateNumberExpression(node.value, 0)
            end
        elseif node.kind == AstKind.MulExpression or node.kind == AstKind.DivExpression then
            local value = self:evaluateIfConstant(node)
            if type(value) == "number" and math.random() <= self.Treshold then
                return self:CreateNumberExpression(value, 0)
            end
        end
    end)
end

return NumbersToExpressions

