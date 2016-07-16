-- RatingSystem.lua

-- hitRadius = 200
-- P Perfect line = 0.75
-- G Great line = 1
-- C LongHit

-- 音准 intonation = (P + G + C) / (all + all_long) %
-- 时值 notevalue = (P + 0.5G) / all %
-- 节奏 rhythm = (P + G) / all %
-- 总分 score = 0.5intonation + 0.25notevalue + 0.25rhythm

local function toIntPercent(float)
    float = float * 100
    if float > 100 then float = 100 end
    if float < 0 then float = 0 end
    if float ~= 0 and float < 0.5 then float = 0.5 end
    if float ~= 100 and float >= 99.5 then float = 99.49 end
    return math.floor(float + 0.5)
end

local RatingSystem = {}


function RatingSystem.getIntonationScore(perfectNumber, greatNumber, longNoteNumber, allNote, allLongNote)
    local num = (perfectNumber + greatNumber + longNoteNumber) / (allNote + allLongNote)
    return toIntPercent(num)
end

function RatingSystem.getNotevalueScore(perfectNumber, greatNumber, allNote)
    local num = (perfectNumber + greatNumber * 0.5) / allNote
    return toIntPercent(num)
end

function RatingSystem.getRhythmScore(perfectNumber, greatNumber, allNote)
    local num = (perfectNumber + greatNumber) / allNote
    return toIntPercent(num)
end

function RatingSystem.getScore(perfectNumber, greatNumber, longNoteNumber, allNote, allLongNote)
    local result = {}
    result.intonation = RatingSystem.getIntonationScore(perfectNumber, greatNumber, longNoteNumber, allNote, allLongNote)
    result.notevalue = RatingSystem.getNotevalueScore(perfectNumber, greatNumber, allNote)
    result.rhythm = RatingSystem.getRhythmScore(perfectNumber, greatNumber, allNote)
    result.score = toIntPercent((result.intonation * 0.5 + result.notevalue * 0.25 + result.rhythm * 0.25) / 100)
    return result
end

function RatingSystem.getScoreFromPoint(point, midiNoteData)
    local perfectNumber = point.rank[1]
    local greatNumber = point.rank[2]
    local longNoteNumber = point.noteLength
    local allNote = midiNoteData.allNote
    local allLongNote = midiNoteData.allLongNote
    return RatingSystem.getScore(perfectNumber, greatNumber, longNoteNumber, allNote, allLongNote)
end

return RatingSystem