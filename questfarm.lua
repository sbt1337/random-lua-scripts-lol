-- Kanom Tokyo | Quest Autofarm (Ghoul - Nishiki)
-- Fixed networking: all remotes are BridgeNet2 bridges accessed AFTER identifierStorage loads
-- identifierStorage lives at game.ReplicatedStorage.BridgeNet2.identifierStorage (wallyInstanceManager)

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer       = Players.LocalPlayer

-- BridgeNet2 module — safe to require immediately
local BridgeNet2  = require(ReplicatedStorage.Modules.Library.BridgeNet2)
local ReplicaCtrl = require(ReplicatedStorage.ReplicaController)

-- !! All ClientBridge / ReferenceBridge calls happen INSIDE init, after identifierStorage
-- is confirmed loaded. Calling them before causes the 3-second "bridge not found" timeout.
local QuestBridge    = nil   -- ClientBridge("Quest")
local UseSkillBridge = nil   -- ReferenceBridge("UseSkill")
local StatBridge     = nil   -- ClientBridge("StatUpgrade")
local Initialized    = false

-- Config
local DEFAULT_SKILL_CD = 8    -- seconds per skill, server overrides via cooldown listener
local UNDER_DEPTH      = 5    -- studs below enemy HRP
local ATTACK_DIST      = 10   -- TP threshold
local StatOrder        = { "Damage", "Durability" }   -- balanced alternation

-- Level → quest giver NPC name (maps to TalkNpc.Quests[name].Quest module)
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
local CurrentQuest   = nil   -- table from QuestReceived: {QuestInfo, Goal, Target, Type}
local QuestDone      = false
local PlayerLevel    = 1
local StatPoints     = 0
local StatIdx        = 1
local SkillCooldowns = {}    -- [skillName] = endTick
local Collectibles   = {}    -- pending ProximityPrompts to trigger

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
    -- 5 studs below, pitched upward at enemy so forward hitbox offset hits them
    r.CFrame = CFrame.new(hrp.Position - Vector3.new(0, UNDER_DEPTH, 0), hrp.Position)
end

-- Rate-limited toggle: ToggleWeapon is a flip-flop. Calling it twice in rapid
-- succession (before isUsingWeapon replicates back) equips then immediately unequips.
-- The 4s gate ensures we never double-fire it.
local LastEquipAt = 0
local function EquipKagune()
    if LocalPlayer:GetAttribute("isUsingWeapon") then return end
    if not _G.ToggleWeapon then return end
    if tick() - LastEquipAt < 4 then return end
    LastEquipAt = tick()
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

-- Returns the Quest child ModuleScript for the best level-appropriate NPC tier
local function GetQuestModule()
    local questsFolder = ReplicatedStorage.Modules.Client.TalkNpc.Quests
    for i = #QuestTiers, 1, -1 do
        local tier = QuestTiers[i]
        if PlayerLevel >= tier.min then
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
    if not QuestBridge then return end
    local questMod, npcName = GetQuestModule()
    if not questMod then
        print("[QF] No quest module for level", PlayerLevel)
        return
    end
    print("[QF] Accepting:", npcName)
    TPNearNPC(npcName)
    task.wait(0.5)
    -- BridgeNet2 Fire mirrors what TalkNpc does: FireServer("RequestQuest", script.Quest)
    QuestBridge:Fire({ "RequestQuest", questMod })
end

-- Collectible system -----------------------------------------------------------
-- Watch workspace for ProximityPrompts outside AI/TalkNpc folders.
-- These are map collectibles (resource nodes, flowers, crystals, etc.)
local IgnoredFolders = { ["AI"] = true, ["TalkNpc"] = true, ["IncludeToGame"] = true }

local function IsCollectible(prompt)
    -- Only care about prompts NOT parented inside ignored folders
    local anc = prompt:FindFirstAncestorWhichIsA("Folder") or prompt:FindFirstAncestorWhichIsA("Model")
    if anc and IgnoredFolders[anc.Name] then return false end
    -- Workspace-level models or Map children with prompts = collectible
    return true
end

local function RegisterCollectible(prompt)
    if not prompt:IsA("ProximityPrompt") then return end
    if not IsCollectible(prompt) then return end
    table.insert(Collectibles, prompt)
end

-- Scan existing workspace children for prompts on startup
for _, desc in workspace:GetDescendants() do
    pcall(RegisterCollectible, desc)
end

workspace.DescendantAdded:Connect(function(desc)
    task.wait(0.1)  -- let it fully parent before checking
    pcall(RegisterCollectible, desc)
end)

workspace.DescendantRemoving:Connect(function(desc)
    if desc:IsA("ProximityPrompt") then
        local idx = table.find(Collectibles, desc)
        if idx then table.remove(Collectibles, idx) end
    end
end)

-- Collectible pickup loop — runs in background when no quest target is nearby
local function TryCollectNearby()
    local r = Root()
    if not r then return end
    for i = #Collectibles, 1, -1 do
        local prompt = Collectibles[i]
        if not prompt or not prompt.Parent then
            table.remove(Collectibles, i)
            continue
        end
        local part = prompt.Parent
        if not part or not part:IsA("BasePart") then continue end
        local dist = (r.Position - part.Position).Magnitude
        if dist > 60 then continue end

        -- TP close
        if dist > 4 then
            r.CFrame = CFrame.new(part.Position + Vector3.new(2, 0, 2))
            task.wait(0.2)
        end

        -- Trigger via executor fireproximityprompt if available, else touch approach
        local ok = pcall(function()
            if fireproximityprompt then
                fireproximityprompt(prompt)
            end
        end)
        if not ok then
            -- Fallback: overlap touch by positioning on part
            if r then r.CFrame = CFrame.new(part.Position) end
        end
        task.wait(0.3)
        return  -- one at a time
    end
end

-- Replica: level + stat points -------------------------------------------------
-- Wrapped in pcall: some executor environments sandbox ReplicaController so
-- the module loads but returns nil, which would error on the :ReplicaOfClassCreated call.
pcall(function()
    ReplicaCtrl.ReplicaOfClassCreated("DataToken_" .. LocalPlayer.UserId, function(replica)
        local team = LocalPlayer:GetAttribute("Team") or "GHOUL"
        local data = replica.Data[team]
        if not data then
            warn("[QF] DataToken: no data for team", team)
            return
        end
        PlayerLevel = data.Level or 1
        StatPoints  = data.StatPoint or 0
        print("[QF] DataToken loaded — Level:", PlayerLevel, "StatPoints:", StatPoints)
        replica:ListenToChange({ "Level" }, function(v)
            PlayerLevel = v
            print("[QF] Level up →", v)
        end)
        replica:ListenToChange({ "StatPoint" }, function(v) StatPoints = v end)
    end)
end)

-- Re-equip on respawn ----------------------------------------------------------
-- Weapon.lua sets internal u19=true (3s toggle cooldown) on CharacterAdded.
-- Wait 4s to outlast it, then reset our rate-limiter and equip.
LocalPlayer.CharacterAdded:Connect(function()
    task.wait(4)
    repeat task.wait(0.2) until LocalPlayer:GetAttribute("Loaded")
    LastEquipAt = 0
    EquipKagune()
    print("[QF] Respawned — kagune equipped")
end)

-- Init: wait for identifierStorage, then create bridges ------------------------
-- The wallyInstanceManager puts identifierStorage at:
--   game.ReplicatedStorage.BridgeNet2.identifierStorage
-- (a folder named "BridgeNet2" created directly in RS root, NOT in Modules.Library.BridgeNet2)
task.spawn(function()
    print("[QF] Init spawn alive — waiting for character...")

    -- Wait for a playable character (HRP = character is actually loaded in world)
    if not LocalPlayer.Character then LocalPlayer.CharacterAdded:Wait() end
    local char = LocalPlayer.Character
    while not char:FindFirstChild("HumanoidRootPart") do task.wait(0.2) end

    -- Team attribute: set server-side before DataToken replica.
    -- Give it up to 15s, then default to GHOUL so we never stall.
    local teamWait = 0
    while not LocalPlayer:GetAttribute("Team") and teamWait < 15 do
        task.wait(0.5)
        teamWait += 0.5
    end
    local team = LocalPlayer:GetAttribute("Team") or "GHOUL"
    print("[QF] Team:", team, "| Attrs — Loaded:", LocalPlayer:GetAttribute("Loaded"), "Team:", team)

    print("[QF] Waiting for BridgeNet2 identifierStorage...")
    local bn2Folder = ReplicatedStorage:WaitForChild("BridgeNet2", 120)
    if not bn2Folder then
        warn("[QF] BridgeNet2 folder never appeared — aborting")
        return
    end
    local idStore = bn2Folder:WaitForChild("identifierStorage", 60)
    if not idStore then
        warn("[QF] identifierStorage never appeared — aborting")
        return
    end

    -- All bridges are now registered. Print them for debugging.
    local names = {}
    for name, _ in idStore:GetAttributes() do table.insert(names, name) end
    table.sort(names)
    print("[QF] Registered bridges:", table.concat(names, ", "))

    -- Now it's safe to create bridges — no more 3s timeout errors
    QuestBridge    = BridgeNet2.ClientBridge("Quest")
    UseSkillBridge = BridgeNet2.ReferenceBridge("UseSkill")
    StatBridge     = BridgeNet2.ClientBridge("StatUpgrade")

    -- Quest event listener
    -- Server fires: {"QuestReceived", questData}, {"QuestCompleted"}, {"QuestProgress", cur, goal}, etc.
    QuestBridge:Connect(function(data)
        local ev = data[1]
        if ev == "QuestReceived" then
            CurrentQuest = data[2]
            QuestDone    = false
            if CurrentQuest then
                print("[QF] Quest:", CurrentQuest.QuestInfo, "| Goal:", CurrentQuest.Goal)
            end
        elseif ev == "QuestCompleted" then
            print("[QF] Complete! Accepting next...")
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
            task.wait(0.35)
        end
    end
end)

-- Skill loop -------------------------------------------------------------------
task.spawn(function()
    repeat task.wait(0.5) until Initialized
    while Running do
        task.wait(0.25)
        if not CurrentQuest then continue end
        if not LocalPlayer:GetAttribute("isUsingWeapon") then continue end
        local char = Char()
        if not char or char:GetAttribute("SkillDisabled") then continue end
        if not FindEnemy(CurrentQuest.Target) then continue end

        local now    = tick()
        local skills = GetLoadedSkillNames()
        for _, name in skills do
            if (SkillCooldowns[name] or 0) > now then continue end
            local ok, result = pcall(function()
                return UseSkillBridge:InvokeServerAsync(name)
            end)
            if ok and result then
                SkillCooldowns[name] = now + DEFAULT_SKILL_CD
                print("[QF] Skill:", name)
            elseif not ok then
                SkillCooldowns[name] = now + 3
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

        -- Attempt to pick up any map collectibles opportunistically
        TryCollectNearby()

        -- No quest: accept one
        if not CurrentQuest and not QuestDone then
            AcceptQuest()
            task.wait(1.5)
            continue
        end

        -- Just finished: brief pause then re-accept same tier (or higher if leveled)
        if QuestDone then
            task.wait(1)
            QuestDone = false
            continue
        end

        -- Hunt enemies
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
                -- No target alive yet — pick up collectibles while waiting
                TryCollectNearby()
                task.wait(0.4)
            end
        else
            task.wait(0.5)
        end
    end
end)

print("[QF] Script executing...")
