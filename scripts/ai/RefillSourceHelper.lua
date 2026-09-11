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

--- Helper functions for finding a nearby fill source (tank trailer, slurry pit, field edge
--- container) that a slurry/digestate spreader can drive to in order to refill its tank.
--- The list of candidate sources is taken from the sprayer's own fillTypeSources, which the
--- base game already scanned and matched to the sprayer's supported spray types.
---@class RefillSourceHelper
RefillSourceHelper = {}
RefillSourceHelper.debugChannel = CpDebug.DBG_FIELDWORK
-- search for fill sources within this distance from the field
RefillSourceHelper.maxDistanceFromField = 20

--- Find the best fill source for a sprayer near the given field.
---@param fieldPolygon Polygon the field boundary. We look for sources on it or close to the boundary.
---@param myVehicle table the vehicle doing the fieldwork, used for distance and to exclude its own vehicles
---@param sprayer table the sprayer implement that needs refilling
---@return table|nil source vehicle
---@return number|nil fill unit index on the source to draw from
---@return table|nil fill root node of the source to drive to
---@return number|nil distance of the source from myVehicle
function RefillSourceHelper:findBestFillSource(fieldPolygon, myVehicle, sprayer)
    if fieldPolygon == nil or #fieldPolygon == 0 then
        CpUtil.errorVehicle(myVehicle, 'Field polygon is nil or empty, can\'t find a fill source to refill from')
        return nil
    end
    if sprayer == nil or sprayer.spec_sprayer == nil then
        CpUtil.errorVehicle(myVehicle, 'No valid sprayer given, can\'t find a fill source to refill from')
        return nil
    end

    local sprayerSpec = sprayer.spec_sprayer
    local seen = {}
    local bestSource, bestFillUnitIndex, bestFillNode
    local minDistance = math.huge

    for _, sprayType in ipairs(sprayerSpec.supportedSprayTypes) do
        local sources = sprayerSpec.fillTypeSources[sprayType]
        if sources then
            for _, src in ipairs(sources) do
                local source = src.vehicle
                local fillUnitIndex = src.fillUnitIndex
                if source and source ~= nil then
                    local key = tostring(source) .. '|' .. tostring(fillUnitIndex)
                    if seen[key] == nil then
                        seen[key] = true
                        local fillNode, distance = self:checkSource(myVehicle, fieldPolygon, source, fillUnitIndex)
                        if fillNode and distance < minDistance then
                            minDistance = distance
                            bestSource = source
                            bestFillUnitIndex = fillUnitIndex
                            bestFillNode = fillNode
                        end
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
    CpUtil.debugVehicle(self.debugChannel, myVehicle,
            'Fill source candidate %s (fill unit %s): on field %s, closest distance %.1f, root vehicle %s, last speed %.1f, CP active %s, fill level %.1f/%.1f',
            CpUtil.getName(source), fillUnitIndex, isOnField and '' or 'NOT', closestDistance,
            rootVehicle and CpUtil.getName(rootVehicle) or 'none', lastSpeed, isCpActive, fillLevel, capacity)
    if isOnField and rootVehicle ~= myVehicle and not isCpActive and lastSpeed < 0.1 and hasFluid then
        local fillRootNode = source:getFillUnitExactFillRootNode(fillUnitIndex)
        if fillRootNode then
            local d = calcDistanceFrom(myVehicle:getAIDirectionNode(), source.rootNode or source.nodeId)
            return fillRootNode, d
        end
    end
    return nil
end
