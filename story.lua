if game.PlaceId == 140409475718339 then return end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local Humanoid = Character:WaitForChild("Humanoid")
local HRP = Character:WaitForChild("HumanoidRootPart")

local Running = true
local LowHP = false
local Attacking = false
local AttackStartTime = 0
local LastAttackPos = nil
local StuckTimer = 0

-- Stats for periodic webhook updates
local Stats = {
    AttacksAttempted = 0,
    AttacksAborted = 0,
    MatchesCompleted = 0,
    Rebirths = 0,
    StartTime = tick(),
}

local WEBHOOK = "https://discord.com/api/webhooks/1503857688118034662/H3y9e9EUyyZyRnKCQ-X_eIdRpejU8OwStg22dzEoycfGt__iAhRTYmnumIenbFWEckS7"
local LOW_HP_THRESHOLD = 0.35
local UNDERGROUND_Y = 10
local ATTACK_OFFSET = 8
local MAX_ZOMBIE_RANGE = 400 -- skip glitched/out-of-bounds zombies
local ATTACK_COOLDOWN_PER_ZOMBIE = 1.0 -- avoid re-targeting same zombie for 1s
local ATTACK_TIMEOUT = 5 -- if attack runs longer than this, force unstick
local STATS_INTERVAL = 1800 -- send stats every 30 mins

-- Recently attacked zombies cooldown
local RecentlyAttacked = {}

local REBIRTH_STEPS = {
    { RequiredLevel = 50, CoinsRequired = 2500000 },
    { RequiredLevel = 50, CoinsRequired = 5000000 },
    { RequiredLevel = 50, CoinsRequired = 7500000 },
    { RequiredLevel = 50, CoinsRequired = 10000000 },
    { RequiredLevel = 50, CoinsRequired = 12500000 },
}

print("[StoryFarm] Loaded")

-- Webhook
local function SendWebhook(Title, Fields, Color)
    local ok, _ = pcall(function()
        local Body = HttpService:JSONEncode({
            username = "StoryFarm",
            embeds = {{
                title = Title,
                color = Color or 3066993,
                fields = Fields
            }}
        })
        local RequestFunc = (syn and syn.request) or request or http_request
        RequestFunc({
            Url = WEBHOOK,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = Body
        })
    end)
    if not ok then print("[StoryFarm] Webhook failed") end
end

local function SendError(Label, Err)
    print("[StoryFarm] ERROR in " .. Label .. ": " .. tostring(Err))
    SendWebhook("Error: " .. Label, {{ name = "Details", value = "```" .. tostring(Err) .. "```" }}, 15158332)
end

local function Safe(Label, Fn)
    local ok, err = pcall(Fn)
    if not ok then SendError(Label, err) end
end

-- PgDn toggle
UserInputService.InputBegan:Connect(function(Input, GameProcessed)
    if GameProcessed then return end
    if Input.KeyCode == Enum.KeyCode.PageDown then
        Running = not Running
        print("[StoryFarm] " .. (Running and "Enabled" or "Disabled"))
    end
end)

-- Character validity check
local function IsCharValid()
    return Character and Character.Parent
        and Humanoid and Humanoid.Parent and Humanoid.Health > 0
        and HRP and HRP.Parent
end

-- Player data
local function GetData()
    local Data = LocalPlayer:FindFirstChild("Data")
    if not Data then return nil end
    local Level = Data:FindFirstChild("BattlepassLevel")
    local Rebirths = Data:FindFirstChild("Rebirths")
    local Coins = Data:FindFirstChild("Coins")
    if not Level or not Rebirths or not Coins then return nil end
    return { Level = Level.Value, Rebirths = Rebirths.Value, Coins = Coins.Value }
end

local function CanRebirth()
    local Data = GetData()
    if not Data then return false end
    if Data.Rebirths >= 5 then return false end
    local Step = REBIRTH_STEPS[Data.Rebirths + 1]
    if not Step then return false end
    return Data.Level >= Step.RequiredLevel and Data.Coins >= Step.CoinsRequired
end

local function GetInteract()
    local Assets = ReplicatedStorage:FindFirstChild("Assets")
    if not Assets then return nil end
    local Remotes = Assets:FindFirstChild("Remotes")
    if not Remotes then return nil end
    return Remotes:FindFirstChild("Interact")
end

local function GetAbilityInfo()
    local Data = LocalPlayer:FindFirstChild("Data")
    if not Data then return nil, nil end
    local AbilitySlots = Data:FindFirstChild("AbilitySlots")
    if not AbilitySlots then return nil, nil end
    local ok, Decoded = pcall(HttpService.JSONDecode, HttpService, AbilitySlots.Value)
    if not ok or not Decoded then return nil, nil end
    for SlotName, SlotData in pairs(Decoded) do
        if SlotData and SlotData.Showcasing then
            return SlotName, SlotData.Name
        end
    end
    return nil, nil
end

-- Canonical zombie validity (mirrors game's Utils.IsValidChar)
local function IsZombieValid(Model)
    if not Model or not Model.Parent then return false end
    if not Model:IsA("Model") then return false end

    local ZombieFolder = workspace:FindFirstChild("Zombies")
    if not ZombieFolder or not Model:IsDescendantOf(ZombieFolder) then return false end

    -- "Died" attribute - game sets this on dead chars
    if Model:GetAttribute("Died") then return false end

    -- HRP is removed when zombie dies
    local Root = Model:FindFirstChild("HumanoidRootPart")
    if not Root or not Root.Parent then return false end

    -- Humanoid health
    local Hum = Model:FindFirstChildWhichIsA("Humanoid")
    if Hum and Hum.Health <= 0 then return false end

    -- Server-side Config.Health
    local Config = Model:FindFirstChild("Config")
    if Config then
        local Health = Config:FindFirstChild("Health")
        if Health and Health.Value <= 0 then return false end
    end

    return true
end

-- Find nearest valid zombie, respecting cooldown and max range
local function GetNearestZombie()
    if not IsCharValid() then return nil end

    local ZombieFolder = workspace:FindFirstChild("Zombies")
    if not ZombieFolder then return nil end

    local Nearest, NearestDist = nil, math.huge
    local Now = tick()

    for _, Model in ipairs(ZombieFolder:GetChildren()) do
        if not IsZombieValid(Model) then continue end
        if RecentlyAttacked[Model] and RecentlyAttacked[Model] > Now then continue end

        local Root = Model:FindFirstChild("HumanoidRootPart")
        if not Root then continue end

        local Dx = Root.Position.X - HRP.Position.X
        local Dz = Root.Position.Z - HRP.Position.Z
        local Dist = math.sqrt(Dx * Dx + Dz * Dz)

        if Dist > MAX_ZOMBIE_RANGE then continue end

        if Dist < NearestDist then
            Nearest = Model
            NearestDist = Dist
        end
    end

    return Nearest
end

-- Movement primitives
local function GoUnderground()
    if not IsCharValid() then return end
    HRP.CFrame = CFrame.new(HRP.Position.X, HRP.Position.Y - UNDERGROUND_Y, HRP.Position.Z)
end

local function GoToZombie(ZombieRoot)
    if not IsCharValid() then return end
    if not ZombieRoot or not ZombieRoot.Parent then return end
    local ZPos = ZombieRoot.Position
    local Dir = HRP.Position - ZPos
    if Dir.Magnitude < 0.1 then
        Dir = Vector3.new(1, 0, 0)
    end
    local Offset = Vector3.new(Dir.X, 0, Dir.Z).Unit * ATTACK_OFFSET
    HRP.CFrame = CFrame.new(ZPos + Offset + Vector3.new(0, 2, 0))
end

-- HP tracker
RunService.Heartbeat:Connect(function()
    if not Humanoid or not Humanoid.Parent then return end
    LowHP = (Humanoid.Health / math.max(Humanoid.MaxHealth, 1)) < LOW_HP_THRESHOLD
end)

-- Noclip
RunService.Stepped:Connect(function()
    if not Running then return end
    if not Character or not Character.Parent then return end
    Safe("Noclip", function()
        for _, Part in ipairs(Character:GetDescendants()) do
            if Part:IsA("BasePart") then
                Part.CanCollide = false
            end
        end
    end)
end)

-- Cleanup RecentlyAttacked + watchdog for stuck Attacking flag
task.spawn(function()
    while true do
        task.wait(1)

        local Now = tick()

        -- Clean expired entries and garbage-collected models
        for Model, Expiry in pairs(RecentlyAttacked) do
            if not Model.Parent or Expiry < Now then
                RecentlyAttacked[Model] = nil
            end
        end

        -- Force unstick if attacking too long
        if Attacking and (Now - AttackStartTime) > ATTACK_TIMEOUT then
            print("[StoryFarm] Attack stuck for " .. math.floor(Now - AttackStartTime) .. "s, force releasing")
            Attacking = false
            Safe("ForceUnstuck", GoUnderground)
        end
    end
end)

-- Main attack loop
task.spawn(function()
    while true do
        task.wait(0.1)
        if not Running then continue end
        if Attacking then continue end
        if not IsCharValid() then task.wait(1) continue end

        Safe("AttackLoop", function()
            local Interact = GetInteract()
            if not Interact then return end

            local SlotName, AbilityName = GetAbilityInfo()
            if not SlotName or not AbilityName then task.wait(1) return end

            -- Low HP retreat
            if LowHP then
                GoUnderground()
                task.wait(2.5)
                return
            end

            local ZombieModel = GetNearestZombie()
            if not ZombieModel then
                task.wait(1)
                return
            end

            -- Mark as attacking BEFORE TP so watchdog can unstick if needed
            Attacking = true
            AttackStartTime = tick()
            Stats.AttacksAttempted = Stats.AttacksAttempted + 1

            -- Pre-TP final validation
            if not IsZombieValid(ZombieModel) then
                Stats.AttacksAborted = Stats.AttacksAborted + 1
                Attacking = false
                return
            end

            local ZombieRoot = ZombieModel:FindFirstChild("HumanoidRootPart")
            if not ZombieRoot or not ZombieRoot.Parent then
                Stats.AttacksAborted = Stats.AttacksAborted + 1
                Attacking = false
                return
            end

            -- Cooldown this zombie immediately so we don't loop on it
            RecentlyAttacked[ZombieModel] = tick() + ATTACK_COOLDOWN_PER_ZOMBIE

            -- TP up to attack position
            GoToZombie(ZombieRoot)
            task.wait(0.03)

            -- One last validation before firing (zombie could have died in those 30ms)
            if not IsZombieValid(ZombieModel) then
                Stats.AttacksAborted = Stats.AttacksAborted + 1
                GoUnderground()
                Attacking = false
                return
            end

            -- Fire all 4 abilities fast
            for i = 1, 4 do
                if not IsCharValid() then break end
                Interact:FireServer("Ability", i, SlotName, AbilityName, "Began")
                task.wait(0.03)
                Interact:FireServer("Ability", i, SlotName, AbilityName, "Released")
                task.wait(0.03)
            end

            -- Retreat immediately
            GoUnderground()
            task.wait(0.25)

            Attacking = false
        end)
    end
end)

-- Auto rebirth check
task.spawn(function()
    while true do
        task.wait(10)
        if not Running then continue end

        Safe("AutoRebirth", function()
            if not CanRebirth() then return end
            local Data = GetData()
            if not Data then return end
            local Interact = GetInteract()
            if not Interact then return end

            print("[StoryFarm] Rebirthing! Rebirths: " .. Data.Rebirths .. " Level: " .. Data.Level)
            Interact:FireServer("Rebirth")
            Stats.Rebirths = Stats.Rebirths + 1

            SendWebhook("Rebirth Performed!", {
                { name = "Rebirths", value = tostring(Data.Rebirths + 1), inline = true },
                { name = "Level",    value = tostring(Data.Level),        inline = true },
                { name = "Coins",    value = tostring(Data.Coins),        inline = true },
            }, 15844367)
        end)
    end
end)

-- End screen handler
task.spawn(function()
    Safe("EndScreenWatcher", function()
        local HUD = LocalPlayer.PlayerGui:WaitForChild("HUD")
        local RetryButton = HUD:WaitForChild("EndScreen"):WaitForChild("Main"):WaitForChild("Retry")

        RetryButton:GetPropertyChangedSignal("Visible"):Connect(function()
            if not RetryButton.Visible then return end

            Safe("EndScreenFired", function()
                local Data = GetData()
                Stats.MatchesCompleted = Stats.MatchesCompleted + 1

                SendWebhook("Match Over", {
                    { name = "Coins",    value = Data and tostring(Data.Coins)    or "?", inline = true },
                    { name = "Level",    value = Data and tostring(Data.Level)    or "?", inline = true },
                    { name = "Rebirths", value = Data and tostring(Data.Rebirths) or "?", inline = true },
                }, 3066993)

                if Running then
                    task.wait(0.5)
                    local Interact = GetInteract()
                    if Interact then Interact:FireServer("PlayAgain") end
                end
            end)
        end)

        print("[StoryFarm] Watching for EndScreen...")
    end)
end)

-- Auto start raid
task.spawn(function()
    Safe("StartWatcher", function()
        local function FireStart()
            if not Running then return end
            if not workspace:GetAttribute("RaidStarting") then return end
            Safe("FireVoteSkipRaid", function()
                local Interact = GetInteract()
                if not Interact then return end
                task.wait(0.5)
                Interact:FireServer("VoteSkipRaid")
            end)
        end

        workspace:GetAttributeChangedSignal("RaidStarting"):Connect(FireStart)
        task.wait(0.5)
        FireStart()
        print("[StoryFarm] Watching for RaidStarting...")
    end)
end)

-- Periodic stats webhook (so user knows it's still running overnight)
task.spawn(function()
    while true do
        task.wait(STATS_INTERVAL)
        if not Running then continue end

        Safe("StatsReport", function()
            local Data = GetData()
            local Runtime = math.floor((tick() - Stats.StartTime) / 60)

            SendWebhook("Status Report", {
                { name = "Runtime",         value = Runtime .. " min",                       inline = true },
                { name = "Matches",         value = tostring(Stats.MatchesCompleted),        inline = true },
                { name = "Rebirths",        value = tostring(Stats.Rebirths),                inline = true },
                { name = "Attacks",         value = tostring(Stats.AttacksAttempted),        inline = true },
                { name = "Aborted",         value = tostring(Stats.AttacksAborted),          inline = true },
                { name = "Coins",           value = Data and tostring(Data.Coins)    or "?", inline = true },
                { name = "Level",           value = Data and tostring(Data.Level)    or "?", inline = true },
                { name = "Current Rebirth", value = Data and tostring(Data.Rebirths) or "?", inline = true },
            }, 7506394)
        end)
    end
end)

-- CharacterAdded - re-grab refs and reset state on respawn
LocalPlayer.CharacterAdded:Connect(function(NewCharacter)
    Safe("CharacterAdded", function()
        print("[StoryFarm] Character respawned")
        Character = NewCharacter
        Humanoid = NewCharacter:WaitForChild("Humanoid")
        HRP = NewCharacter:WaitForChild("HumanoidRootPart")
        LowHP = false
        Attacking = false

        task.wait(1)

        local ForceConn
        local Start = tick()
        ForceConn = RunService.Stepped:Connect(function()
            Safe("ForcefieldNudge", function()
                if tick() - Start >= 2 then
                    ForceConn:Disconnect()
                    return
                end
                if HRP and HRP.Parent then
                    HRP.Velocity = Vector3.new(0, 0, -10)
                end
            end)
        end)

        task.wait(2.5)
        Safe("InitialUnderground", GoUnderground)
        print("[StoryFarm] Underground, attack loop active")
    end)
end)
