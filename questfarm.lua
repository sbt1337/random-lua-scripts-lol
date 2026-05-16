-- Kanom Tokyo | Quest Autofarm (Ghoul - Nishiki)
-- Uses level-based NPC quest givers, NOT the rotating board system

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer       = Players.LocalPlayer

local BridgeNet2  = require(ReplicatedStorage.Modules.Library.BridgeNet2)
local ReplicaCtrl = require(ReplicatedStorage.ReplicaController)

local QuestBridge    = BridgeNet2.ClientBridge("Quest")
local UseSkillBridge = BridgeNet2.ClientBridge("UseSkill")
local StatBridge     = BridgeNet2.ClientBridge("StatUpgrade")

-- Config
local DEFAULT_SKILL_CD = 8
local UNDER_DEPTH      = 5
local ATTACK_DIST      = 10
local StatOrder        = { "Damage", "Durability" }

-- Level → NPC quest giver name + quest module path
-- module is at ReplicatedStorage.Modules.Client.TalkNpc.Quests[npcName].Quest
local QuestTiers = {
    { min = 1,    max = 49,   npc = "QuestGiver (Lv.1-Lv.50)" },
    { min = 50,   max = 149,  npc = "QuestGiver (Lv.50-Lv.150)" },
    { min = 150,  max = 249,  npc = "QuestGiver (Lv.150-Lv.250)" },
    { min = 250,  max = 349,  npc = "QuestGiver (Lv.250-Lv.350)" },
    { min = 350,  max = 399,  npc = "QuestGiver (Lv.350-Lv.400)" },
    { min = 400,  max = 449,  npc = "QuestGiver (Lv.400-Lv.450)" },
    { min = 450,  max = 499,  npc = "QuestGiver (Lv.450-Lv.500)" },
    { min = 500,  max = 549,  npc = "QuestGiver (Lv.500-Lv.550)" },
    { min = 550,  max = 599,  npc = "QuestGiver (Lv.550-Lv.600)" },
    { min = 600,  max = 699,  npc = "QuestGiver (Lv.600-Lv.700)" },
    { min = 700,  max = 799,  npc = "QuestGiver (Lv.700-Lv.800)" },
    { min = 800,  max = 899,  npc = "QuestGiver (Lv.800-Lv.900)" },
    { min = 900,  max = 999,  npc = "QuestGiver (Lv.900-Lv.1000)" },
    { min = 1000, max = 1099, npc = "QuestGiver (Lv.1000-Lv.1100)" },
    { min = 1100, max = math.huge, npc = "QuestGiver (Lv.1100-Lv.1200)" },
}

-- Runtime state
local Running        = true
local CurrentQuest   = nil   -- {QuestInfo, Goal, Target, Type} from QuestReceived
local QuestDone      = false
local PlayerLevel    = 1
local StatPoints     = 0
local StatIdx        = 1
local SkillCooldowns = {}
local Initialized    = false

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

-- Find the quest module child for the current player level
local function GetQuestModuleForLevel(level)
    local questsFolder = ReplicatedStorage.Modules.Client.TalkNpc.Quests
    for i = #QuestTiers, 1, -1 do   -- iterate highest first so we get the best tier
        local tier = QuestTiers[i]
        if level >= tier.min then
            local npcModule = questsFolder:FindFirstChild(tier.npc)
            if npcModule then
                local questMod = npcModule:FindFirstChild("Quest")
                if questMod then
                    return questMod, tier.npc
                end
            end
        end
    end
    return nil, nil
end

-- Teleport near the NPC quest giver before accepting (server may check proximity)
local function TPNearNPC(npcName)
    local giverFolder = workspace:FindFirstChild("TalkNpc")
    if not giverFolder then return end
    local giverParent = giverFolder:FindFirstChild("QuestGiver")
    if not giverParent then return end
    local npc = giverParent:FindFirstChild(npcName)
    if not npc then return end
    local hrp = npc:FindFirstChild("HumanoidRootPart") or npc.PrimaryPart
    if not hrp then return end
    local r = Root()
    if r then
        r.CFrame = CFrame.new(hrp.Position + Vector3.new(3, 0, 3))
    end
end

local function AcceptQuest()
    local questMod, npcName = GetQuestModuleForLevel(PlayerLevel)
    if questMod then
        print("[QF] Accepting quest from:", npcName)
        TPNearNPC(npcName)
        task.wait(0.3)
        QuestBridge:Fire({ "RequestQuest", questMod })
    else
        print("[QF] No quest module found for level", PlayerLevel)
    end
end

-- Replica: level + stat points -------------------------------------------------
ReplicaCtrl.ReplicaOfClassCreated("DataToken_" .. LocalPlayer.UserId, function(replica)
    local team = LocalPlayer:GetAttribute("Team") or "GHOUL"
    local data = replica.Data[team]
    if not data then return end
    PlayerLevel = data.Level or 1
    StatPoints  = data.StatPoint or 0
    replica:ListenToChange({ "Level" }, function(v)
        PlayerLevel = v
        -- If we crossed a tier boundary mid-quest, abandon and re-accept
        -- (handled automatically: AcceptQuest uses current PlayerLevel)
    end)
    replica:ListenToChange({ "StatPoint" }, function(v)
        StatPoints = v
    end)
end)

-- Quest event bridge
QuestBridge:Connect(function(data)
    local ev = data[1]
    if ev == "QuestReceived" then
        CurrentQuest = data[2]
        QuestDone    = false
        if CurrentQuest then
            print("[QF] Quest:", CurrentQuest.QuestInfo, "| Goal:", CurrentQuest.Goal)
        end
    elseif ev == "QuestCompleted" then
        print("[QF] Complete! Re-accepting immediately...")
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

-- Init gate
task.spawn(function()
    repeat task.wait(0.5) until LocalPlayer:GetAttribute("Loaded") and LocalPlayer:GetAttribute("Team")
    print("[QF] Ready | Level:", PlayerLevel, "| Team:", LocalPlayer:GetAttribute("Team"))
    EquipKagune()
    Initialized = true
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

        -- Accept / re-accept quest
        if not CurrentQuest then
            AcceptQuest()
            task.wait(1.5)
            continue
        end

        -- Brief rest after complete then instantly re-accept same tier
        if QuestDone then
            task.wait(1)
            QuestDone = false
            continue
        end

        -- Attack enemies
        if CurrentQuest.Target then
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
