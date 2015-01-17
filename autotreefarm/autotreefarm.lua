local component = require("component")
local fs = require("filesystem")
local serialization = require("serialization")
local term = require("term")
local computer = require("computer")
local robot = require("robot")
local keyboard = require("keyboard")
local event =  require("event")
local sides = require("sides")
local ic = component.inventory_controller

local wood = 16
local sapling = 15
local version = "0.2.1 open alpha"
local for_os = "1.4.4+"
local run = false
local running = false
local continuous = false

local config_name = "/etc/autotreefarm.cfg"

--Test features

if not component.isAvailable("robot") then
    error("This program is designed for robots")
    return -1
end

if not component.isAvailable("inventory_controller") then
    error("Inventory Controller not found")
    return -2
end

if not fs.exists(config_name) then
    error("Config not present")
    return -3
end

local file_config = io.open(config_name,"r")
local config = nil
if file_config then
    local content = file_config:read("*a")
    local reason
    config, reason = serialization.unserialize(content)
    if not config then
        error("Something wrong with config:"..reason)
        return -4
    end
else
    error("Config couldn't be opened")
    return -5
end

local ic = component.inventory_controller

local redstone = nil

if component.isAvailable("redstone") then
	redstone = component.redstone
end

local function moveDirection(moves, forced, fmove, fswing)
    local moved = 0
    while moved < moves do
        local m, s =fmove()
        if m then 
            moved = moved + 1
        else
            if s == "impossible move" then
                os.sleep(1)
                if not forced then
                    error("Get Stuck")
                end
            elseif s == "not enough energy" then 
                return false
            elseif forced then
                fswing()
            else
                error("Get Stuck")
            end
        end
    end
    return true
end

local function moveForward(moves, forced)
    return moveDirection(moves, forced, robot.forward, robot.swing)
end

local function moveUp(moves, forced)
    return moveDirection(moves, forced, robot.up, robot.swingUp)
end

local function moveDown(moves, forced)
    return moveDirection(moves, forced, robot.down, robot.swingDown)
end

local function localCompare(slot, compareSlot)
    local old = robot.select()
    robot.select(compareSlot)
    local ret = robot.compareTo(slot)
    robot.select(old)
    return ret
end

local function isLocalSapling(slot)
    return localCompare(slot,sapling)
end

local function isLocalWood(slot)
    return localCompare(slot,wood)
end

local function calcMaxMovement()
    local c = 2 --move up and down from start
    c = c + config.field.start --to get to the first tree
    c = c + (2 * (config.misc.tree - 2)) * config.field.x * config.field.z --max tree traverse
    c = c + config.field.x * config.field.z * (config.field.step + 1) --max field traverse
    c = c + config.field.x + config.field.z --max line traverse
    c = c + (config.field.x + config.field.z) * (config.field.step + 1) + config.field.start
    return c
end

local function printRunOptions(wait)
	term.setCursor(1,5)
	print("R: Toggle Run")
	if redstone then
		print("C: Continuous operation              ")
	else
		print("C: Continuous operation (unavailable)")
	end
	print("Q: Quit program")
	print("Run: "..tostring(run).."  ")
	print("Running: "..tostring(running).."  ")
	print("Continuous: "..tostring(continuous).."  ")
	if wait ~= nil then
		print("Wait for recharge: "..tostring(wait))
	else
        term.clearLine()
    end
end

local function checkEnergy()
    local requiredEnergy = calcMaxMovement() * config.cost.move * 1.4;
    requiredEnergy = requiredEnergy + config.field.x * config.field.z * config.misc.tree * config.cost.hit;
    local maxEnergy = computer.maxEnergy()
    if maxEnergy < requiredEnergy then
        error("Energy storage too small")
        return false
    end
    local wait = 1
    while computer.energy() < requiredEnergy do
        printRunOptions(wait)
		wait = wait + 1
        os.sleep(1)
    end
    return true
end

local function selectEmptySlot()
    for i = 1, 14 do
        if robot.count(i) == 0 then
            robot.select(i)
            return true
        end
    end
    return false
end

local function checkTool()
    local damage, message = robot.durability()
    if damage == nil and message == "no tool equipped" then
        if not selectEmptySlot() then
            error("Could not find an empty slot for tool")
            return false
        end
        robot.suck(1)
        if not ic.equip() then
            error("Could not equip tool")
            return false
        end
	elseif damage == nil and message == "tool cannot be damaged" then --I think this will not happen
		error("Not damage able tool")
    elseif config.misc.min_tool > damage then
		if not selectEmptySlot() then
            error("Could not find an empty slot for tool")
            return false
        end
		if not ic.equip() then
			error("Something is really wrong")
			return false
		end
		robot.dropDown()
		robot.suck(1)
		if not ic.equip() then
            error("Could not equip tool")
            return false
        end
	end			
end

local function isToolPresent()
	local damage, message = robot.durability()
	if damage == nil and message == "no tool equipped" then
		return false
	else
		return true
	end
end

local function countSaplings()
    local old = robot.select()
    robot.select(sapling)
    local saplings = 0
    for i = 1, 14 do 
        if robot.compareTo(i) then
            saplings = saplings + robot.count(i)
        end
    end
    robot.select(old)
    return saplings
end

local function checkSaplings()
    robot.select(1)
    local needed = config.field.x * config.field.z
    while countSaplings() < needed do
        ic.suckFromSlot(sides.front,2)
        os.sleep(1)
    end
end

local function moveFirstTree()
    moveUp(1,true)
    moveForward(config.field.start,true)
end

local function cutTree()
    robot.select(wood)
    robot.swingDown()
    local moved = 0
    while robot.compareUp() do
        robot.swingUp()
        robot.up()
        moved = moved + 1
    end
    for i = 1 , moved do
        robot.down()
    end
end

--[[local function placeSaplingDown()
    robot.select(sapling)
    for i = 1, 14 do
        if robot.compareTo(i) then
            robot.select(i)
            robot.placeDown()
            return
        end
    end
end]]

local function placeSaplingFront()
    robot.select(sapling)
    for i = 1, 14 do
        if robot.compareTo(i) then
            robot.select(i)
            robot.place()
            return
        end
    end
end

local function circleTree()
    robot.turnLeft()
    moveForward(1, false)
    robot.turnRight()
    moveForward(2, false)
    robot.turnRight()
    moveForward(1, false)
    robot.turnLeft()
end

local function replantTree()
    moveForward(1, true)
    robot.turnRight()
    robot.turnRight()
    moveDown(1, true)
    placeSaplingFront()
    moveUp(1, true)
    robot.turnRight()
    robot.turnRight()
end

local function doTreeLineX()
    for i = 1, config.field.x do
        if robot.swing() then
            robot.forward()
            cutTree()
            replantTree()            
        else
            robot.down()
            placeSaplingFront()
            robot.up()
            circleTree()
        end
        
        if i == config.field.x then
            --moveForward(1,true)
        else
            moveForward(config.field.step-1,true)
        end
    end
end

local function dropWood()
	local old = robot.select()
	for i=1, 14 do
		robot.select(i)
		if robot.compareTo(wood) then
			robot.dropDown()
		end
	end
	robot.select(old)
end		

local function singleRun()
    checkEnergy()
    checkTool()
    robot.turnRight()
    checkSaplings()
    moveFirstTree()
    for i = 1, config.field.z do
        doTreeLineX()
		dropWood()
		if not isToolPresent() then
			if i % 2 == 0 then
				moveForward(config.field.start, true) --move to return line
				robot.turnRight()
				moveForward((i - 1) * (config.field.step + 1), true)
				moveDown(1,ture)
				return nil
			else
				robot.turnRight()
				moveForward(1,true)
				robot.turnRight()
				moveForward((config.field.x * (config.field.step + 1)) + config.field.start - 1, true)
				robot.turnRight()
				moveForward((i - 1) * (config.field.step + 1) + 1, true)
				moveDown(1,ture)
				return nil
			end
		end
        if i ~= config.field.z then     --Is End?
            if i % 2 == 0 then
                robot.turnLeft()
                moveForward(config.field.step + 1, true)
                robot.turnLeft()
            else
                robot.turnRight()
                moveForward(config.field.step + 1, true)
                robot.turnRight()
            end
        elseif config.field.z % 2 == 0 then --Return even
            moveForward(config.field.start, true)
            robot.turnRight()
            moveForward((config.field.z - 1) * (config.field.step + 1), true)
            moveDown(1,ture)
        else                                --Return odd
            robot.turnRight()
            moveForward(1,true)
            robot.turnRight()
            moveForward((config.field.x * (config.field.step + 1)) + config.field.start - 1, true)
            robot.turnRight()
            moveForward((config.field.z - 1) * (config.field.step + 1) + 1, true)
            moveDown(1,ture)
        end
    end
end

local function printVersionHead()
	term.clear()
	print("Autotreefarm by Namarius")
	print("Powered by OpenComputers and Lua")
	print("Version "..version.." for "..for_os)
	print()
end

local function toggleRun()
	run = not run
	printRunOptions()
end

local function toggleContinuous()
	continuous = not continuous
	printRunOptions()
end

local function setRunning(runmode)
	if runmode then
		running = true
	else
		running = false
	end
	printRunOptions()
end

local function runFarm()
	printVersionHead()
	printRunOptions()
	while true do
		local event, _, _, code = event.pull()
		if event == "key_down" then
			if code == keyboard.keys.r then
				toggleRun()
			elseif code == keyboard.keys.c then
				toggleContinuous()
			elseif code == keyboard.keys.q then
				return 0
			end
			printRunOptions()
		end
		if run then
			if continuous then
				if redstone.getInput(sides.left) > 0 then
					setRunning(true)
					singleRun()
					setRunning(false)
				end
			else
				toggleRun()
				setRunning(true)
				singleRun()
				setRunning(false)
			end
		end
	end	
end


local function main()
	term.clear()
	print("Autotreefarm by Namarius")
	print("Powered by OpenComputers and Lua")
	print("Version "..version)
	print()
	print(
"Please place a sapling at position 15 and wood at position 16 in the inventory. "..
"The tree farm itself should be right from this robot. "..
"Please provide 3 inventorys with the following items")
	print("Front: Tools (can be battery)")
	print("Right: Saplings (must be barrel)")
	print("Bottom: Used Tools")
	print("If everything is correct please press 1 or q for quit")
	while true do
		local _, _, _, code = event.pull("key_down")
		print(code)
		if code == keyboard.keys["1"] then
			return runFarm()
		elseif code == keyboard.keys.q then
			return 0
		end
	end
end

main()
term.clear()
    