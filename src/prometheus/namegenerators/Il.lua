-- namegenerators/il.lua
-- Long-valid-name generator (letters / underscore start, then alnum + underscore)
local MIN_CHARACTERS = 120          -- minimal length of generated names
local MAX_RANDOM_SUFFIX = 48       -- maximum random suffix added
local MAX_LENGTH = 200             -- safety cap to avoid extremely long identifiers

local util = require("prometheus.util")
local chararray = util.chararray

-- allowed characters for the body of identifiers (letters, digits, underscore)
local VarDigits = chararray("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
-- allowed characters for the first character (must NOT start with a digit)
local VarStartDigits = chararray("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")

local offset = 0

-- deterministic-ish base-conversion generator (then padded with randomness to reach MIN_CHARACTERS)
local function generateName(id, scope)
    -- ensure id is a number
    id = tonumber(id) or 0
    id = id + offset

    local startBase = #VarStartDigits
    local base = #VarDigits

    -- pick starting character. if id==0 produce a pseudo-random pick from offset to avoid digits-start
    local startIndex = (id % startBase) + 1
    id = math.floor(id / startBase)
    local name = VarStartDigits[startIndex] or "_"

    -- produce the rest using base conversion
    repeat
        local d = (id % base) + 1
        name = name .. (VarDigits[d] or "a")
        id = math.floor(id / base)
    until id == 0

    -- If the name is still shorter than MIN_CHARACTERS, append pseudo-random chars.
    -- Use math.random to add entropy (prepare() shuffles pools so distribution changes per run).
    while #name < MIN_CHARACTERS do
        name = name .. (VarDigits[math.random(1, base)] or "a")
        if #name >= MIN_CHARACTERS or #name >= MAX_LENGTH then break end
    end

    -- Add a bounded random suffix sometimes to increase length/obfuscation variety
    local extra = math.random(0, MAX_RANDOM_SUFFIX)
    for i = 1, extra do
        if #name >= MAX_LENGTH then break end
        name = name .. (VarDigits[math.random(1, base)] or "a")
    end

    -- final safety: ensure it starts with a valid start char (not digit) and is within caps
    if name:match("^[0-9]") then
        name = "_" .. name:sub(2)
    end
    if #name > MAX_LENGTH then
        name = name:sub(1, MAX_LENGTH)
    end

    return name
end

local function prepare(ast)
    -- shuffle available characters so subsequent runs produce different names
    util.shuffle(VarDigits)
    util.shuffle(VarStartDigits)

    -- choose an offset to avoid predictable short names; keep it within safe numeric range
    offset = math.random(1, 1e9)
end

return {
    generateName = generateName,
    prepare = prepare
}

