--// CONFIG
local SIZE = 16
local TOTAL_MINES = 40 -- adjust to your board's actual mine count
local folder = workspace:WaitForChild("Lobby"):WaitForChild("MineSweeper")

local player = game:GetService("Players").LocalPlayer
local char = player.Character or player.CharacterAdded:Wait()
local root = char:WaitForChild("HumanoidRootPart")
local humanoid = char:WaitForChild("Humanoid")

--// TELEPORT + JUMP to guarantee TouchInterest fires
local function touch(part)
    if not part or not part.Parent then return end
    root.CFrame = part.CFrame + Vector3.new(0, 3, 0)
    humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
    task.wait(0.01)
end

--// STATE
local grid, tiles
local flagged = {}
local revealed = {}
local tilePos = {}
local currentStatus = 'Starting'
local wins = 0
local fails = 0
local startTime = tick()
local lastRisk = 'N/A'
local totalStuck = 0
local guessCount = 0
local triedGuesses = {}
local lastGuess = nil
local solving = false
local lastRebuild = 0
local gridVersion = 0
local stuckCount = 0
local STUCK_LIMIT = 3
local gameStarted = false  -- true after we've made our first move

--// PHOTO SOLVER
local photoFixed = 0
local photoBad = 0

local picFolder = workspace.Lobby:WaitForChild("picfolder")

local picCache = {}
local picLastClick = {}
local PIC_COOLDOWN = 0.25



local gui = Instance.new("ScreenGui")
gui.Name = "MineSolverUI"
pcall(function() gui.Parent = game:GetService("CoreGui") end)

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0,320,0,270)
frame.Position = UDim2.new(0,20,0,20)
frame.Active = true
frame.Draggable = true
frame.BackgroundColor3 = Color3.fromRGB(25,25,25)
frame.BorderSizePixel = 0
frame.Parent = gui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1,0,0,30)
title.BackgroundTransparency = 1
title.Text = "Minesweeper Solver"
title.TextScaled = true
title.TextColor3 = Color3.new(1,1,1)
title.Parent = frame

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1,0,0,30)
statusLabel.Position = UDim2.new(0,0,0,35)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = Color3.new(1,1,1)
statusLabel.Parent = frame

local flagLabel = statusLabel:Clone()
flagLabel.Position = UDim2.new(0,0,0,65)
flagLabel.Parent = frame

local stuckLabel = statusLabel:Clone()
stuckLabel.Position = UDim2.new(0,0,0,95)
stuckLabel.Parent = frame

local boardLabel = statusLabel:Clone()
boardLabel.Position = UDim2.new(0,0,0,125)
boardLabel.Parent = frame

local statsLabel = statusLabel:Clone()
statsLabel.Position = UDim2.new(0,0,0,155)
statsLabel.Parent = frame

local photoStatusLabel = statusLabel:Clone()
photoStatusLabel.Position = UDim2.new(0,0,0,185)
photoStatusLabel.Parent = frame

local photoFixedLabel = statusLabel:Clone()
photoFixedLabel.Position = UDim2.new(0,0,0,215)
photoFixedLabel.Parent = frame

local function updateGui()
    local flags = 0
    for _,v in pairs(flagged) do
        if v then flags += 1 end
    end

    local rev,cov = countStates and countStates() or 0,0

    local left = math.max(0, cov - flags)
    local progress = math.floor((rev / math.max(1, rev + cov)) * 100)

    statusLabel.Text = "Status: "..tostring(currentStatus)
    flagLabel.Text = string.format("Flags: %d/%d", flags, TOTAL_MINES)
    stuckLabel.Text = string.format("Stuck: %d (%d)", stuckCount or 0, totalStuck or 0)
    local runtime = math.floor(tick() - startTime)
    local wr = (wins + fails) > 0 and math.floor((wins / (wins + fails)) * 100) or 0
    boardLabel.Text = string.format("Risk:%s | Guess:%d | Runtime:%ds", tostring(lastRisk), guessCount or 0, runtime)
    statsLabel.Text = string.format("Wins:%d Fails:%d WR:%d%%", wins, fails, wr)
    photoStatusLabel.Text = string.format("PhotoSolve: %d bad", photoBad)
    photoFixedLabel.Text = string.format("PhotoFixes: %d", photoFixed)
end


--// SAFE TILE ACCESS
local function getTile(x, y)
    local row = grid and grid[y]
    return row and row[x]
end

local function getNeighbors(x, y)
    local t = {}
    for dy = -1, 1 do
        for dx = -1, 1 do
            if not (dx == 0 and dy == 0) then
                local nx, ny = x + dx, y + dy
                local tile = getTile(nx, ny)
                if tile then
                    table.insert(t, { nx, ny, tile })
                end
            end
        end
    end
    return t
end

local function getNumber(tile)
    if not tile or tile.Name ~= "Revealed" then return nil end
    local gui = tile:FindFirstChildOfClass("SurfaceGui")
    local label = gui and gui:FindFirstChild("TextLabel")
    return label and tonumber(label.Text)
end

--// RESET DETECTION — count via grid, not folder
local function countStates()
    local rev, cov = 0, 0
    if not tiles then return 0, 0 end
    for _, t in ipairs(tiles) do
        if t.Name == "Revealed" then rev += 1
        elseif t.Name == "Covered" then cov += 1
        end
    end
    return rev, cov
end

--// OVERLAY GUI (safe — stored by tile reference)
local overlayCache = {}

local function clearOverlays()
    for tile, gui in pairs(overlayCache) do
        if gui and gui.Parent then gui:Destroy() end
    end
    overlayCache = {}
end

local function setOverlay(tile, text, color)
    if not tile or not tile.Parent then return end
    local gui = overlayCache[tile]
    if not gui then
        gui = Instance.new("SurfaceGui")
        gui.Name = "SolverGui"
        gui.AlwaysOnTop = true
        gui.Face = Enum.NormalId.Top
        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, 0, 1, 0)
        label.BackgroundTransparency = 1
        label.TextScaled = true
        label.Font = Enum.Font.SourceSansBold
        label.Parent = gui
        gui.Parent = tile
        overlayCache[tile] = gui
    end
    local label = gui:FindFirstChildOfClass("TextLabel")
    if label then
        label.Text = text or ""
        label.TextColor3 = color or Color3.new(1, 1, 1)
    end
end


local function picAligned(p)
    local r = p.Orientation
    return math.round(r.X) == 0 and math.round(r.Y) == 0 and math.round(r.Z) == 0
end

local function refreshPics()
    table.clear(picCache)
    for _, v in ipairs(picFolder:GetChildren()) do
        if v:IsA("BasePart") then
            picCache[#picCache + 1] = v
        end
    end
end

picFolder.ChildAdded:Connect(refreshPics)
picFolder.ChildRemoved:Connect(refreshPics)
refreshPics()

local function updatePhotoSolver()
    local now = tick()
    photoBad = 0

    for i = 1, #picCache do
        local p = picCache[i]

        if p and p.Parent and not picAligned(p) then
            photoBad += 1

            local last = picLastClick[p] or 0
            if now - last >= PIC_COOLDOWN then
                local cd = p:FindFirstChildOfClass("ClickDetector")
                if cd then
                    fireclickdetector(cd)
                    picLastClick[p] = now
                    photoFixed += 1
                end
            end
        end
    end
end

--// BUILD GRID
local function rebuild()
    currentStatus = "Rebuilding"
    gridVersion += 1
    local myVersion = gridVersion

    clearOverlays()
    tiles = {}
    grid = {}
    flagged = {}
    revealed = {}
    tilePos = {}

    repeat task.wait(0.05) until #folder:GetChildren() >= SIZE * SIZE or myVersion ~= gridVersion
    if myVersion ~= gridVersion then return end

    for _, v in ipairs(folder:GetChildren()) do
        if v:IsA("BasePart") then
            table.insert(tiles, v)
        end
    end

    if #tiles < SIZE * SIZE then
        warn("⚠️ Not enough tiles:", #tiles)
        return
    end

    table.sort(tiles, function(a, b)
        if math.abs(a.Position.Z - b.Position.Z) < 1 then
            return a.Position.X < b.Position.X
        end
        return a.Position.Z < b.Position.Z
    end)

    local i = 1
    for y = 1, SIZE do
        grid[y] = {}
        for x = 1, SIZE do
            grid[y][x] = tiles[i]
            tilePos[tiles[i]] = {x, y}
            i += 1
        end
    end

    lastRebuild = tick()
    stuckCount = 0
    gameStarted = false
    print("✅ Rebuilt v" .. gridVersion .. " (" .. #tiles .. " tiles)")
end

rebuild()

--// OPENING MOVE — touch all 4 corners to open up the board
--  Corners are almost never mines; this guarantees some revealed numbers to work from.
local function doOpeningMoves()
    currentStatus = "Opening"
    local corners = {
        getTile(1, 1),
        getTile(SIZE, 1),
        getTile(1, SIZE),
        getTile(SIZE, SIZE),
    }
    for _, tile in ipairs(corners) do
        if tile and tile.Name == "Covered" then
            touch(tile)
            task.wait(0.05)
        end
    end
    gameStarted = true
end

--// WATCH FOR BOARD RESETS — only meaningful after we've started playing
local rebuildDebounce = false
folder.ChildAdded:Connect(function()
    if not gameStarted then return end  -- ignore churn before first move
    if rebuildDebounce then return end
    rebuildDebounce = true
    task.delay(0.3, function()
        rebuildDebounce = false
        local rev, _ = countStates()
        if rev <= 1 then
            rebuild()
        end
    end)
end)

--// BOARD COMPLETION — true when no covered non-flagged tiles remain
local function isBoardComplete()
    if not tiles then return false end
    for _, t in ipairs(tiles) do
        if t.Name == "Covered" and not flagged[t] then
            return false
        end
    end
    return true
end

--// TILE POSITION INDEX — rebuilt alongside grid so we can look up (x,y) from a tile part

--// CASCADE RISK — prefer tiles that border at least one numbered (>0) revealed tile.
--  These reveal exactly one tile. Tiles that only border blanks (0) cascade and
--  reveal many tiles at once, which is bad for per-tile scoring.
local function bordersNumberedTile(tile)
    local pos = tilePos[tile]
    if not pos then return false end
    for _, n in ipairs(getNeighbors(pos[1], pos[2])) do
        local num = getNumber(n[3])
        if num and num > 0 then return true end
    end
    return false
end
local function buildConstraints()
    local constraints = {}

    for y = 1, SIZE do
        for x = 1, SIZE do
            local tile = getTile(x, y)
            local num = getNumber(tile)
            if not num then continue end

            local neighbors = getNeighbors(x, y)
            local covered = {}
            local flagCount = 0

            for _, n in ipairs(neighbors) do
                local t = n[3]
                if flagged[t] then
                    flagCount += 1
                elseif t.Name == "Covered" then
                    table.insert(covered, t)
                end
            end

            local remainingMines = num - flagCount
            if #covered > 0 and remainingMines >= 0 then
                table.insert(constraints, {
                    tiles = covered,
                    mines = remainingMines,
                    x = x,
                    y = y,
                })
            end
        end
    end

    return constraints
end

--// SUBSET CONSTRAINT SOLVING (A - B = difference)
local function isSubset(small, large)
    for _, t in ipairs(small) do
        if not table.find(large, t) then return false end
    end
    return true
end

local function solveConstraints(constraints)
    local madeProgress = false

    for i = 1, #constraints do
        local A = constraints[i]
        for j = 1, #constraints do
            if i == j then continue end
            local B = constraints[j]

            -- Check if B ⊆ A
            if #B.tiles < #A.tiles and isSubset(B.tiles, A.tiles) then
                local diff = {}
                for _, t in ipairs(A.tiles) do
                    if not table.find(B.tiles, t) then
                        table.insert(diff, t)
                    end
                end

                local mineDiff = A.mines - B.mines

                if mineDiff == 0 and #diff > 0 then
                    -- All tiles in diff are safe — reveal numbered-bordered ones first
                    table.sort(diff, function(a, b)
                        local an = bordersNumberedTile(a) and 0 or 1
                        local bn = bordersNumberedTile(b) and 0 or 1
                        return an < bn
                    end)
                    for _, t in ipairs(diff) do
                        if not flagged[t] and t.Name == "Covered" then
                            touch(t)
                            madeProgress = true
                        end
                    end
                elseif mineDiff == #diff and #diff > 0 then
                    -- All tiles in diff are mines
                    for _, t in ipairs(diff) do
                        if not flagged[t] then
                            flagged[t] = true
                            madeProgress = true
                        end
                    end
                end
            end
        end
    end

    return madeProgress
end

--// GLOBAL MINE BUDGET PROBABILITY
--  Uses: P(tile is mine) weighted by all constraints + global remaining budget
local function calculateProbabilities(constraints)
    local probs = {}    -- sum of per-constraint risk
    local counts = {}   -- how many constraints touched this tile

    -- Count flagged mines already placed
    local flaggedCount = 0
    for _, v in pairs(flagged) do
        if v then flaggedCount += 1 end
    end

    -- Global unconstrained covered tiles
    local allCovered = {}
    for _, t in ipairs(tiles) do
        if t.Name == "Covered" and not flagged[t] then
            table.insert(allCovered, t)
        end
    end

    -- Global fallback risk (budget approach)
    local minesLeft = TOTAL_MINES - flaggedCount
    local globalRisk = #allCovered > 0 and (minesLeft / #allCovered) or 0.5

    -- Per-constraint risk
    for _, c in ipairs(constraints) do
        if #c.tiles > 0 and c.mines >= 0 then
            local risk = c.mines / #c.tiles
            for _, t in ipairs(c.tiles) do
                probs[t] = (probs[t] or 0) + risk
                counts[t] = (counts[t] or 0) + 1
            end
        end
    end

    -- Final: average per-constraint risk, fallback to global for unconstrained tiles
    local final = {}
    for _, t in ipairs(allCovered) do
        if counts[t] then
            -- Blend constraint estimate with global budget
            local constraintRisk = probs[t] / counts[t]
            final[t] = constraintRisk * 0.8 + globalRisk * 0.2
        else
            -- Unconstrained tile — use global budget risk
            final[t] = globalRisk
        end
    end

    return final
end

--// BEST GUESS (lowest probability mine tile, cascade-safe preferred)
local function makeBestMove(constraints)
    local probs = calculateProbabilities(constraints)

    -- Separate into cascade-safe (borders a number) and cascade-risky buckets
    local bestSafe,   riskSafe   = nil, math.huge
    local bestAny,    riskAny    = nil, math.huge

    for tile, risk in pairs(probs) do
        if risk < riskAny then
            riskAny  = risk
            bestAny  = tile
        end
        if bordersNumberedTile(tile) and risk < riskSafe then
            riskSafe = risk
            bestSafe = tile
        end
    end

    -- Prefer the cascade-safe pick; only fall back to bestAny if none found
    local pick = bestSafe or bestAny
    if pick then
        if pick == lastGuess then
            triedGuesses[pick] = tick()
            return false
        end

        lastGuess = pick
        triedGuesses[pick] = tick()

        lastRisk = string.format("%.0f%%", (bestSafe and riskSafe or riskAny) * 100)
        guessCount += 1
        setOverlay(pick, lastRisk, Color3.fromRGB(255, 200, 0))
        touch(pick)
        return true
    end

    -- Absolute fallback: any covered tile
    for _, t in ipairs(tiles) do
        if t.Name == "Covered" and not flagged[t] then
            touch(t)
            return true
        end
    end

    return false
end

--// RESET DETECTION — tiles turn green (BrickColor) when board resets in-place
local FOREST_GREEN = BrickColor.new("Forest green")
local SEA_GREEN    = BrickColor.new("Sea green")

local function isBoardReset()
    if not tiles then return false end
    local greenCount = 0
    for _, t in ipairs(tiles) do
        local bc = t.BrickColor
        if bc == FOREST_GREEN or bc == SEA_GREEN then
            greenCount += 1
        end
    end
    -- Consider reset when the vast majority of tiles are green again
    return greenCount >= SIZE * SIZE * 0.9
end

--// ROUND END DETECTION — triggered by sounds, then wait for server to teleport us away
local roundEnding = false

local function onRoundEnd(reason)
    currentStatus = "Round End"
    if roundEnding then return end
    roundEnding = true
    solving = false
    print("🔔 Round ended (" .. reason .. "), waiting to be teleported out...")

    -- Snapshot where we are right now (on the board)
    local posAtEnd = root.Position

    -- Wait until the server teleports us away (>20 studs from our board position)
    repeat task.wait(0.1) until (root.Position - posAtEnd).Magnitude > 20

    print("🔄 Teleported! Starting next round...")
    task.wait(4)
    roundEnding = false
    rebuild()
    task.wait(0.3)
    doOpeningMoves()
end

local soundFolder = workspace:WaitForChild("Lobby"):WaitForChild("MinesweeperCenter")
soundFolder:WaitForChild("badge").Played:Connect(function() wins += 1; onRoundEnd("win") end)
soundFolder:WaitForChild("Rocket").Played:Connect(function() fails += 1; onRoundEnd("death") end)

--// MAIN SOLVE LOOP
task.spawn(function()
    task.wait(0.3)
    doOpeningMoves()

    while true do
        for tile,tm in pairs(triedGuesses) do
            if tick() - tm > 3 then
                triedGuesses[tile] = nil
            end
        end
        local ok, err = pcall(function()

            if not grid or not tiles then return end
            if tick() - lastRebuild < 0.15 then return end
            if solving then return end
            if roundEnding then return end

            if gameStarted then
                local rev, cov = countStates()
                if rev == 0 and cov >= SIZE * SIZE - 5 then
                    rebuild()
                    task.wait(0.3)
                    doOpeningMoves()
                    return
                end
            end

            solving = true
            local didSomething = false
            local myVersion = gridVersion

            --// PASS 1: Basic logic — flag/reveal from number constraints
            for y = 1, SIZE do
                if myVersion ~= gridVersion then solving = false return end
                for x = 1, SIZE do
                    local tile = getTile(x, y)
                    local number = getNumber(tile)
                    if not number then continue end

                    local neighbors = getNeighbors(x, y)
                    local covered = {}
                    local nFlagged = 0

                    for _, n in ipairs(neighbors) do
                        local t = n[3]
                        if flagged[t] then
                            nFlagged += 1
                        elseif t.Name == "Covered" then
                            table.insert(covered, t)
                        end
                    end

                    -- All remaining covered neighbors must be mines
                    if (#covered + nFlagged) == number and #covered > 0 then
                        for _, c in ipairs(covered) do
                            if not flagged[c] then
                                flagged[c] = true
                                didSomething = true
                            end
                        end
                    end

                    -- All mines accounted for — safe to reveal remaining covered
                    -- Prefer tiles bordering a numbered tile (avoids big cascades)
                    if nFlagged == number and #covered > 0 then
                        table.sort(covered, function(a, b)
                            local an = bordersNumberedTile(a) and 0 or 1
                            local bn = bordersNumberedTile(b) and 0 or 1
                            return an < bn
                        end)
                        for _, c in ipairs(covered) do
                            touch(c)
                            didSomething = true
                        end
                    end
                end
            end

            --// PASS 2: Subset constraint propagation
            if myVersion == gridVersion then
                currentStatus = "Constraints"
                local constraints = buildConstraints()
                if solveConstraints(constraints) then
                    didSomething = true
                end

                --// PASS 3: If stuck, make a probabilistic best guess
                if not didSomething then
                    stuckCount += 1
                    totalStuck += 1
                    if stuckCount >= STUCK_LIMIT then
                        stuckCount = 0

                        currentStatus = "Guessing"
                        makeBestMove(buildConstraints())
                    end
                else
                    stuckCount = 0
                end
            end

            solving = false
        end)

        if not ok then
            warn("💥 Solver error:", err)
            solving = false
        end

        updatePhotoSolver()
        pcall(updateGui)
        task.wait(0.03)
    end
end)
