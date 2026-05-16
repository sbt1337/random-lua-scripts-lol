-- Kanom Tokyo | Quest Autofarm (Ghoul - Nishiki)
-- All networking via BridgeNet2 (Network folder is GUID-named, no plain "Quest" child)

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer       = Players.LocalPlayer

local BridgeNet2  = require(ReplicatedStorage.Modules.Library.BridgeNet2)
local ReplicaCtrl = require(ReplicatedStorage.ReplicaController)

-- BridgeNet2 bridges (resolved immediately — just a GUID lookup, no yielding)
local QuestBridge    = BridgeNet2.ClientBridge("Quest")
local UseSkillBridge = BridgeNet2.ClientBridge("UseSkill")
local StatBridge     = BridgeNet2.ClientBridge("StatUpgrade")
local QuestDataBridge = BridgeNet2.ClientBridge("QuestData")

-- Config
local DEFAULT_SKILL_CD = 8
local BOARD_POS        = Vector3.new(-240, 34, 208)
local UNDER_DEPTH      = 5
local ATTACK_DIST      = 10
local StatOrder        = { "Damage", "Durability" }

-- Runtime state
local Running         = true
local AvailableQuests = {}
local CompletedUIDs   = {}
local CurrentQuest    = nil
local QuestDone       = false
local ShouldRepick    = false
local PlayerLevel     = 1
local StatPoints      = 0
local StatIdx         = 1
local SkillCooldowns  = {}
local Initialized     = false

-- Helpers ----------------------------------------------------------------------
local function Char() return LocalPlayer.Character end
local function Root()
    local c = Char()
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function FindEnemy(targets)
    local r = Root()
    if not r then return nil end
    local ok, folder = pcall(function() return workspace["AI/Player"] end)
    if not ok or not folder then return nil end
    local best, bestDist = nil, math.huge
    for _, m in folder:GetChildren() do
        if not m:IsA("Model") or not table.find(targets, m.Name) then continue end
        local hrp = m:FindFirstChild("HumanoidRootPart")
        local hum = m:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum or hum.Health <= 0 then continue end
        local d = (r.Position - hrp.Position).Magnitude
        if d < bestDist then bestDist = d; best = m end
    end
    return best
end

local function TPUnderEnemy(hrp)
    local r = Root()
    if not r then return end
    r.CFrame = CFrame.new(hrp.Position - Vector3.new(0, UNDER_DEPTH, 0), hrp.Position)
end

local function EquipKagune()
    if not LocalPlayer:GetAttribute("isUsingWeapon") and _G.ToggleWeapon then
        _G.ToggleWeapon()
        task.wait(0.5)
    end
end

local function GetLoadedSkillNames()
    local names  = {}
    local folder = ReplicatedStorage:FindFirstChild("Inputs")
    folder = folder and folder:FindFirstChild("Skills")
    if not folder then return names end
    for _, action in folder:GetChildren() do
        table.insert(names, action.Name)
    end
    return names
end

local function BestQuest()
    if #AvailableQuests == 0 then return nil end
    local QuestBoardDB = ReplicatedStorage.Modules.DataBase.QuestBoard
    local best, bestLv = nil, -1
    for _, q in AvailableQuests do
        if CompletedUIDs[q.UID] then continue end
        local mod = QuestBoardDB:FindFirstChild(q.QuestName, true)
        if not mod then continue end
        local ok, data = pcall(require, mod)
        if not ok then continue end
        local targets = data.Target or {}
        if table.find(targets, "Player") then continue end
        local lv = data.LevelRequired or 0
        if lv <= PlayerLevel and lv > bestLv then
            bestLv = lv
            best = { q = q, mod = mod, info = data.QuestInfo }
        end
    end
    return best
end

local function AcceptBestQuest()
    local best = BestQuest()
    if best then
        print("[QF] Accepting:", best.info)
        -- Quest:FireServer("RequestQuest", moduleRef, uid)
        QuestBridge:Fire({ "RequestQuest", best.mod, best.q.UID })
    else
        print("[QF] No suitable quest available")
    end
end

-- Replica: level + stat points (safe immediately, no Network dependency) -------
ReplicaCtrl.ReplicaOfClassCreated("DataToken_" .. LocalPlayer.UserId, function(replica)
    local team = LocalPlayer:GetAttribute("Team") or "GHOUL"
    local data = replica.Data[team]
    if not data then return end
    PlayerLevel = data.Level or 1
    StatPoints  = data.StatPoint or 0
    replica:ListenToChange({ "Level" }, function(v)
        if v > PlayerLevel then ShouldRepick = true end
        PlayerLevel = v
    end)
    replica:ListenToChange({ "StatPoint" }, function(v)
        StatPoints = v
    end)
end)

-- Quest board data bridge
QuestDataBridge:Connect(function(payload)
    AvailableQuests = payload[1] or {}
    CompletedUIDs   = {}
    for _, q in AvailableQuests do
        if q.isCompleted then CompletedUIDs[q.UID] = true end
    end
    ShouldRepick = true
    print("[QF] Board refreshed —", #AvailableQuests, "quests")
end)

-- Quest event bridge: server sends {eventType, ...args}
QuestBridge:Connect(function(data)
    local ev = data[1]
    if ev == "QuestReceived" then
        CurrentQuest = data[2]
        QuestDone    = false
        ShouldRepick = false
        if CurrentQuest then
            print("[QF] Quest:", CurrentQuest.QuestInfo, "| Goal:", CurrentQuest.Goal)
        end
    elseif ev == "QuestCompleted" then
        print("[QF] Quest complete!")
        QuestDone    = true
        CurrentQuest = nil
    elseif ev == "QuestRemoved" then
        CurrentQuest = nil
        QuestDone    = false
    elseif ev == "QuestProgress" then
        print("[QF] Progress:", data[2], "/", data[3])
    end
end)

-- Re-equip on respawn
LocalPlayer.CharacterAdded:Connect(function()
    task.wait(3)
    repeat task.wait(0.2) until LocalPlayer:GetAttribute("Loaded")
    EquipKagune()
    print("[QF] Respawned — kagune equipped")
end)

-- Init gate: wait for player loaded, then unlock all loops ---------------------
task.spawn(function()
    repeat task.wait(0.5) until LocalPlayer:GetAttribute("Loaded") and LocalPlayer:GetAttribute("Team")
    print("[QF] Ready | Level:", PlayerLevel, "| Team:", LocalPlayer:GetAttribute("Team"))
    EquipKagune()
    Initialized = true

    task.delay(3, function()
        if #AvailableQuests == 0 then
            local r = Root()
            if r then r.CFrame = CFrame.new(BOARD_POS) end
            print("[QF] No board data yet — teleported to quest board")
        end
    end)
end)

-- Stat allocation --------------------------------------------------------------
task.spawn(function()
    repeat task.wait(0.5) until Initialized
    while Running do
        task.wait(0.8)
        while StatPoints > 0 do
            local stat = StatOrder[StatIdx]
            StatBridge:Fire({ { stat, 1 } })
            StatIdx    = (StatIdx % #StatOrder) + 1
            StatPoints -= 1
            task.wait(0.3)
        end
    end
end)

-- Skill loop -------------------------------------------------------------------
task.spawn(function()
    repeat task.wait(0.5) until Initialized
    while Running do
        task.wait(0.2)
        if not CurrentQuest then continue end
        if not LocalPlayer:GetAttribute("isUsingWeapon") then continue end
        local char = Char()
        if not char or char:GetAttribute("SkillDisabled") then continue end
        if not FindEnemy(CurrentQuest.Target) then continue end

        local now = tick()
        for _, name in GetLoadedSkillNames() do
            if (SkillCooldowns[name] or 0) > now then continue end
            local ok, result = pcall(function()
                return UseSkillBridge:InvokeServerAsync(name)
            end)
            if ok and result then
                SkillCooldowns[name] = now + DEFAULT_SKILL_CD
                print("[QF] Skill:", name)
            elseif not ok then
                SkillCooldowns[name] = now + 2
            end
            task.wait(0.1)
        end
    end
end)

-- Main attack loop -------------------------------------------------------------
task.spawn(function()
    repeat task.wait(0.5) until Initialized
    while Running do
        local char = Char()
        if not char or not Root() then task.wait(1) continue end

        if not CurrentQuest and not QuestDone then
            if #AvailableQuests > 0 then
                AcceptBestQuest()
                task.wait(1.5)
            else
                task.wait(2)
            end
            continue
        end

        if QuestDone then
            task.wait(2)
            QuestDone    = false
            ShouldRepick = true
            continue
        end

        if ShouldRepick and not CurrentQuest then
            ShouldRepick = false
            AcceptBestQuest()
            task.wait(1.5)
            continue
        end

        if CurrentQuest and CurrentQuest.Target then
            EquipKagune()
            local enemy = FindEnemy(CurrentQuest.Target)
            if enemy then
                local hrp = enemy:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local r = Root()
                    if r and (r.Position - hrp.Position).Magnitude > ATTACK_DIST then
                        TPUnderEnemy(hrp)
                    end
                    if _G.Attack then _G.Attack() else task.wait(0.1) end
                end
            else
                task.wait(0.4)
            end
        else
            task.wait(0.5)
        end
    end
end)

print("[QF] Script executing...")
