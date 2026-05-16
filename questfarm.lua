-- Kanom Tokyo | Quest Autofarm (Ghoul - Nishiki)
-- Discovers the real Quest bridge name from BridgeNet2 identifierStorage at runtime

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer       = Players.LocalPlayer

local BridgeNet2  = require(ReplicatedStorage.Modules.Library.BridgeNet2)
local ReplicaCtrl = require(ReplicatedStorage.ReplicaController)

-- Config
local DEFAULT_SKILL_CD = 8
local UNDER_DEPTH      = 5
local ATTACK_DIST      = 10
local StatOrder        = { "Damage", "Durability" }

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
local CurrentQuest   = nil
local QuestDone      = false
local PlayerLevel    = 1
local StatPoints     = 0
local StatIdx        = 1
local SkillCooldowns = {}
local Initialized    = false

-- These are resolved inside init — NOT at top level (top-level BridgeNet2.ClientBridge
-- calls fire immediately and time out after 3s if the server hasn't registered yet)
local QuestBridge    = nil
local UseSkillBridge = nil
local StatBridge     = nil

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

local LastEquipAttempt = 0
local function EquipKagune()
    if LocalPlayer:GetAttribute("isUsingWeapon") then return end
    if not _G.ToggleWeapon then return end
    if tick() - LastEquipAttempt < 4 then return end
    LastEquipAttempt = tick()
    _G.ToggleWeapon()
    task.wait(1.5)
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

local function GetQuestModuleForLevel(level)
    local questsFolder = ReplicatedStorage.Modules.Client.TalkNpc.Quests
    for i = #QuestTiers, 1, -1 do
        local tier = QuestTiers[i]
        if level >= tier.min then
            local npcMod = questsFolder:FindFirstChild(tier.npc)
            if npcMod then
                local questMod = npcMod:FindFirstChild("Quest")
                if questMod then return questMod, tier.npc end
            end
        end
    end
    return nil, nil
end

local function TPNearNPC(npcName)
    local talknpc = workspace:FindFirstChild("TalkNpc")
    if not talknpc then return end
    local givers = talknpc:FindFirstChild("QuestGiver")
    if not givers then return end
    local npc = givers:FindFirstChild(npcName)
    if not npc then return end
    local hrp = npc:FindFirstChild("HumanoidRootPart") or npc.PrimaryPart
    if not hrp then return end
    local r = Root()
    if r then r.CFrame = CFrame.new(hrp.Position + Vector3.new(3, 0, 3)) end
end

local function AcceptQuest()
    if not QuestBridge then print("[QF] Quest bridge not ready yet") return end
    local questMod, npcName = GetQuestModuleForLevel(PlayerLevel)
    if questMod then
        print("[QF] Accepting:", npcName)
        TPNearNPC(npcName)
        task.wait(0.3)
        QuestBridge:Fire({ "RequestQuest", questMod })
    else
        print("[QF] No quest module for level", PlayerLevel)
    end
end

-- Replica: level + stat points -------------------------------------------------
ReplicaCtrl.ReplicaOfClassCreated("DataToken_" .. LocalPlayer.UserId, function(replica)
    local team = LocalPlayer:GetAttribute("Team") or "GHOUL"
    local data = replica.Data[team]
    if not data then return end
    PlayerLevel = data.Level or 1
    StatPoints  = data.StatPoint or 0
    replica:ListenToChange({ "Level" }, function(v) PlayerLevel = v end)
    replica:ListenToChange({ "StatPoint" }, function(v) StatPoints = v end)
end)

-- Re-equip on respawn
LocalPlayer.CharacterAdded:Connect(function()
    task.wait(4)
    repeat task.wait(0.2) until LocalPlayer:GetAttribute("Loaded")
    LastEquipAttempt = 0
    EquipKagune()
    print("[QF] Respawned — kagune equip attempted")
end)

-- Init: resolve all bridges AFTER player is loaded ----------------------------
task.spawn(function()
    repeat task.wait(0.5) until LocalPlayer:GetAttribute("Loaded") and LocalPlayer:GetAttribute("Team")

    -- Give the server a moment to register all bridges into identifierStorage
    task.wait(2)

    -- Read BridgeNet2 identifierStorage to find real bridge names
    local bn2Module = ReplicatedStorage.Modules.Library.BridgeNet2
    local idStore   = bn2Module:FindFirstChild("identifierStorage")

    local allBridges = {}
    if idStore then
        for name, _ in idStore:GetAttributes() do
            table.insert(allBridges, name)
            -- Print every bridge so we can debug if needed
        end
        table.sort(allBridges)
        print("[QF] Registered bridges:", table.concat(allBridges, ", "))
    else
        -- identifierStorage might live deeper — wait for it
        idStore = bn2Module:WaitForChild("identifierStorage", 10)
        if idStore then
            for name, _ in idStore:GetAttributes() do
                table.insert(allBridges, name)
            end
            print("[QF] Registered bridges:", table.concat(allBridges, ", "))
        else
            warn("[QF] identifierStorage not found — can't auto-detect bridge names")
        end
    end

    -- Find the quest bridge: look for "quest" (case-insensitive) in registered names
    local questBridgeName, useSkillBridgeName, statBridgeName
    for _, name in allBridges do
        local lower = name:lower()
        if lower == "quest" or lower:find("^quest$") then
            questBridgeName = name
        elseif lower:find("quest") and not lower:find("data") then
            -- fallback: any quest-related bridge that isn't QuestData (the board)
            questBridgeName = questBridgeName or name
        end
        if lower:find("skill") or lower:find("useskill") then
            useSkillBridgeName = name
        end
        if lower:find("statupgrade") or lower:find("stat") then
            statBridgeName = name
        end
    end

    -- Fallback names in case auto-detection misses
    questBridgeName    = questBridgeName    or "Quest"
    useSkillBridgeName = useSkillBridgeName or "UseSkill"
    statBridgeName     = statBridgeName     or "StatUpgrade"

    print("[QF] Using bridges — Quest:", questBridgeName, "| Skill:", useSkillBridgeName, "| Stat:", statBridgeName)

    QuestBridge    = BridgeNet2.ClientBridge(questBridgeName)
    UseSkillBridge = BridgeNet2.ClientBridge(useSkillBridgeName)
    StatBridge     = BridgeNet2.ClientBridge(statBridgeName)

    -- Hook quest events
    QuestBridge:Connect(function(data)
        local ev = data[1]
        if ev == "QuestReceived" then
            CurrentQuest = data[2]
            QuestDone    = false
            if CurrentQuest then
                print("[QF] Quest:", CurrentQuest.QuestInfo, "| Goal:", CurrentQuest.Goal)
            end
        elseif ev == "QuestCompleted" then
            print("[QF] Complete!")
            QuestDone    = true
            CurrentQuest = nil
        elseif ev == "QuestRemoved" then
            CurrentQuest = nil
            QuestDone    = false
        elseif ev == "QuestProgress" then
            print("[QF] Progress:", data[2], "/", data[3])
        end
    end)

    Initialized = true
    print("[QF] Ready | Level:", PlayerLevel, "| Team:", LocalPlayer:GetAttribute("Team"))
    EquipKagune()
end)

-- Stat allocation --------------------------------------------------------------
task.spawn(function()
    repeat task.wait(0.5) until Initialized
    while Running do
        task.wait(0.8)
        while StatPoints > 0 and StatBridge do
            StatBridge:Fire({ { StatOrder[StatIdx], 1 } })
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
        if not CurrentQuest or not UseSkillBridge then continue end
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

        if not CurrentQuest then
            AcceptQuest()
            task.wait(1.5)
            continue
        end

        if QuestDone then
            task.wait(1)
            QuestDone = false
            continue
        end

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
