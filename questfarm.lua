-- Kanom Tokyo | Quest Autofarm (Ghoul)
-- Picks best level-appropriate quest from the board, kills targets, repeats.

local Players         = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer     = Players.LocalPlayer
local Network         = ReplicatedStorage.Network
local QuestNet        = Network.Quest
local UseSkillRemote  = Network.UseSkill
local QuestBoardDB    = ReplicatedStorage.Modules.DataBase.QuestBoard
local BridgeNet2      = require(ReplicatedStorage.Modules.Library.BridgeNet2)
local ReplicaCtrl     = require(ReplicatedStorage.ReplicaController)

-- Variables

local Running         = true
local AvailableQuests = {}
local CompletedUIDs   = {}
local CurrentQuest    = nil   -- data from QuestReceived: {QuestInfo, Goal, Target, Type}
local QuestDone       = false
local PlayerLevel     = 1
local WeaponToggled   = false -- did we fire ToggleWeapon at least once this equip cycle

-- Quest board NPC is physically around here; TP nearby to trigger server re-send if needed
local BOARD_POS = Vector3.new(-240, 34, 208)

-- Priority: skip player-kill quests (arena), skip already-completed UIDs
-- Among the rest, pick highest LevelRequired (= most EXP)

-- Level tracking via Replica ----------------------------------------------------
ReplicaCtrl.ReplicaOfClassCreated("DataToken_" .. LocalPlayer.UserId, function(replica)
    local team = LocalPlayer:GetAttribute("Team") or "GHOUL"
    local data  = replica.Data[team]
    if data then
        PlayerLevel = data.Level or 1
        replica:ListenToChange({ "Level" }, function(v) PlayerLevel = v end)
    end
end)

-- Quest board data (server fires this on join and on hourly reset) ----------------
BridgeNet2.ClientBridge("QuestData"):Connect(function(payload)
    AvailableQuests = payload[1] or {}
    CompletedUIDs   = {}
    for _, q in AvailableQuests do
        if q.isCompleted then
            CompletedUIDs[q.UID] = true
        end
    end
end)

-- Quest event listener -----------------------------------------------------------
QuestNet.OnClientEvent:Connect(function(ev, ...)
    local a = { ... }
    if ev == "QuestReceived" then
        CurrentQuest  = a[1]   -- {QuestInfo, Goal, Target, Type, Rewards, ...}
        QuestDone     = false
        print("[QF] Quest:", CurrentQuest.QuestInfo, "| Goal:", CurrentQuest.Goal)
    elseif ev == "QuestProgress" then
        -- a[1]=current, a[2]=goal (already tracked server-side, just log)
    elseif ev == "QuestCompleted" then
        print("[QF] Quest complete!")
        QuestDone    = true
        CurrentQuest = nil
        WeaponToggled = false
    elseif ev == "QuestRemoved" then
        CurrentQuest  = nil
        QuestDone     = false
        WeaponToggled = false
    end
end)

-- Helpers -----------------------------------------------------------------------

local function Character()
    return LocalPlayer.Character
end

local function Root()
    local c = Character()
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function SafeTP(pos)
    local r = Root()
    if r then
        r.CFrame = CFrame.new(pos)
    end
end

-- Accept best quest from the board based on player level -------------------------
local function AcceptBestQuest()
    if #AvailableQuests == 0 then return end

    local best, bestLevel = nil, -1

    for _, q in AvailableQuests do
        if CompletedUIDs[q.UID] then continue end

        local mod = QuestBoardDB:FindFirstChild(q.QuestName, true)
        if not mod then continue end

        local ok, data = pcall(require, mod)
        if not ok then continue end

        local targets      = data.Target or {}
        local isPlayerKill = table.find(targets, "Player")
        local levelReq     = data.LevelRequired or 0

        if not isPlayerKill and levelReq <= PlayerLevel and levelReq > bestLevel then
            bestLevel = levelReq
            best = { q = q, mod = mod, name = data.QuestInfo }
        end
    end

    if best then
        print("[QF] Accepting:", best.name)
        QuestNet:FireServer("RequestQuest", best.mod, best.q.UID)
    else
        print("[QF] No suitable quest available (all done or level too low?)")
    end
end

-- Find nearest alive enemy matching any of the target names ----------------------
local function FindEnemy(targets)
    local r = Root()
    if not r then return nil end

    local aiFolder = workspace["AI/Player"]
    local best, bestDist = nil, math.huge

    for _, m in aiFolder:GetChildren() do
        if not m:IsA("Model") then continue end
        if not table.find(targets, m.Name) then continue end

        local hrp = m:FindFirstChild("HumanoidRootPart")
        local hum = m:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum or hum.Health <= 0 then continue end

        local d = (r.Position - hrp.Position).Magnitude
        if d < bestDist then
            bestDist = d
            best = m
        end
    end

    return best
end

-- Ensure weapon is drawn. ToggleWeapon flips state, so only call it when sheathed.
local function EnsureWeapon()
    if not LocalPlayer:GetAttribute("isUsingWeapon") then
        if not WeaponToggled then
            _G.ToggleWeapon()
            WeaponToggled = true
            task.wait(0.5)
        end
    else
        WeaponToggled = true
    end
end

-- Main loop ----------------------------------------------------------------------
task.spawn(function()
    -- Wait until player data is loaded
    repeat task.wait(0.5) until LocalPlayer:GetAttribute("Loaded") and LocalPlayer:GetAttribute("Team")

    -- If QuestData hasn't arrived in 3s, walk near the board to nudge the server
    task.delay(3, function()
        if #AvailableQuests == 0 then
            SafeTP(BOARD_POS)
            print("[QF] Teleported to quest board to trigger data refresh...")
        end
    end)

    while Running do
        local char = Character()
        if not char or not Root() then task.wait(1) continue end

        -- No quest — try to accept one
        if not CurrentQuest and not QuestDone then
            if #AvailableQuests > 0 then
                AcceptBestQuest()
                task.wait(1.5)
            else
                task.wait(2)
            end
            continue
        end

        -- Quest just completed — brief cooldown then accept next
        if QuestDone then
            task.wait(2)
            QuestDone = false
            continue
        end

        -- Active quest — find enemy and attack
        if CurrentQuest and CurrentQuest.Target then
            local enemy = FindEnemy(CurrentQuest.Target)

            if enemy then
                local hrp = enemy:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local r = Root()
                    if r and (r.Position - hrp.Position).Magnitude > 7 then
                        -- TP directly behind/beside the enemy
                        local offset = hrp.CFrame.LookVector * -4
                        SafeTP(hrp.Position + Vector3.new(offset.X, 0, offset.Z))
                    end

                    EnsureWeapon()

                    -- _G.Attack() yields until animation finishes, naturally pacing attacks
                    if _G.Attack then
                        _G.Attack()
                    else
                        task.wait(0.1)
                    end
                end
            else
                -- No living target found yet — wait for one to spawn
                task.wait(0.4)
            end
        else
            task.wait(0.5)
        end
    end
end)

print("[QF] Quest autofarm loaded. Level:", PlayerLevel, "| Team:", LocalPlayer:GetAttribute("Team") or "?")
