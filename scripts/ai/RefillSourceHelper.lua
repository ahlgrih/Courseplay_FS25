--[[
This file is part of Courseplay (https://github.com/Courseplay/Courseplay_FS25)
Copyright (C) 2025 Courseplay Dev Team

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
]]

--- Helper functions for finding a nearby fill source (usually a slurry/digestate tank trailer)
--- that a slurry/digestate spreader can drive to in order to refill its tank.
--- The base game does NOT populate the sprayer's fillTypeSources with tank trailers on the map,
--- so we scan all mission vehicles for one that has a fill unit matching the sprayer's spray
--- types, that actually contains fluid, and that is stopped near the field.
---@class RefillSourceHelper
RefillSourceHelper = {}
RefillSourceHelper.debugChannel = CpDebug.DBG_FIELDWORK
-- search for fill sources within this distance from the field
RefillSourceHelper.maxDistanceFromField = 20
-- sideways offset (m) kept between the vehicle and the tanker while driving alongside, clamped to this range.
-- In reality the two vehicles would be bridged with a hose, so this is the hose working distance.
RefillSourceHelper.refillSidewaysOffsetMin = 3
RefillSourceHelper.refillSidewaysOffsetMax = 5

--- Find the best fill source for a sprayer near the given field.
---@param fieldPolygon Polygon the field boundary. We look for sources on it or close to the boundary.
--- Like SelfUnloadHelper:findBestTrailer, it must not be nil/empty.
---@param myVehicle table the vehicle doing the fieldwork, used for distance and to exclude its own vehicles
---@param sprayer table the sprayer implement that needs refilling
---@return table|nil source vehicle
---@return number|nil fill unit index on the source to draw from
---@return table|nil fill root node of the source to drive to
---@return number|nil distance of the source from myVehicle
function RefillSourceHelper:findBestFillSource(fieldPolygon, myVehicle, sprayer)
    if sprayer == nil or sprayer.spec_sprayer == nil then
        CpUtil.errorVehicle(myVehicle, 'No valid sprayer given, can\'t find a fill source to refill from')
        return nil
    end
    if fieldPolygon == nil or #fieldPolygon == 0 then
        CpUtil.errorVehicle(myVehicle, 'Field polygon is nil or empty, can\'t find a fill source to refill from')
        return nil
    end

    local sprayerSpec = sprayer.spec_sprayer
    -- the fill types this sprayer can be refilled with (e.g. LIQUIDMANURE, DIGESTATE)
    local wantedFillTypes = {}
    for _, sprayType in ipairs(sprayerSpec.supportedSprayTypes) do
        wantedFillTypes[sprayType] = true
    end

    local bestSource, bestFillUnitIndex, bestFillNode
    local minDistance = math.huge

    for _, otherVehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        if otherVehicle ~= sprayer and otherVehicle.getFillUnits then
            local fillUnits = otherVehicle:getFillUnits()
            for i = 1, #fillUnits do
                local canSupply = false
                if otherVehicle.getFillUnitSupportsFillType then
                    for sprayType, _ in pairs(wantedFillTypes) do
                        if otherVehicle:getFillUnitSupportsFillType(i, sprayType) then
                            canSupply = true
                            break
                        end
                    end
                end
                if canSupply then
                    local fillNode, distance = self:checkSource(myVehicle, fieldPolygon, otherVehicle, i)
                    if fillNode and distance < minDistance then
                        minDistance = distance
                        bestSource = otherVehicle
                        bestFillUnitIndex = i
                        bestFillNode = fillNode
                    end
                end
            end
        end
    end

    if bestSource then
        CpUtil.debugVehicle(self.debugChannel, myVehicle,
                'Best fill source is %s (fill unit %s) at %.1f m',
                CpUtil.getName(bestSource), bestFillUnitIndex, minDistance)
        return bestSource, bestFillUnitIndex, bestFillNode, minDistance
    else
        CpUtil.debugVehicle(self.debugChannel, myVehicle, 'Found no fill source to refill from.')
        return nil
    end
end

--- Check a single source vehicle and return the fill node to drive to if it is usable, otherwise nil.
---@param myVehicle table
---@param fieldPolygon Polygon
---@param source table source vehicle
---@param fillUnitIndex number fill unit on the source to draw from
---@return table|nil fill root node to drive to
---@return number|nil distance from myVehicle
function RefillSourceHelper:checkSource(myVehicle, fieldPolygon, source, fillUnitIndex)
    if source.rootNode == nil then
        return nil
    end
    local rootVehicle = source:getRootVehicle()
    local lastSpeed = rootVehicle and rootVehicle:getLastSpeed() or 0
    local isCpActive = rootVehicle and rootVehicle.getIsCpActive and rootVehicle:getIsCpActive()
    local x, _, z = getWorldTranslation(source.rootNode)
    local isOnField, closestDistance = CpMathUtil.isWithinDistanceToPolygon(fieldPolygon, x, z, RefillSourceHelper.maxDistanceFromField)
    if not isOnField then
        isOnField = CpMathUtil.isPointInPolygon(fieldPolygon, x, z)
    end
    local capacity = source:getFillUnitCapacity(fillUnitIndex)
    local fillLevel = source:getFillUnitFillLevel(fillUnitIndex)
    local hasFluid = capacity > 0 and fillLevel > 0
    local isInvalidAdTarget = rootVehicle and rootVehicle.ad and rootVehicle.ad.stateModule
            and rootVehicle.ad.stateModule:isActive() and not rootVehicle.ad.drivePathModule:isTargetReached()
    CpUtil.debugVehicle(self.debugChannel, myVehicle,
            'Fill source candidate %s (fill unit %s): on field %s, closest distance %.1f, root vehicle %s, last speed %.1f, CP active %s, AD target %s, fill level %.1f/%.1f',
            CpUtil.getName(source), fillUnitIndex, isOnField and '' or 'NOT', closestDistance,
            rootVehicle and CpUtil.getName(rootVehicle) or 'none', lastSpeed, isCpActive, isInvalidAdTarget and 'yes' or 'no', fillLevel, capacity)
    if isOnField and rootVehicle ~= myVehicle and not isCpActive and lastSpeed < 0.1 and hasFluid and not isInvalidAdTarget then
        local fillRootNode = source:getFillUnitExactFillRootNode(fillUnitIndex)
        if fillRootNode then
            local d = calcDistanceFrom(myVehicle:getAIDirectionNode(), source.rootNode or source.nodeId)
            return fillRootNode, d
        end
    end
    return nil
end

--- Compute the approach geometry for driving to a fill source, modeled on
--- SelfUnloadHelper:getTargetParameters. Returns the target node to drive to, the
--- distance to pathfind behind it, and the sideways offset to keep alongside it.
---@param myVehicle table the vehicle doing the fieldwork
---@param source table the fill source vehicle (tanker)
---@param fillRootNode number the fill root node of the source to drive to
---@return number target node to drive to
---@return number alignLength how far behind the target to pathfind
---@return number offsetX sideways offset to keep alongside the target (3-5 m)
---@return table the source vehicle
function RefillSourceHelper:getTargetParameters(myVehicle, source, fillRootNode)
    local targetNode = fillRootNode or source.rootNode
    local sourceLength = source.size and source.size.length or 10
    local sourceWidth = source.size and source.size.width or 4

    -- keep to the side of the source the vehicle is already on, so it doesn't have to cross it
    local dx = localToLocal(myVehicle:getAIDirectionNode(), targetNode, 0, 0, 0)
    local sideSign = dx >= 0 and 1 or -1

    -- sideways offset, clamped to 3-5 m (in reality the two would be bridged with a hose)
    local offsetX = CpMathUtil.clamp(sourceWidth / 2 + myVehicle.size.width / 2 + 1,
            RefillSourceHelper.refillSidewaysOffsetMin, RefillSourceHelper.refillSidewaysOffsetMax)
    offsetX = offsetX * sideSign

    -- how far behind the source to pathfind, so the vehicle can align and drive alongside
    local _, steeringLength = AIUtil.getSteeringParameters(myVehicle)
    local _, frontMarkerOffset = Markers.getFrontMarkerNode(myVehicle)
    local alignLength = (sourceLength / 2) + math.max(myVehicle.size.length / 2 + frontMarkerOffset, steeringLength)

    CpUtil.debugVehicle(self.debugChannel, myVehicle,
            'Refill target: source length %.1f, width %.1f, align length %.1f, offset %.1f (side %s)',
            sourceLength, sourceWidth, alignLength, offsetX, sideSign > 0 and 'left' or 'right')
    return targetNode, alignLength, offsetX, source
end
