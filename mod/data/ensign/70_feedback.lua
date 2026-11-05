-- 70_feedback.lua: rumble and haptics policy. Game events are mapped to short
-- vibration patterns; navigation ticks use the trackpad haptics on hardware that
-- has them (Steam Deck / Steam Controller).
local E = ENSIGN
local F = {}
E.feedback = F

local lastTick = 0
local function strength() return E.settings.rumble end

function F.rumble(left, right, ms)
    if not E.native or strength() <= 0 then return end
    Ensign.rumble(left * strength(), right * strength(), ms)
end

-- small confirmation on navigation
function F.tick()
    if not E.native or E.settings.haptics == 0 then return end
    if E.time - lastTick < 0.03 then return end
    lastTick = E.time
    local _, _, family = Ensign.controllerType()
    if family == "deck" or family == "steam" then Ensign.haptic(3, 40, -6) end
end

local patterns = {
    select = { 0.15, 0.25, 40 },
    hit = { 0.7, 0.9, 160 },
    shield = { 0.2, 0.35, 70 },
    fire = { 0.1, 0.2, 35 },
    jump = { 0.5, 0.5, 350 },
    arrive = { 0.3, 0.2, 180 },
    ftlready = { 0.25, 0.25, 90 },
    boarders = { 0.6, 0.6, 120 },
    crewdeath = { 0.9, 0.5, 400 },
    lowhull = { 0.3, 0.1, 80 },
}
function F.pulse(name)
    local p = patterns[name]
    if p then F.rumble(p[1], p[2], p[3]) end
end

local lastIntruders, lastFtlReady, lastCrewCount = 0, false, nil
local lowHullAt = -100

function F.watch()
    -- polled state changes (cheap, once per tick while in flight)
    local ship = E.playerShip()
    if not ship then lastCrewCount = nil return end
    local ok, intr = pcall(function() return ship.iIntruderCount end)
    if ok and intr and intr > lastIntruders then F.pulse("boarders") end
    if ok and intr then lastIntruders = intr end
    local gui = E.gui()
    local okf, ready = pcall(function() return gui.ftlButton.ready end)
    if okf then
        if ready and not lastFtlReady then F.pulse("ftlready") end
        lastFtlReady = ready and true or false
    end
    local okc, n = pcall(function()
        local c = 0
        local list = ship.vCrewList
        for i = 0, list:size() - 1 do local m = list[i]; if m and not m.bDead and m.iShipId == 0 then c = c + 1 end end
        return c
    end)
    if okc then
        if lastCrewCount and n < lastCrewCount then F.pulse("crewdeath") end
        lastCrewCount = n
    end
    local okh, hull, maxHull = pcall(function() return ship.ship.hullIntegrity.first, ship.ship.hullIntegrity.second end)
    if okh and hull and maxHull and maxHull > 0 then
        if hull < maxHull * 0.3 and E.time - lowHullAt > 4 then lowHullAt = E.time; F.pulse("lowhull") end
    end
end

function F.registerEvents()
    if not script then return end
    -- a projectile actually hits our hull
    script.on_internal_event(Defines.InternalEvents.DAMAGE_AREA_HIT, function(shipManager, projectile, location, damage, forceHit)
        pcall(function()
            if shipManager and shipManager.iShipId == 0 then
                local d = damage and damage.iDamage or 1
                F.rumble(math.min(1, 0.4 + 0.2 * d), math.min(1, 0.6 + 0.2 * d), 120 + 40 * d)
            end
        end)
        return Defines.Chain.CONTINUE
    end)
    -- our shields absorb a shot
    script.on_internal_event(Defines.InternalEvents.SHIELD_COLLISION, function(shipManager, projectile, damage, response)
        pcall(function() if shipManager and shipManager.iShipId == 0 then F.pulse("shield") end end)
        return Defines.Chain.CONTINUE
    end)
    -- our weapons fire
    script.on_internal_event(Defines.InternalEvents.PROJECTILE_FIRE, function(projectile, weapon)
        pcall(function() if projectile and projectile.ownerId == 0 then F.pulse("fire") end end)
        return Defines.Chain.CONTINUE
    end)
    script.on_internal_event(Defines.InternalEvents.JUMP_LEAVE, function(shipManager)
        pcall(function() if shipManager and shipManager.iShipId == 0 then F.pulse("jump") end end)
    end)
    script.on_internal_event(Defines.InternalEvents.JUMP_ARRIVE, function(shipManager)
        pcall(function() if shipManager and shipManager.iShipId == 0 then F.pulse("arrive") end end)
        lastIntruders = 0
    end)
end
