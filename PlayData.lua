local PlayData = class("PlayData")

function PlayData:ctor(hitRank)
    self.hitRank = hitRank
    self.initPoint = {
        combo = 0,
        maxCombo = 0,
        notePitch = 0,
        noteLength = 0,
        measureDeviation = 0,
        beatDeviation = 0,
        noteDeviation = 0,
        rank = {},
    }
    for i, v in ipairs(hitRank) do
        self.initPoint.rank[i] = 0
    end
    self:reset()
end

function PlayData:reset()
    self.playData = {}
    self.pressedPitches = {} -- 如果有按下的键，保存按下事件在_playData中的key
end

function PlayData:getTop()
    return self.playData[#self.playData]
end

function PlayData:getPoint()
    local dataTop = self:getTop()
    if dataTop then
        return dataTop.point
    else
        return self.initPoint
    end
end

function PlayData:handleMiss(event)
    local point = clone(self:getPoint())
    point.combo = 0

    local data = {
        pitch = event:getPitch(),
        tick = event:getTick(),
        point = point,
    }
    table.insert(self.playData, data)
end

function PlayData:handleHit(event, hitType, hitDeviation, rank)
    local point = clone(self:getPoint())
    point.notePitch = point.notePitch + 1
    point.combo = point.combo + 1
    if point.combo > point.maxCombo then
        point.maxCombo = point.combo
    end
    if point[hitType] then
        point[hitType] = point[hitType] + hitDeviation
    end
    point.rank[rank] = point.rank[rank] + 1

    local data = {
        pitch = event:getPitch(),
        tick = event:getTick(),
        point = point,
    }
    table.insert(self.playData, data)
end

function PlayData:handleHitLength(event)
    local point = clone(self:getPoint())
    point.noteLength = point.noteLength + 1

    local data = {
        pitch = event:getPitch(),
        tick = event:getTick(),
        point = point,
    }
    table.insert(self.playData, data)
end

function PlayData:seek(tick)
    for i = #self.playData, 1, -1 do
        if self.playData[i].tick >= tick then
            table.remove(self.playData, i)
        else
            break
        end
    end
    self.pressedPitches = {}
    self.combo = 0
end

return PlayData
