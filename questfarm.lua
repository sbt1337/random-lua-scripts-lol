-- Kanom Tokyo | Quest Autofarm (Ghoul - Nishiki)
-- Nothing blocks at top level — all remotes resolved after player Loaded

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer       = Players.LocalPlayer

-- These are nil until init completes; loops wait on Initialized
local QuestNet       = nil
local UseSkillRemote = nil
local StatBridge     = nil
local Initialized    = false

-- Shared modules (safe to require immediately — they don't depend on Network)
local BridgeNet2  = require(ReplicatedStorage.Modules.Library.BridgeNet2)
local ReplicaCtrl = require(ReplicatedStorage.ReplicaController)

-- Config
local DEFAULT_SKILL_CD = 8
local BOARD_POS        = Vector3.new(-240, 34, 208)
local UNDER_DEPTH      = 5
local ATTACK_DIST      = 10
local StatOrder        = { "Damage", "Durability" }

-- Runtime state
local Running        = true
local AvailableQuests = {}
local CompletedUIDs  = {}
local CurrentQuest   = nil
local QuestDone      = false
local ShouldRepick   = false
local PlayerLevel    = 1
local StatPoints     = 0
local StatIdx        = 1
local SkillCooldowns = {}

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
    local underPos = hrp.Position - Vector3.new(0, UNDER_DEPTH, 0)
    r.CFrame = CFrame.new(underPos, hrp.Position)
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
        QuestNet:FireServer("RequestQuest", best.mod, best.q.UID)
    else
        print("[QF] No suitable quest right now")
    end
end

-- Replica (safe to set up immediately — doesn't touch Network) -----------------
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

-- Quest board data bridge (safe to connect immediately) ------------------------
BridgeNet2.ClientBridge("QuestData"):Connect(function(payload)
    AvailableQuests = payload[1] or {}
    CompletedUIDs   = {}
    for _, q in AvailableQuests do
        if q.isCompleted then CompletedUIDs[q.UID] = true end
    end
    ShouldRepick = true
    print("[QF] Quest board refreshed —", #AvailableQuests, "quests")
end)

-- Re-equip on respawn ----------------------------------------------------------
LocalPlayer.CharacterAdded:Connect(function()
    task.wait(3)
    repeat task.wait(0.2) until LocalPlayer:GetAttribute("Loaded")
    EquipKagune()
    print("[QF] Respawned — kagune equipped")
end)

-- Init: resolve Network remotes after player is fully loaded -------------------
task.spawn(function()
    repeat task.wait(0.5) until LocalPlayer:GetAttribute("Loaded") and LocalPlayer:GetAttribute("Team")
    print("[QF] Player loaded. Resolving Network remotes...")

    local Network = ReplicatedStorage:FindFirstChild("Network")
    if not Network then
        -- poll until it appears (server creates it at runtime)
        repeat task.wait(0.5)
            Network = ReplicatedStorage:FindFirstChild("Network")
        until Network
    end
    print("[QF] Network folder found. Waiting for remotes...")

    -- Dump every child of Network so we can see the real names
    print("[QF] Network children:")
    for _, child in Network:GetChildren() do
        print("  >>", child.Name, "|", child.ClassName)
    end
    -- Also watch for anything added later
    Network.ChildAdded:Connect(function(child)
        print("[QF] Network.ChildAdded:", child.Name, "|", child.ClassName)
    end)

    -- poll for each remote individually so we can report which one is missing
    local deadline = tick() + 30
    repeat task.wait(0.5)
        QuestNet       = Network:FindFirstChild("Quest")
        UseSkillRemote = Network:FindFirstChild("UseSkill")
    until (QuestNet and UseSkillRemote) or tick() > deadline

    if not QuestNet then
        warn("[QF] Quest remote not found after 30s — aborting")
        warn("[QF] Network children at timeout:")
        for _, child in Network:GetChildren() do
            warn("  >>", child.Name, "|", child.ClassName)
        end
        return
    end
    if not UseSkillRemote then
        warn("[QF] UseSkill remote not found after 30s — skills disabled")
    end

    StatBridge = BridgeNet2.ClientBridge("StatUpgrade")

    -- Hook quest events now that QuestNet is valid
    QuestNet.OnClientEvent:Connect(function(ev, ...)
        local a = { ... }
        if ev == "QuestReceived" then
            CurrentQuest = a[1]
            QuestDone    = false
            ShouldRepick = false
            print("[QF] Quest:", CurrentQuest.QuestInfo, "| Goal:", CurrentQuest.Goal)
        elseif ev == "QuestCompleted" then
            print("[QF] Quest complete!")
            QuestDone    = true
            CurrentQuest = nil
        elseif ev == "QuestRemoved" then
            CurrentQuest = nil
            QuestDone    = false
        end
    end)

    Initialized = true
    print("[QF] Init done | Level:", PlayerLevel, "| Team:", LocalPlayer:GetAttribute("Team"))

    EquipKagune()

    -- If no quest data in 3s, TP to board to nudge server
    task.delay(3, function()
        if #AvailableQuests == 0 then
            local r = Root()
            if r then r.CFrame = CFrame.new(BOARD_POS) end
            print("[QF] No quest data — teleported to board")
        end
    end)
end)

-- Stat allocation --------------------------------------------------------------
task.spawn(function()
    repeat task.wait(0.5) until Initialized
    while Running do
        task.wait(0.8)
        while StatPoints > 0 and StatBridge do
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
        if not CurrentQuest or not UseSkillRemote then continue end
        if not LocalPlayer:GetAttribute("isUsingWeapon") then continue end
        local char = Char()
        if not char or char:GetAttribute("SkillDisabled") then continue end
        if not FindEnemy(CurrentQuest.Target) then continue end

        local now = tick()
        for _, name in GetLoadedSkillNames() do
            if (SkillCooldowns[name] or 0) > now then continue end
            local ok, result = pcall(function()
                return UseSkillRemote:InvokeServer(name)
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
