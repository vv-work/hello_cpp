--Define a "class" name HelloWorld
HelloWorld = {}
HelloWorld.__index = HelloWorld

function HelloWorld:new(name)
    local self = setmetatable({}, HelloWorld)
    self.name = name or "World"
    return self
end

function HelloWorld:greet()
    return "Hello, " .. self.name .. "!"
end

function HelloWorld:shout()
    return string.upper(self:greet())
end

local hw = HelloWorld:new("Lua")

print(hw:greet())
print(hw:shout())
