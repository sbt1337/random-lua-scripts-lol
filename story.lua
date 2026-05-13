if game.PlaceId == 140409475718339 then return end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local Humanoid = Character:WaitForChild("Humanoid")
local HRP = Character:WaitForChild("HumanoidRootPart")

local Running = true
local Attacking = false
local AttackStartTime = 0
local CurrentTarget = nil
local CurrentTargetIsBoss = false
local SlotCooldownEnd = { 0, 0, 0, 0 } -- per-slot cooldown end time, set by UsedAbility event

local Stats = {
    AttacksAttempted = 0,
    AttacksAborted = 0,
    MatchesCompleted = 0,
    Rebirths = 0,
    TotalKills = 0,
    TotalDamage = 0,
    StartTime = tick(),
}

local WEBHOOK = "https://discord.com/api/webhooks/1503857688118034662/H3y9e9EUyyZyRnKCQ-X_eIdRpejU8OwStg22dzEoycfGt__iAhRTYmnumIenbFWEckS7"
local UNDERGROUND_Y = 10
local ATTACK_HEIGHT = 5
local MAX_ZOMBIE_RANGE = 10000 -- effectively uncapped so we follow zombies into new sections
local ATTACK_COOLDOWN_PER_ZOMBIE = 0.3 -- just enough for death events to propagate
local ATTACK_TIMEOUT = 4
local STATS_INTERVAL = 1800
local AOE_RADIUS = 12 -- assumed melee/AOE hitbox radius for cluster-picking
local ATTACK_WINDOW = 1.5 -- max seconds we spend at the surface per cycle

-- Live caches updated by events (not polling)
-- [Model] = { Root = HRP, Health = IntValue, Conns = {connections} }
local AliveZombies = {}
local AliveBosses = {}
local RecentlyAttacked = {}

-- Game's blocking state child names (from Utils.ActionCheck)
local BLOCKING_STATES = { "LightAttack", "NoAttack", "Action", "Stun", "UsingMove" }

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
    pcall(function()
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

-- Character validity
local function IsCharValid()
    return Character and Character.Parent
        and Humanoid and Humanoid.Parent and Humanoid.Health > 0
        and HRP and HRP.Parent
end

-- Game's ActionCheck mirror - returns true if we CAN'T act
local function IsActionBlocked()
    if not IsCharValid() then return true end
    for _, Name in ipairs(BLOCKING_STATES) do
        if Character:FindFirstChild(Name) then return true end
    end
    if workspace:FindFirstChild("Cutscene") then return true end
    if workspace:FindFirstChild("GameFinished") then return true end
    return false
end

-- Read our current-match stats from workspace.MatchConfig.PlayersStats (JSON StringValue).
-- Per _LocalFX.lua:16002 the value is HttpService:JSONDecode'd; entries look like
-- { Kills = N, DamageDealt = N, Drops = {...} }
local function GetMatchStats()
    local MatchConfig = workspace:FindFirstChild("MatchConfig")
    if not MatchConfig then return nil end
    local PlayersStats = MatchConfig:FindFirstChild("PlayersStats")
    if not PlayersStats then return nil end

    local ok, Decoded = pcall(HttpService.JSONDecode, HttpService, PlayersStats.Value)
    if not ok or type(Decoded) ~= "table" then return nil end
    return Decoded[LocalPlayer.Name]
end

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

-- Generic unregister - removes from whichever cache holds it
local function Unregister(Cache, Model)
    local Entry = Cache[Model]
    if not Entry then return end
    for _, Conn in ipairs(Entry.Conns) do
        pcall(function() Conn:Disconnect() end)
    end
    Cache[Model] = nil
end

local function UnregisterZombie(Model) Unregister(AliveZombies, Model) end
local function UnregisterBoss(Model) Unregister(AliveBosses, Model) end

-- Generic register - works for both zombies (in workspace.Zombies) and bosses (CollectionService tagged)
local function ResolveRoot(Model)
    return Model:FindFirstChild("HumanoidRootPart")
        or Model.PrimaryPart
        or Model:FindFirstChild("Torso")
        or Model:FindFirstChild("UpperTorso")
        or Model:FindFirstChild("Head")
        or Model:FindFirstChildWhichIsA("BasePart")
end

local function Register(Cache, Model, OnDeath)
    if not Model:IsA("Model") then return end
    if Cache[Model] then return end

    task.spawn(function()
        Safe("Register", function()
            local Config = Model:WaitForChild("Config", 10)
            if not Config or not Model.Parent then
                print("[StoryFarm] Register: no Config on " .. Model.Name)
                return
            end

            local Health = Config:WaitForChild("Health", 10)
            if not Health or not Model.Parent then
                print("[StoryFarm] Register: no Config.Health on " .. Model.Name)
                return
            end

            local Root = ResolveRoot(Model)
            if not Root then
                local Deadline = tick() + 5
                while not Root and tick() < Deadline and Model.Parent do
                    task.wait(0.05)
                    Root = ResolveRoot(Model)
                end
                if not Root then
                    print("[StoryFarm] Register: no root part on " .. Model.Name)
                    return
                end
            end

            if Health.Value <= 0 then return end
            if Model:GetAttribute("Died") then return end

            local Conns = {}

            table.insert(Conns, Health:GetPropertyChangedSignal("Value"):Connect(function()
                if Health.Value <= 0 then OnDeath(Model) end
            end))

            table.insert(Conns, Model:GetAttributeChangedSignal("Died"):Connect(function()
                if Model:GetAttribute("Died") then OnDeath(Model) end
            end))

            table.insert(Conns, Model.ChildRemoved:Connect(function(Child)
                if Child == Root then OnDeath(Model) end
            end))

            table.insert(Conns, Model.AncestryChanged:Connect(function()
                if not Model.Parent then OnDeath(Model) end
            end))

            Cache[Model] = { Root = Root, Health = Health, Conns = Conns }
        end)
    end)
end

-- Bootstrap zombies (survives Zombies folder being destroyed/replaced between matches)
local ZombieFolderConns = {}
local CurrentZombieFolder = nil

local function AttachZombieFolder(Folder)
    if CurrentZombieFolder == Folder then return end

    for _, Conn in ipairs(ZombieFolderConns) do
        pcall(function() Conn:Disconnect() end)
    end
    ZombieFolderConns = {}
    CurrentZombieFolder = Folder

    for _, Child in ipairs(Folder:GetChildren()) do
        Register(AliveZombies, Child, UnregisterZombie)
    end

    table.insert(ZombieFolderConns, Folder.ChildAdded:Connect(function(Child)
        Register(AliveZombies, Child, UnregisterZombie)
    end))
    table.insert(ZombieFolderConns, Folder.ChildRemoved:Connect(UnregisterZombie))
    table.insert(ZombieFolderConns, Folder.AncestryChanged:Connect(function()
        if not Folder.Parent then CurrentZombieFolder = nil end
    end))

    print("[StoryFarm] Attached to Zombies folder")
end

task.spawn(function()
    Safe("ZombieBootstrap", function()
        local Existing = workspace:FindFirstChild("Zombies")
        if Existing then AttachZombieFolder(Existing) end

        workspace.ChildAdded:Connect(function(Child)
            if Child.Name == "Zombies" then AttachZombieFolder(Child) end
        end)

        -- Periodic rescan + diagnostic (cheap safety net)
        while true do
            task.wait(5)
            local Folder = workspace:FindFirstChild("Zombies")
            if Folder and Folder ~= CurrentZombieFolder then
                AttachZombieFolder(Folder)
            end
            if Folder then
                local InFolder, Tracked = 0, 0
                for _, Child in ipairs(Folder:GetChildren()) do
                    if Child:IsA("Model") then
                        InFolder = InFolder + 1
                        if not AliveZombies[Child] then
                            Register(AliveZombies, Child, UnregisterZombie)
                        end
                    end
                end
                for _ in pairs(AliveZombies) do Tracked = Tracked + 1 end
                if InFolder > 0 and Tracked == 0 then
                    print("[StoryFarm] Rescan: " .. InFolder .. " zombies in folder but 0 tracked")
                end
            end
        end
    end)
end)

-- Bootstrap bosses (CollectionService tagged "RaidBoss" or "Boss" with IsRaidBoss=true)
task.spawn(function()
    local function HandleBoss(Model)
        Register(AliveBosses, Model, UnregisterBoss)
    end

    for _, Boss in ipairs(CollectionService:GetTagged("RaidBoss")) do
        HandleBoss(Boss)
    end
    for _, Boss in ipairs(CollectionService:GetTagged("Boss")) do
        if Boss:GetAttribute("IsRaidBoss") then HandleBoss(Boss) end
    end

    CollectionService:GetInstanceAddedSignal("RaidBoss"):Connect(HandleBoss)
    CollectionService:GetInstanceAddedSignal("Boss"):Connect(function(Boss)
        if Boss:GetAttribute("IsRaidBoss") then HandleBoss(Boss) end
    end)
    CollectionService:GetInstanceRemovedSignal("RaidBoss"):Connect(UnregisterBoss)
    CollectionService:GetInstanceRemovedSignal("Boss"):Connect(UnregisterBoss)

    print("[StoryFarm] Boss tracker active")
end)

-- Scan a cache for the nearest valid target
-- IgnoreCooldown=true forces selection even from recently-attacked (used as fallback when nothing else available)
local function ScanCache(Cache, Unregister, IgnoreCooldown)
    local Best, BestDist = nil, math.huge
    local Now = tick()

    for Model, Data in pairs(Cache) do
        if not Model.Parent then Unregister(Model) continue end
        if Data.Health.Value <= 0 then Unregister(Model) continue end
        if not Data.Root or not Data.Root.Parent then Unregister(Model) continue end
        if Model:GetAttribute("Died") then Unregister(Model) continue end
        if Model:GetAttribute("Frozen") then continue end
        if not IgnoreCooldown and RecentlyAttacked[Model] and RecentlyAttacked[Model] > Now then continue end

        local Dx = Data.Root.Position.X - HRP.Position.X
        local Dz = Data.Root.Position.Z - HRP.Position.Z
        local Dist = math.sqrt(Dx * Dx + Dz * Dz)
        if Dist > MAX_ZOMBIE_RANGE then continue end

        if Dist < BestDist then
            Best = Model
            BestDist = Dist
        end
    end

    return Best
end

-- Boss first, then zombies. If nothing passes cooldown, retry ignoring cooldown so we don't stall on the last enemy
local function PickNearestZombie()
    if not IsCharValid() then return nil end

    local Boss = ScanCache(AliveBosses, UnregisterBoss, false)
    if Boss then return Boss, true end

    local Z = ScanCache(AliveZombies, UnregisterZombie, false)
    if Z then return Z, false end

    -- Fallback: nothing passed the cooldown - try again ignoring it
    Boss = ScanCache(AliveBosses, UnregisterBoss, true)
    if Boss then return Boss, true end

    return ScanCache(AliveZombies, UnregisterZombie, true), false
end

-- Lookup entry from either cache
local function GetTargetEntry(Model)
    return AliveBosses[Model] or AliveZombies[Model]
end

local function IsZombieStillAlive(Model)
    if not Model then return false end
    local Data = GetTargetEntry(Model)
    if not Data then return false end
    if not Model.Parent then return false end
    if Data.Health.Value <= 0 then return false end
    if not Data.Root or not Data.Root.Parent then return false end
    if Model:GetAttribute("Died") then return false end
    return true
end

-- Movement
local function IsZombieDataLive(Data)
    if not Data or not Data.Root or not Data.Root.Parent then return false end
    if not Data.Health or not Data.Health.Parent then return false end
    return Data.Health.Value > 0
end

local function GoUnderground()
    if not IsCharValid() then return end
    HRP.CFrame = CFrame.new(HRP.Position.X, HRP.Position.Y - UNDERGROUND_Y, HRP.Position.Z)
    HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
end

-- TP to under any tracked zombie/boss so we never sit in dead space between attacks
local function GoUnderZombie()
    if not IsCharValid() then return false end

    for _, Cache in ipairs({ AliveBosses, AliveZombies }) do
        for _, Data in pairs(Cache) do
            if IsZombieDataLive(Data) then
                local Pos = Data.Root.Position
                HRP.CFrame = CFrame.new(Pos.X, Pos.Y - UNDERGROUND_Y, Pos.Z)
                HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                return true
            end
        end
    end

    GoUnderground()
    return false
end

local function GoToZombie(Root)
    if not IsCharValid() then return end
    if not Root or not Root.Parent then return end
    HRP.CFrame = CFrame.new(Root.Position + Vector3.new(0, ATTACK_HEIGHT, 0))
end

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

-- Watchdog + cleanup
task.spawn(function()
    while true do
        task.wait(1)
        local Now = tick()

        for Model, Expiry in pairs(RecentlyAttacked) do
            if not Model.Parent or Expiry < Now then
                RecentlyAttacked[Model] = nil
            end
        end

        if Attacking and (Now - AttackStartTime) > ATTACK_TIMEOUT then
            print("[StoryFarm] Stuck for " .. math.floor(Now - AttackStartTime) .. "s, force release")
            Attacking = false
            Safe("WatchdogUnstick", GoUnderground)
        end
    end
end)

-- Authoritative per-slot cooldown from server (already accounts for CD reduction cosmetics)
task.spawn(function()
    Safe("CooldownHook", function()
        local Assets = ReplicatedStorage:WaitForChild("Assets", 30)
        local Remotes = Assets:WaitForChild("Remotes", 30)
        local UsedAbility = Remotes:WaitForChild("UsedAbility", 30)

        UsedAbility.OnClientEvent:Connect(function(_, Duration, _AbilityName, KeyIndex)
            if type(Duration) ~= "number" then return end
            if type(KeyIndex) ~= "number" or KeyIndex < 1 or KeyIndex > 4 then return end
            SlotCooldownEnd[KeyIndex] = tick() + Duration
        end)

        print("[StoryFarm] Cooldown hook armed")
    end)
end)

local function PickReadySlot()
    local Now = tick()
    for i = 1, 3 do -- skip V (slot 4)
        if SlotCooldownEnd[i] <= Now then return i end
    end
    return nil
end

local function AnySlotReady()
    local Now = tick()
    for i = 1, 3 do
        if SlotCooldownEnd[i] <= Now then return true end
    end
    return false
end

-- Pick a TP center that maximizes zombies inside AOE_RADIUS
local function PickAttackCenter(Target)
    local TargetData = GetTargetEntry(Target)
    if not IsZombieDataLive(TargetData) then return nil, 0 end

    local Best = TargetData.Root.Position
    local BestCount = 1
    local Search = (AOE_RADIUS * 2) * (AOE_RADIUS * 2)

    local Candidates = { Best }
    for _, Data in pairs(AliveZombies) do
        if IsZombieDataLive(Data) then
            local Pos = Data.Root.Position
            local Dx = Pos.X - Best.X
            local Dz = Pos.Z - Best.Z
            if (Dx * Dx + Dz * Dz) < Search then
                table.insert(Candidates, Pos)
            end
        end
    end

    local Radius2 = AOE_RADIUS * AOE_RADIUS
    for _, Center in ipairs(Candidates) do
        local Count = 0
        for _, Data in pairs(AliveZombies) do
            if IsZombieDataLive(Data) then
                local Pos = Data.Root.Position
                local Dx = Pos.X - Center.X
                local Dz = Pos.Z - Center.Z
                if (Dx * Dx + Dz * Dz) <= Radius2 then
                    Count = Count + 1
                end
            end
        end
        if Count > BestCount then
            BestCount = Count
            Best = Center
        end
    end

    return Best, BestCount
end

-- Main attack loop
task.spawn(function()
    while true do
        task.wait(0.05)
        if not Running then continue end
        if Attacking then continue end
        if not IsCharValid() then task.wait(0.5) continue end

        Safe("AttackLoop", function()
            -- Game finished / cutscene = wait it out
            if workspace:FindFirstChild("GameFinished") or workspace:FindFirstChild("Cutscene") then
                task.wait(1)
                return
            end

            local Interact = GetInteract()
            if not Interact then return end

            local SlotName, AbilityName = GetAbilityInfo()
            if not SlotName or not AbilityName then task.wait(0.5) return end

            -- Wait underground until abilities are off cooldown / state clears
            if IsActionBlocked() then
                GoUnderZombie()
                task.wait(0.1)
                return
            end
            if not AnySlotReady() then
                GoUnderZombie()
                task.wait(0.1)
                return
            end

            local Target, IsBoss = PickNearestZombie()
            if not Target then
                GoUnderZombie()
                task.wait(0.3)
                return
            end

            Attacking = true
            AttackStartTime = tick()
            Stats.AttacksAttempted = Stats.AttacksAttempted + 1

            -- Final check before TP
            if not IsZombieStillAlive(Target) then
                Stats.AttacksAborted = Stats.AttacksAborted + 1
                Attacking = false
                return
            end

            local Data = GetTargetEntry(Target)
            local Root = Data and Data.Root
            if not Root or not Root.Parent then
                Stats.AttacksAborted = Stats.AttacksAborted + 1
                Attacking = false
                return
            end

            if IsBoss then print("[StoryFarm] Boss target acquired: " .. Target.Name) end

            CurrentTarget = Target
            CurrentTargetIsBoss = IsBoss
            RecentlyAttacked[Target] = tick() + ATTACK_COOLDOWN_PER_ZOMBIE

            -- Pick the densest cluster around the target so one swing hits the most zombies
            local Center, Hits = PickAttackCenter(Target)
            if not Center then
                Stats.AttacksAborted = Stats.AttacksAborted + 1
                GoUnderground()
                Attacking = false
                return
            end

            HRP.CFrame = CFrame.new(Center + Vector3.new(0, ATTACK_HEIGHT, 0))
            HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            task.wait(0.03)

            if not IsZombieStillAlive(Target) and Hits <= 1 then
                Stats.AttacksAborted = Stats.AttacksAborted + 1
                GoUnderground()
                Attacking = false
                return
            end

            -- Cycle through ready slots (1..3) until window closes or all on CD
            local Deadline = tick() + ATTACK_WINDOW
            local Fired = 0
            while tick() < Deadline do
                if not IsCharValid() then break end

                if IsActionBlocked() then
                    task.wait(0.03)
                    continue
                end

                local Slot = PickReadySlot()
                if not Slot then break end

                Interact:FireServer("Ability", Slot, SlotName, AbilityName, "Began")
                task.wait(0.03)
                Interact:FireServer("Ability", Slot, SlotName, AbilityName, "Released")

                -- Soft cooldown until server confirms via UsedAbility (prevents same-slot spam if event is late)
                if SlotCooldownEnd[Slot] <= tick() then
                    SlotCooldownEnd[Slot] = tick() + 0.4
                end
                Fired = Fired + 1
                task.wait(0.08)
            end

            GoUnderground()
            task.wait(0.05)
            Attacking = false
        end)
    end
end)

-- Auto rebirth
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

-- End-of-match: triggered when the server creates workspace.GameFinished
-- (Create("GameFinished", "Folder", workspace) at _LocalFX.lua:15994).
-- More reliable than watching UI properties since the folder is server-authoritative.
local LastEndAt = 0
local function HandleMatchEnd()
    if tick() - LastEndAt < 5 then return end -- dedupe rapid double-fires
    LastEndAt = tick()

    Safe("EndScreenFired", function()
        local Data = GetData()
        local Match = GetMatchStats()
        Stats.MatchesCompleted = Stats.MatchesCompleted + 1

        local MatchKills  = (Match and type(Match.Kills)       == "number") and Match.Kills       or 0
        local MatchDamage = (Match and type(Match.DamageDealt) == "number") and Match.DamageDealt or 0
        Stats.TotalKills  = Stats.TotalKills  + MatchKills
        Stats.TotalDamage = Stats.TotalDamage + MatchDamage

        SendWebhook("Match Over", {
            { name = "Coins",       value = Data and tostring(Data.Coins)    or "?", inline = true },
            { name = "Level",       value = Data and tostring(Data.Level)    or "?", inline = true },
            { name = "Rebirths",    value = Data and tostring(Data.Rebirths) or "?", inline = true },
            { name = "Match Kills", value = tostring(MatchKills),                    inline = true },
            { name = "Match Dmg",   value = tostring(MatchDamage),                   inline = true },
            { name = "Total Kills", value = tostring(Stats.TotalKills),              inline = true },
        }, 3066993)

        if not Running then return end

        -- Retry until the server actually accepts PlayAgain. We can't fully tell when the
        -- new match has started, so just keep firing until GameFinished is gone.
        local Deadline = tick() + 20
        while tick() < Deadline do
            if not workspace:FindFirstChild("GameFinished") then break end
            local Interact = GetInteract()
            if Interact then
                Safe("FirePlayAgain", function() Interact:FireServer("PlayAgain") end)
            end
            task.wait(1)
        end
    end)
end

task.spawn(function()
    Safe("EndScreenWatcher", function()
        local Existing = workspace:FindFirstChild("GameFinished")
        if Existing then HandleMatchEnd() end

        workspace.ChildAdded:Connect(function(Child)
            if Child.Name == "GameFinished" then HandleMatchEnd() end
        end)

        print("[StoryFarm] Watching workspace.GameFinished...")
    end)
end)

-- Auto-escape: TP to the Train (Shibuya) or Door (Impel Down) once enemies are clear.
-- Server then fires the Escaped remote (_LocalFX.lua:15892) which teleports us out.
local function GetEscapePart()
    local Map = workspace:FindFirstChild("Map")
    if not Map then return nil end

    -- Shibuya: workspace.Map.Train.Model
    local Train = Map:FindFirstChild("Train")
    if Train then
        local Model = Train:FindFirstChild("Model")
        if Model then
            return Model.PrimaryPart or Model:FindFirstChildWhichIsA("BasePart"), "Train"
        end
    end

    -- Impel Down: workspace.Map.Objective.Entries.Model.Door
    local Objective = Map:FindFirstChild("Objective")
    if Objective then
        local Entries = Objective:FindFirstChild("Entries")
        if Entries then
            local Model = Entries:FindFirstChild("Model")
            if Model then
                local Door = Model:FindFirstChild("Door")
                if Door then
                    if Door:IsA("BasePart") then return Door, "Door" end
                    return Door.PrimaryPart or Door:FindFirstChildWhichIsA("BasePart"), "Door"
                end
            end
        end
    end

    return nil
end

-- Escape ProximityPrompt scanner. Decompile has no ProximityPrompt scripts but the prompt
-- may be authored directly in workspace.Map as a static instance — scan workspace descendants
-- for any ProximityPrompt whose Name/ActionText/ObjectText contains "escape".
local FireProx = fireproximityprompt
    or (syn and syn.fireproximityprompt)
    or (getgenv and getgenv().fireproximityprompt)

local FiredEscapePrompts = setmetatable({}, { __mode = "k" }) -- weak keys so GC'd prompts drop

local function IsEscapePrompt(Prompt)
    if not Prompt:IsA("ProximityPrompt") then return false end
    if not Prompt.Enabled then return false end
    local Combined = string.lower(
        (Prompt.Name       or "") .. " " ..
        (Prompt.ActionText or "") .. " " ..
        (Prompt.ObjectText or "")
    )
    return string.find(Combined, "escape", 1, true) ~= nil
end

-- Walk up the prompt's ancestry to find the first BasePart we can stand on.
local function ResolvePromptPart(Prompt)
    local Node = Prompt.Parent
    while Node and Node ~= workspace do
        if Node:IsA("BasePart") then return Node end
        if Node:IsA("Model") then
            local Pivot = Node.PrimaryPart or Node:FindFirstChildWhichIsA("BasePart")
            if Pivot then return Pivot end
        end
        Node = Node.Parent
    end
    return nil
end

local function FindEscapePrompt()
    -- Per user: prompt lives under workspace.Objectives. Check there first.
    local Objectives = workspace:FindFirstChild("Objectives")
    if Objectives then
        for _, Inst in ipairs(Objectives:GetDescendants()) do
            if IsEscapePrompt(Inst) then return Inst end
        end
    end
    -- Fallback to full workspace scan
    for _, Inst in ipairs(workspace:GetDescendants()) do
        if IsEscapePrompt(Inst) then return Inst end
    end
    return nil
end

-- Spam-TP to the prompt's parent part and fire the prompt every tick while one exists.
-- Potassium's fireproximityprompt takes ONE arg (the prompt) and bypasses distance,
-- but TPing on top of it is harmless and protects against server-side distance checks.
task.spawn(function()
    Safe("EscapePromptSpammer", function()
        while true do
            task.wait(0.1)
            if not Running then continue end
            if not IsCharValid() then continue end

            local Prompt = FindEscapePrompt()
            if not Prompt then continue end

            local Part = ResolvePromptPart(Prompt)
            if Part then
                HRP.CFrame = Part.CFrame + Vector3.new(0, 3, 0)
                HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            end

            if FireProx then
                Safe("FireProx", function() FireProx(Prompt) end)
            end

            if not FiredEscapePrompts[Prompt] then
                FiredEscapePrompts[Prompt] = tick()
                print("[StoryFarm] Escape prompt: " .. Prompt:GetFullName()
                    .. " | action='" .. (Prompt.ActionText or "")
                    .. "' object='" .. (Prompt.ObjectText or "") .. "'"
                    .. " | tp=" .. (Part and Part:GetFullName() or "(no part)"))
            end
        end
    end)
end)

-- Objective gate: only escape when workspace.Objectives has a visible child
-- whose Name starts with "Escape" (e.g. "Escape Shibuya!", "Escape Impel Down!").
-- Per ObjectivesPanel.lua:50 the objective name IS the displayed text.
local function HasEscapeObjective()
    local Folder = workspace:FindFirstChild("Objectives")
    if not Folder then return false end
    for _, Obj in ipairs(Folder:GetChildren()) do
        if not Obj:GetAttribute("Hidden") then
            if string.sub(Obj.Name, 1, 6):lower() == "escape" then
                return true, Obj.Name
            end
        end
    end
    return false
end

task.spawn(function()
    while true do
        task.wait(1)
        if not Running then continue end
        if workspace:FindFirstChild("GameFinished") then continue end
        if workspace:FindFirstChild("Cutscene") then continue end
        if not IsCharValid() then continue end

        local Active, ObjName = HasEscapeObjective()
        if not Active then continue end

        Safe("AutoEscape", function()
            local Part, Kind = GetEscapePart()
            if not Part then return end

            print("[StoryFarm] Objective '" .. ObjName .. "' active, TPing to " .. Kind)
            HRP.CFrame = Part.CFrame + Vector3.new(0, 3, 0)
            HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        end)
    end
end)

-- Auto-revive (Ultra Instinct / standard revive). Server sets CanRevive=true on Character;
-- fire Interact:FireServer("Revive") to consume it. Matches ClientUI.lua:1330 and CharacterHandler/Client.lua:1756.
local ReviveAttrConn = nil
local function HookReviveListener(Char)
    if ReviveAttrConn then
        pcall(function() ReviveAttrConn:Disconnect() end)
        ReviveAttrConn = nil
    end
    if not Char then return end

    local function TryRevive()
        if not Running then return end
        if not Char or not Char.Parent then return end
        if not Char:GetAttribute("CanRevive") then return end
        Safe("AutoRevive", function()
            local Interact = GetInteract()
            if not Interact then return end
            print("[StoryFarm] CanRevive=true, firing Revive")
            Interact:FireServer("Revive")
        end)
    end

    ReviveAttrConn = Char:GetAttributeChangedSignal("CanRevive"):Connect(TryRevive)
    TryRevive() -- in case it's already true at hook time
end

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

-- Periodic stats
task.spawn(function()
    while true do
        task.wait(STATS_INTERVAL)
        if not Running then continue end

        Safe("StatsReport", function()
            local Data = GetData()
            local Runtime = math.floor((tick() - Stats.StartTime) / 60)

            local LiveMatch = GetMatchStats()
            local LiveKills = (LiveMatch and type(LiveMatch.Kills) == "number") and LiveMatch.Kills or 0
            local SessionKills = Stats.TotalKills + LiveKills -- include current in-progress match

            SendWebhook("Status Report", {
                { name = "Runtime",         value = Runtime .. " min",                       inline = true },
                { name = "Matches",         value = tostring(Stats.MatchesCompleted),        inline = true },
                { name = "Rebirths Done",   value = tostring(Stats.Rebirths),                inline = true },
                { name = "Total Kills",     value = tostring(SessionKills),                  inline = true },
                { name = "Total Damage",    value = tostring(Stats.TotalDamage),             inline = true },
                { name = "Attacks",         value = tostring(Stats.AttacksAttempted),        inline = true },
                { name = "Aborted",         value = tostring(Stats.AttacksAborted),          inline = true },
                { name = "Zombies Tracked", value = tostring((function()
                    local n = 0; for _ in pairs(AliveZombies) do n = n + 1 end; return n
                end)()), inline = true },
                { name = "Bosses Tracked",  value = tostring((function()
                    local n = 0; for _ in pairs(AliveBosses) do n = n + 1 end; return n
                end)()), inline = true },
                { name = "Coins",           value = Data and tostring(Data.Coins)    or "?", inline = true },
                { name = "Level",           value = Data and tostring(Data.Level)    or "?", inline = true },
                { name = "Current Rebirth", value = Data and tostring(Data.Rebirths) or "?", inline = true },
            }, 7506394)
        end)
    end
end)

-- Current target ping (every 5s)
task.spawn(function()
    while true do
        task.wait(5)
        if not Running then continue end

        Safe("CurrentTargetPing", function()
            local Target = CurrentTarget
            if not Target or not Target.Parent then
                SendWebhook("Current Target", {
                    { name = "Target", value = "(none)", inline = true },
                }, 10070709)
                return
            end

            local Data = GetTargetEntry(Target)
            local HP = Data and Data.Health and Data.Health.Value or "?"
            local Dist = "?"
            if Data and Data.Root and Data.Root.Parent and HRP and HRP.Parent then
                Dist = tostring(math.floor((Data.Root.Position - HRP.Position).Magnitude))
            end

            SendWebhook("Current Target", {
                { name = "Name",     value = Target.Name,                      inline = true },
                { name = "Type",     value = CurrentTargetIsBoss and "BOSS" or "Zombie", inline = true },
                { name = "HP",       value = tostring(HP),                     inline = true },
                { name = "Distance", value = Dist,                             inline = true },
            }, CurrentTargetIsBoss and 15158332 or 3447003)
        end)
    end
end)

-- Wait for the ForceField on the character to be destroyed (or timeout)
local function WaitForForceField(Char, Timeout)
    local Deadline = tick() + (Timeout or 5)
    while tick() < Deadline do
        if not Char or not Char.Parent then return end
        local FF = Char:FindFirstChildOfClass("ForceField")
        if not FF then return end
        task.wait(0.1)
    end
end

-- Apply to initial character too
local function SetupCharacter(NewCharacter)
    Safe("SetupCharacter", function()
        print("[StoryFarm] Character ready")
        Character = NewCharacter
        Humanoid = NewCharacter:WaitForChild("Humanoid", 10)
        HRP = NewCharacter:WaitForChild("HumanoidRootPart", 10)
        Attacking = false
        CurrentTarget = nil
        SlotCooldownEnd = { 0, 0, 0, 0 }

        if not Humanoid or not HRP then
            print("[StoryFarm] Missing Humanoid/HRP after spawn")
            return
        end

        -- Arm auto-revive (CanRevive attribute on Character)
        HookReviveListener(NewCharacter)

        -- Walk 20 studs forward to break forcefield / unstick from spawn
        Safe("WalkOutOfSpawn", function()
            local Target = HRP.Position + HRP.CFrame.LookVector * 20
            Humanoid:MoveTo(Target)

            local Done = false
            local Conn = Humanoid.MoveToFinished:Connect(function() Done = true end)
            local Deadline = tick() + 3
            while not Done and tick() < Deadline do
                if not IsCharValid() then break end
                task.wait(0.1)
            end
            pcall(function() Conn:Disconnect() end)
        end)

        -- Wait out any remaining forcefield invuln
        WaitForForceField(NewCharacter, 5)

        if not IsCharValid() then return end
        Safe("InitialUnderground", GoUnderground)
        print("[StoryFarm] Underground, hunting")
    end)
end

LocalPlayer.CharacterAdded:Connect(SetupCharacter)

-- Run setup for the character we already had at script load
if Character and Character.Parent then
    task.spawn(SetupCharacter, Character)
end

-- Last-resort target watchdog: if cache is empty and a raid is active, force a folder rescan
task.spawn(function()
    while true do
        task.wait(8)
        if not Running then continue end

        local HaveAny = false
        for _ in pairs(AliveZombies) do HaveAny = true break end
        if HaveAny then continue end
        for _ in pairs(AliveBosses) do HaveAny = true break end
        if HaveAny then continue end

        -- No tracked enemies — try to recover
        Safe("TargetWatchdog", function()
            local Folder = workspace:FindFirstChild("Zombies")
            if Folder then
                if Folder ~= CurrentZombieFolder then AttachZombieFolder(Folder) end
                for _, Child in ipairs(Folder:GetChildren()) do
                    if Child:IsA("Model") and not AliveZombies[Child] then
                        Register(AliveZombies, Child, UnregisterZombie)
                    end
                end
            end
            for _, Tag in ipairs({ "RaidBoss", "Boss" }) do
                for _, Boss in ipairs(CollectionService:GetTagged(Tag)) do
                    if not AliveBosses[Boss] then
                        if Tag == "Boss" and not Boss:GetAttribute("IsRaidBoss") then continue end
                        Register(AliveBosses, Boss, UnregisterBoss)
                    end
                end
            end
        end)
    end
end)
