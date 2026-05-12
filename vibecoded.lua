local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local HRP = Character:WaitForChild("HumanoidRootPart")

if game.PlaceId == 140409475718339 then return end

local Running = true

-- Webhook error reporter
local WEBHOOK = "https://discord.com/api/webhooks/1503794681803440321/qXasXkOVlDvjunThkHMv-2FzXsyBB74yamzlWDgygmxPnHRJ2xWRRBu5FOdXKj99jaQS"

local function SendError(label, err)
    print("[AutoFarm] ERROR in " .. label .. ": " .. tostring(err))
    local ok, _ = pcall(function()
        local Body = HttpService:JSONEncode({
            username = "AutoFarm",
            embeds = {{
                title = "Error: " .. label,
                description = "```" .. tostring(err) .. "```",
                color = 15158332
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
end

-- Wraps a function in pcall and reports errors to webhook
local function Safe(label, fn)
    local ok, err = pcall(fn)
    if not ok then
        SendError(label, err)
    end
end

print("[AutoFarm] Loaded")

-- PgDn toggle
UserInputService.InputBegan:Connect(function(Input, GameProcessed)
    if GameProcessed then return end
    if Input.KeyCode == Enum.KeyCode.PageDown then
        Running = not Running
        print("[AutoFarm] " .. (Running and "Enabled" or "Disabled"))
    end
end)

-- Decode AbilitySlots to get the showcasing slot name + ability name
local function GetAbilityInfo()
    local AbilitySlots = LocalPlayer:FindFirstChild("Data") and LocalPlayer.Data:FindFirstChild("AbilitySlots")
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

-- Safely get Interact remote
local function GetInteract()
    local Assets = ReplicatedStorage:FindFirstChild("Assets")
    if not Assets then return nil end
    local Remotes = Assets:FindFirstChild("Remotes")
    if not Remotes then return nil end
    return Remotes:FindFirstChild("Interact")
end

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

-- Safely get Bus Left Leg
local function GetBusLeg()
    local Map = workspace:FindFirstChild("Map")
    if not Map then return nil end
    local Bus = Map:FindFirstChild("Bus")
    if not Bus then return nil end
    return Bus:FindFirstChild("Left Leg")
end

-- TP loop - independent thread, abilities fire immediately regardless
local BusLeg = nil
task.spawn(function()
    Safe("TPLoop", function()
        print("[AutoFarm] Waiting for Bus Left Leg...")
        while not BusLeg do
            BusLeg = GetBusLeg()
            task.wait(1)
        end
        print("[AutoFarm] Bus Left Leg found, locking position")

        while true do
            task.wait(0.5)
            if not Running then continue end
            if not HRP or not HRP.Parent then continue end

            BusLeg = GetBusLeg()
            if not BusLeg then
                print("[AutoFarm] Bus Left Leg missing, retrying...")
                continue
            end

            local LegPos = BusLeg.Position
            local LegSize = BusLeg.Size
            HRP.CFrame = CFrame.new(LegPos.X, LegPos.Y - (LegSize.Y / 2) + 2, LegPos.Z)
        end
    end)
end)

-- Ability spam - Z=1, X=2, C=3, V=4
task.spawn(function()
    while true do
        task.wait(0.1)
        if not Running then continue end

        Safe("AbilitySpam", function()
            local Interact = GetInteract()
            if not Interact then return end

            local SlotName, AbilityName = GetAbilityInfo()
            if not SlotName or not AbilityName then
                task.wait(1)
                return
            end

            for i = 1, 4 do
                Interact:FireServer("Ability", i, SlotName, AbilityName, "Began")
                task.wait(0.05)
                Interact:FireServer("Ability", i, SlotName, AbilityName, "Released")
                task.wait(0.05)
            end
        end)
    end
end)

-- Auto retry - fires PlayAgain the moment the Retry button appears on the EndScreen
task.spawn(function()
    Safe("RetryWatcher", function()
        local HUD = LocalPlayer.PlayerGui:WaitForChild("HUD")
        local RetryButton = HUD:WaitForChild("EndScreen"):WaitForChild("Main"):WaitForChild("Retry")

        RetryButton:GetPropertyChangedSignal("Visible"):Connect(function()
            if not RetryButton.Visible or not Running then return end
            Safe("FirePlayAgain", function()
                local Interact = GetInteract()
                if not Interact then return end
                print("[AutoFarm] Retry button visible, firing PlayAgain")
                task.wait(0.5)
                Interact:FireServer("PlayAgain")
            end)
        end)

        print("[AutoFarm] Watching for EndScreen Retry button...")
    end)
end)

-- Auto start - fires VoteSkipRaid when RaidStarting goes true
task.spawn(function()
    Safe("StartWatcher", function()
        local function FireStart()
            if not Running then return end
            if not workspace:GetAttribute("RaidStarting") then return end
            Safe("FireVoteSkipRaid", function()
                local Interact = GetInteract()
                if not Interact then return end
                print("[AutoFarm] RaidStarting active, voting to start")
                task.wait(0.5)
                Interact:FireServer("VoteSkipRaid")
            end)
        end

        workspace:GetAttributeChangedSignal("RaidStarting"):Connect(FireStart)
        task.wait(0.5) -- wait for _LocalFX to finish initializing before firing on load
        FireStart()
        print("[AutoFarm] Watching for RaidStarting...")
    end)
end)

-- On each respawn: re-grab refs and break forcefield by nudging velocity for 2s
LocalPlayer.CharacterAdded:Connect(function(NewCharacter)
    Safe("CharacterAdded", function()
        print("[AutoFarm] Character spawned, breaking forcefield...")
        Character = NewCharacter
        HRP = NewCharacter:WaitForChild("HumanoidRootPart")

        task.wait(1)

        local ForceConn
        local Start = tick()
        ForceConn = RunService.Stepped:Connect(function()
            Safe("ForcefieldNudge", function()
                if tick() - Start >= 2 then
                    ForceConn:Disconnect()
                    print("[AutoFarm] Forcefield done, resuming farm")
                    return
                end
                if HRP and HRP.Parent then
                    HRP.Velocity = Vector3.new(0, 0, -10)
                end
            end)
        end)
    end)
end)
