-- Kanom Tokyo | Quest Autofarm (Ghoul - Nishiki)
-- * Auto-accepts best level-appropriate quest from the board
-- * Attacks from 5 studs underground, facing up at enemy (hitbox offset hits through floor)
-- * Auto-discovers and fires all Nishiki skills as they get unlocked (no hardcoding needed)
-- * Alternates Damage / Durability stat allocation when points are available
-- * Re-equips kagune on respawn and whenever it drops mid-fight

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer       = Players.LocalPlayer
local QuestNet          = ReplicatedStorage.Network.Quest
local UseSkillRemote    = ReplicatedStorage.Network.UseSkill
local QuestBoardDB      = ReplicatedStorage.Modules.DataBase.QuestBoard
local BridgeNet2        = require(ReplicatedStorage.Modules.Library.BridgeNet2)
local ReplicaCtrl       = require(ReplicatedStorage.ReplicaController)

-- Config
local DEFAULT_SKILL_CD = 8   -- fallback cooldown estimate (seconds) per skill
local BOARD_POS        = Vector3.new(-240, 34, 208)
local UNDER_DEPTH      = 5   -- studs below enemy HRP
local ATTACK_DIST      = 10  -- re-TP threshold

-- Stat alternation: Damage first, then Durability, repeat
local StatOrder = { "Damage", "Durability" }
local StatIdx   = 1

-- Runtime state
local Running           = true
local AvailableQuests   = {}
local CompletedUIDs     = {}
local CurrentQuest      = nil   -- set by QuestReceived event: {QuestInfo, Goal, Target, ...}
local QuestDone         = false
local ShouldRepick      = false
local PlayerLevel       = 1
local StatPoints        = 0
-- Per-skill cooldown end times, keyed by skill name
local SkillCooldowns = {}

local StatBridge = BridgeNet2.ClientBridge("StatUpgrade")

-- Replica: level + stat point tracking ----------------------------------------
ReplicaCtrl.ReplicaOfClassCreated("DataToken_" .. LocalPlayer.UserId, function(replica)
    local team = LocalPlayer:GetAttribute("Team") or "GHOUL"
    local data  = replica.Data[team]
    if not data then return end

    PlayerLevel = data.Level    or 1
    StatPoints  = data.StatPoint or 0

    replica:ListenToChange({ "Level" }, function(v)
        if v > PlayerLevel then
            ShouldRepick = true   -- level up: try for a higher quest next chance
        end
        PlayerLevel = v
    end)

    replica:ListenToChange({ "StatPoint" }, function(v)
        StatPoints = v
    end)
end)

-- Quest board data (server fires on join + hourly reset) -----------------------
BridgeNet2.ClientBridge("QuestData"):Connect(function(payload)
    AvailableQuests = payload[1] or {}
    CompletedUIDs   = {}
    for _, q in AvailableQuests do
        if q.isCompleted then
            CompletedUIDs[q.UID] = true
        end
    end
    ShouldRepick = true
end)

-- Quest event listener ---------------------------------------------------------
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

-- Helpers ----------------------------------------------------------------------
local function Char() return LocalPlayer.Character end
local function Root()
    local c = Char()
    return c and c:FindFirstChild("HumanoidRootPart")
end

-- Pick the highest LevelRequired non-player-kill quest we qualify for
local function BestQuest()
    if #AvailableQuests == 0 then return nil end
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
            best   = { q = q, mod = mod, info = data.QuestInfo }
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
        print("[QF] No suitable quest found (board may need to refresh)")
    end
end

-- Find nearest alive enemy matching quest targets inside workspace["AI/Player"]
local function FindEnemy(targets)
    local r = Root()
    if not r then return nil end
    local aiFolder = workspace["AI/Player"]
    local best, bestDist = nil, math.huge
    for _, m in aiFolder:GetChildren() do
        if not m:IsA("Model") or not table.find(targets, m.Name) then continue end
        local hrp = m:FindFirstChild("HumanoidRootPart")
        local hum = m:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum or hum.Health <= 0 then continue end
        local d = (r.Position - hrp.Position).Magnitude
        if d < bestDist then
            bestDist = d
            best     = m
        end
    end
    return best
end

-- TP 5 studs below enemy, look up at them so the Nishiki hitbox (forward offset)
-- extends upward into the enemy's collision box
local function TPUnderEnemy(hrp)
    local r = Root()
    if not r then return end
    local underPos = hrp.Position - Vector3.new(0, UNDER_DEPTH, 0)
    -- CFrame.new(pos, lookAt) pitches us upward toward the enemy
    r.CFrame = CFrame.new(underPos, hrp.Position)
end

-- Equip kagune if it's currently sheathed
local function EquipKagune()
    if not LocalPlayer:GetAttribute("isUsingWeapon") then
        if _G.ToggleWeapon then
            _G.ToggleWeapon()
            task.wait(0.5)
        end
    end
end

-- Auto-reequip on respawn
LocalPlayer.CharacterAdded:Connect(function()
    task.wait(3)
    repeat task.wait(0.2) until LocalPlayer:GetAttribute("Loaded")
    EquipKagune()
    print("[QF] Respawned — kagune re-equipped")
end)

-- Stat allocation thread -------------------------------------------------------
task.spawn(function()
    repeat task.wait(0.5) until LocalPlayer:GetAttribute("Loaded")
    while Running do
        task.wait(0.8)
        while StatPoints > 0 do
            local stat = StatOrder[StatIdx]
            StatBridge:Fire({ { stat, 1 } })
            StatIdx    = (StatIdx % #StatOrder) + 1
            StatPoints -= 1   -- optimistic; replica confirms actual value
            task.wait(0.3)
        end
    end
end)

-- Auto-discover skills from ReplicatedStorage.Inputs.Skills.
-- SkillClientHandler registers each skill's InputAction there when the weapon is
-- loaded, so this naturally includes only the ones currently in the weapon module.
-- New skills appear here as soon as they unlock — no script changes needed.
local function GetLoadedSkillNames()
    local names   = {}
    local folder  = ReplicatedStorage:FindFirstChild("Inputs")
    folder        = folder and folder:FindFirstChild("Skills")
    if not folder then return names end
    for _, action in folder:GetChildren() do
        -- InputAction instances are the registered skills
        if action.ClassName == "InputAction" or action:IsA("Instance") then
            table.insert(names, action.Name)
        end
    end
    return names
end

-- Skill thread: cycles through all currently-loaded skills, fires any off cooldown
task.spawn(function()
    repeat task.wait(0.5) until LocalPlayer:GetAttribute("Loaded")
    while Running do
        task.wait(0.2)

        if not CurrentQuest then continue end
        if not LocalPlayer:GetAttribute("isUsingWeapon") then continue end

        local char = Char()
        if not char or char:GetAttribute("SkillDisabled") then continue end

        local enemy = FindEnemy(CurrentQuest.Target)
        if not enemy then continue end

        local now    = tick()
        local skills = GetLoadedSkillNames()

        for _, name in skills do
            if (SkillCooldowns[name] or 0) > now then continue end

            local ok, result = pcall(function()
                return UseSkillRemote:InvokeServer(name)
            end)
            if ok and result then
                SkillCooldowns[name] = now + DEFAULT_SKILL_CD
                print("[QF] Skill fired:", name)
            elseif not ok then
                SkillCooldowns[name] = now + 2   -- brief backoff on pcall error
            end
            -- small gap between firing multiple skills back-to-back
            task.wait(0.1)
        end
    end
end)

-- Main farm loop ---------------------------------------------------------------
task.spawn(function()
    repeat task.wait(0.5) until LocalPlayer:GetAttribute("Loaded") and LocalPlayer:GetAttribute("Team")

    EquipKagune()

    -- Fallback: if no quest data arrives in 3s, walk to the board so server re-sends
    task.delay(3, function()
        if #AvailableQuests == 0 then
            local r = Root()
            if r then r.CFrame = CFrame.new(BOARD_POS) end
            print("[QF] No quest data yet — teleported to board to trigger refresh")
        end
    end)

    while Running do
        local char = Char()
        if not char or not Root() then task.wait(1) continue end

        -- No quest: accept best available
        if not CurrentQuest and not QuestDone then
            if #AvailableQuests > 0 then
                AcceptBestQuest()
                task.wait(1.5)
            else
                task.wait(2)
            end
            continue
        end

        -- Just completed: short pause then repick (level up might open a better tier)
        if QuestDone then
            task.wait(2)
            QuestDone    = false
            ShouldRepick = true
            continue
        end

        -- Level-up flagged and quest just finished: try higher tier
        if ShouldRepick and not CurrentQuest then
            ShouldRepick = false
            AcceptBestQuest()
            task.wait(1.5)
            continue
        end

        -- Active quest: find, sink below, swing
        if CurrentQuest and CurrentQuest.Target then
            EquipKagune()

            local enemy = FindEnemy(CurrentQuest.Target)
            if enemy then
                local hrp = enemy:FindFirstChild("HumanoidRootPart")
                if hrp then
                    -- Re-TP only when we've drifted out of ATTACK_DIST
                    local r = Root()
                    if r and (r.Position - hrp.Position).Magnitude > ATTACK_DIST then
                        TPUnderEnemy(hrp)
                    end

                    if _G.Attack then
                        _G.Attack()   -- yields until animation marker fires
                    else
                        task.wait(0.1)
                    end
                end
            else
                task.wait(0.4)
            end
        else
            task.wait(0.5)
        end
    end
end)

print("[QF] Quest autofarm started | Level:", PlayerLevel, "| Team:", LocalPlayer:GetAttribute("Team") or "?")
