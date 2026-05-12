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

local WEBHOOK = "https://discord.com/api/webhooks/1503794681803440321/qXasXkOVlDvjunThkHMv-2FzXsyBB74yamzlWDgygmxPnHRJ2xWRRBu5FOdXKj99jaQS"
local LOW_HP_THRESHOLD = 0.35
local UNDERGROUND_Y = 10 -- studs below current position
local ATTACK_OFFSET = 8 -- studs away from zombie horizontally

-- Rebirth steps from Rebirth.lua
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

-- Helpers
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

-- Find nearest zombie in workspace.Zombies
local function GetNearestZombie()
    local ZombieFolder = workspace:FindFirstChild("Zombies")
    if not ZombieFolder then return nil end

    local Nearest, NearestDist = nil, math.huge

    for _, Model in ipairs(ZombieFolder:GetChildren()) do
        local Root = Model.PrimaryPart or Model:FindFirstChildWhichIsA("BasePart")
        if not Root then continue end
        local Dist = (Root.Position - Vector3.new(HRP.Position.X, Root.Position.Y, HRP.Position.Z)).Magnitude
        if Dist < NearestDist then
            Nearest = Root
            NearestDist = Dist
        end
    end

    return Nearest
end

-- TP underground (safe zone)
local function GoUnderground()
    if HRP and HRP.Parent then
        HRP.CFrame = CFrame.new(HRP.Position.X, HRP.Position.Y - UNDERGROUND_Y, HRP.Position.Z)
    end
end

-- TP to attack position near zombie (offset so we're not inside it)
local function GoToZombie(ZombieRoot)
    if not HRP or not HRP.Parent then return end
    local ZPos = ZombieRoot.Position
    local Offset = (HRP.Position - ZPos).Unit * ATTACK_OFFSET
    Offset = Vector3.new(Offset.X, 0, Offset.Z)
    HRP.CFrame = CFrame.new(ZPos + Offset + Vector3.new(0, 2, 0))
end

-- HP tracker
RunService.Heartbeat:Connect(function()
    if not Humanoid or not Humanoid.Parent then return end
    LowHP = (Humanoid.Health / math.max(Humanoid.MaxHealth, 1)) < LOW_HP_THRESHOLD
end)

-- Noclip every frame
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

-- Main attack loop - underground hit and run
task.spawn(function()
    while true do
        task.wait(0.1)
        if not Running then continue end
        if Attacking then continue end

        Safe("AttackLoop", function()
            local Interact = GetInteract()
            if not Interact then return end

            local SlotName, AbilityName = GetAbilityInfo()
            if not SlotName or not AbilityName then task.wait(1) return end

            -- If low HP, go underground and wait it out
            if LowHP then
                print("[StoryFarm] Low HP, retreating underground...")
                GoUnderground()
                task.wait(3)
                return
            end

            local ZombieRoot = GetNearestZombie()
            if not ZombieRoot then
                print("[StoryFarm] No zombies found, waiting...")
                task.wait(2)
                return
            end

            Attacking = true

            -- 1. Re-validate zombie is still alive right before TPing
            local ZombiesModel = workspace:FindFirstChild("Zombies")
            if not ZombieRoot.Parent or not ZombieRoot.Parent:IsDescendantOf(ZombiesModel or workspace) then
                print("[StoryFarm] Zombie died before we could attack, skipping...")
                Attacking = false
                return
            end

            GoToZombie(ZombieRoot)
            task.wait(0.1)

            -- 2. Fire all abilities
            for i = 1, 4 do
                Interact:FireServer("Ability", i, SlotName, AbilityName, "Began")
                task.wait(0.05)
                Interact:FireServer("Ability", i, SlotName, AbilityName, "Released")
                task.wait(0.05)
            end

            -- 3. Immediately go back underground
            GoUnderground()

            -- 4. Brief cooldown underground before next attack
            task.wait(0.5)

            Attacking = false
        end)
    end
end)

-- Auto rebirth check every 10s
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

            SendWebhook("Rebirth Performed!", {
                { name = "Rebirths", value = tostring(Data.Rebirths + 1), inline = true },
                { name = "Level",    value = tostring(Data.Level),        inline = true },
                { name = "Coins",    value = tostring(Data.Coins),        inline = true },
            }, 15844367)
        end)
    end
end)

-- End screen - send current coins/level/rebirths, then retry
task.spawn(function()
    Safe("EndScreenWatcher", function()
        local HUD = LocalPlayer.PlayerGui:WaitForChild("HUD")
        local RetryButton = HUD:WaitForChild("EndScreen"):WaitForChild("Main"):WaitForChild("Retry")

        RetryButton:GetPropertyChangedSignal("Visible"):Connect(function()
            if not RetryButton.Visible then return end

            Safe("EndScreenFired", function()
                local Data = GetData()
                print("[StoryFarm] Match ended, sending stats...")

                SendWebhook("Match Over", {
                    { name = "Coins",    value = Data and tostring(Data.Coins)    or "?", inline = true },
                    { name = "Level",    value = Data and tostring(Data.Level)    or "?", inline = true },
                    { name = "Rebirths", value = Data and tostring(Data.Rebirths) or "?", inline = true },
                }, 3066993)

                if Running then
                    task.wait(0.5)
                    local Interact = GetInteract()
                    if Interact then
                        print("[StoryFarm] Firing PlayAgain")
                        Interact:FireServer("PlayAgain")
                    end
                end
            end)
        end)

        print("[StoryFarm] Watching for EndScreen...")
    end)
end)

-- Auto start raid vote
task.spawn(function()
    Safe("StartWatcher", function()
        local function FireStart()
            if not Running then return end
            if not workspace:GetAttribute("RaidStarting") then return end
            Safe("FireVoteSkipRaid", function()
                local Interact = GetInteract()
                if not Interact then return end
                print("[StoryFarm] Voting to start")
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

-- CharacterAdded - re-grab all refs on respawn
LocalPlayer.CharacterAdded:Connect(function(NewCharacter)
    Safe("CharacterAdded", function()
        print("[StoryFarm] Character respawned")
        Character = NewCharacter
        Humanoid = NewCharacter:WaitForChild("Humanoid")
        HRP = NewCharacter:WaitForChild("HumanoidRootPart")
        LowHP = false
        Attacking = false

        task.wait(1)

        -- Break forcefield by nudging forward for 2s
        local ForceConn
        local Start = tick()
        ForceConn = RunService.Stepped:Connect(function()
            Safe("ForcefieldNudge", function()
                if tick() - Start >= 2 then
                    ForceConn:Disconnect()
                    print("[StoryFarm] Forcefield done")
                    return
                end
                if HRP and HRP.Parent then
                    HRP.Velocity = Vector3.new(0, 0, -10)
                end
            end)
        end)

        -- Start underground immediately after forcefield
        task.wait(2.5)
        GoUnderground()
        print("[StoryFarm] Gone underground, starting attack loop")
    end)
end)
