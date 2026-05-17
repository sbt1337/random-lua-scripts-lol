if game.PlaceId == 140409475718339 then return end

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local HttpService       = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer
local Character   = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local Humanoid    = Character:WaitForChild("Humanoid")
local HRP         = Character:WaitForChild("HumanoidRootPart")

do
    local VirtualUser = game:GetService("VirtualUser")
    LocalPlayer.Idled:Connect(function()
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
        print("[StoryFarm] Anti-AFK: simulated input")
    end)
end

local Running             = true
local Attacking           = false
local AttackStartTime     = 0
local CurrentTarget       = nil
local SlotCooldownEnd     = { 0, 0, 0, 0 }
local LastDamageAt        = 0
local LastSeenHP          = nil
local LastAttackAt        = tick()

-- HP baseline for no-damage skip (persists across loop iterations on the same target)
local ActiveTargetHPBaseline = nil
local ActiveTargetBaselineAt = nil

local Stats = {
    AttacksAttempted = 0,
    AttacksAborted   = 0,
    MatchesCompleted = 0,
    Rebirths         = 0,
    TotalKills       = 0,
    TotalDamage      = 0,
    StartTime        = tick(),
}

local WEBHOOK     = "https://discord.com/api/webhooks/1503857688118034662/H3y9e9EUyyZyRnKCQ-X_eIdRpejU8OwStg22dzEoycfGt__iAhRTYmnumIenbFWEckS7"
local LOG_WEBHOOK = "https://discord.com/api/webhooks/1504232139749720074/D_Oe_5gwVDguw2eUeqZbKvpmxBLeajcEZxClzS4tvyAyS80zlL3iOLHsrpOTXUsh_gdu"

local UNDERGROUND_Y          = 10
local ATTACK_HEIGHT          = 5
local ATTACK_TIMEOUT         = 4
local STATS_INTERVAL         = 1800
local AOE_RADIUS             = 12
local ATTACK_WINDOW          = 0.8
local POST_DAMAGE_LOCKOUT    = 1.5
local DAMAGE_ABORT_THRESHOLD = 0.15
local DAMAGE_GRACE_PERIOD    = 0.15
local NO_DAMAGE_TIMEOUT      = 10   -- seconds on a target with no HP change → skip it
local SKIP_DURATION          = 30   -- how long to leave it on the skip list

-- Weak-keyed: if SkipUntil[model] > tick(), don't pick that model
local SkipUntil = setmetatable({}, { __mode = "k" })

local BLOCKING_STATES = { "LightAttack", "NoAttack", "Action", "Stun", "UsingMove" }

local REBIRTH_STEPS = {
    { RequiredLevel = 50, CoinsRequired = 2500000  },
    { RequiredLevel = 50, CoinsRequired = 5000000  },
    { RequiredLevel = 50, CoinsRequired = 7500000  },
    { RequiredLevel = 50, CoinsRequired = 10000000 },
    { RequiredLevel = 50, CoinsRequired = 12500000 },
}

print("[StoryFarm] Loaded")

-- Log webhook (batch + flush every 3s)
local LogBuffer = {}
local RawPrint  = print
local LogStats  = { Sent = 0, Failed = 0, Dropped = 0 }

local function FlushLogs()
    if #LogBuffer == 0 then return end
    local Snapshot = LogBuffer
    LogBuffer = {}
    local Lines, TotalLen = {}, 0
    for i, Line in ipairs(Snapshot) do
        if TotalLen + #Line + 1 > 1800 then
            for j = i, #Snapshot do
                table.insert(LogBuffer, j - i + 1, Snapshot[j])
            end
            break
        end
        table.insert(Lines, Line)
        TotalLen = TotalLen + #Line + 1
    end
    local Payload = table.concat(Lines, "\n")
    if #Payload == 0 then return end
    local RequestFunc = (syn and syn.request) or request or http_request
    if not RequestFunc then
        LogStats.Dropped = LogStats.Dropped + #Lines
        return
    end
    local ok = pcall(function()
        local Body = HttpService:JSONEncode({
            username = "StoryFarm Logs",
            content  = "```" .. Payload .. "```",
        })
        RequestFunc({
            Url     = LOG_WEBHOOK,
            Method  = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = Body,
        })
    end)
    if ok then LogStats.Sent   = LogStats.Sent   + #Lines
    else       LogStats.Failed = LogStats.Failed + #Lines end
end

print = function(...)
    local n     = select("#", ...)
    local Parts = {}
    for i = 1, n do Parts[i] = tostring((select(i, ...))) end
    local Msg = table.concat(Parts, " ")
    pcall(RawPrint, Msg)
    if #LogBuffer >= 300 then table.remove(LogBuffer, 1) end
    table.insert(LogBuffer, os.date("%H:%M:%S") .. " " .. Msg)
end

task.spawn(function()
    while true do
        task.wait(3)
        pcall(FlushLogs)
    end
end)

-- Forward-declared so the heartbeat (below) can reference it before the real definition
local SendWebhook

local LastStuckAlarm = 0
task.spawn(function()
    while true do
        task.wait(30)
        pcall(function()
            local Folder      = workspace:FindFirstChild("Zombies")
            local InFolder    = Folder and #Folder:GetDescendants() or 0
            local SinceAttack = math.floor(tick() - LastAttackAt)
            local GF = workspace:FindFirstChild("GameFinished")    and "Y" or "N"
            local SS = workspace:FindFirstChild("SwitchingSection") and "Y" or "N"
            local CS = workspace:FindFirstChild("Cutscene")         and "Y" or "N"

            print("[Heartbeat] running=" .. tostring(Running)
                .. " zombies=" .. InFolder
                .. " attacks=" .. Stats.AttacksAttempted
                .. " matches=" .. Stats.MatchesCompleted
                .. " sinceAttack=" .. SinceAttack .. "s"
                .. " GF=" .. GF .. " SS=" .. SS .. " CS=" .. CS)

            if SinceAttack > 120 and InFolder > 0 and Running
                and (tick() - LastStuckAlarm) > 300 then
                LastStuckAlarm = tick()
                SendWebhook("Script Stalled", {
                    { name = "SinceAttack",  value = SinceAttack .. "s", inline = true },
                    { name = "InFolder",     value = tostring(InFolder), inline = true },
                    { name = "GameFinished", value = GF,                 inline = true },
                    { name = "Switching",    value = SS,                 inline = true },
                    { name = "Cutscene",     value = CS,                 inline = true },
                    { name = "CurrentTarget",
                      value = (CurrentTarget and CurrentTarget.Parent) and CurrentTarget.Name or "(none)",
                      inline = false },
                }, 15158332)
            end
        end)
    end
end)

SendWebhook = function(Title, Fields, Color)
    pcall(function()
        local Body = HttpService:JSONEncode({
            username = "StoryFarm",
            embeds = {{
                title  = Title,
                color  = Color or 3066993,
                fields = Fields,
            }}
        })
        local RequestFunc = (syn and syn.request) or request or http_request
        RequestFunc({
            Url     = WEBHOOK,
            Method  = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = Body,
        })
    end)
end

local function SendError(Label, Err, Trace)
    local Msg = "[StoryFarm] ERROR in " .. Label .. ": " .. tostring(Err)
    print(Msg)
    if Trace then print(Trace) end
    SendWebhook("Error: " .. Label, {
        { name = "Details", value = "```" .. tostring(Err) .. "```",                              inline = false },
        { name = "Trace",   value = "```" .. tostring(Trace or "no trace"):sub(1, 1000) .. "```", inline = false },
    }, 15158332)
end

local function Safe(Label, Fn, ...)
    local Args = { ... }
    local ok, errOrResult = xpcall(function()
        return Fn(table.unpack(Args))
    end, function(Err)
        return tostring(Err) .. "\n" .. debug.traceback("", 2)
    end)
    if not ok then SendError(Label, errOrResult, nil) end
    return ok, errOrResult
end

local function SafeWrap(Label, Fn)
    return function(...)
        local args = { ... }
        local ok, err = xpcall(function() return Fn(table.unpack(args)) end, function(e)
            return tostring(e) .. "\n" .. debug.traceback("", 2)
        end)
        if not ok then SendError(Label, err, nil) end
    end
end

do
    local LastReported = 0
    pcall(function()
        game:GetService("ScriptContext").Error:Connect(function(Msg, Trace)
            if tick() - LastReported < 2 then return end
            LastReported = tick()
            SendError("UncaughtScriptError", Msg, Trace)
        end)
    end)
    pcall(function()
        game:GetService("LogService").MessageOut:Connect(function(Msg, Type)
            if Type == Enum.MessageType.MessageError then
                if tick() - LastReported < 2 then return end
                LastReported = tick()
                SendError("LogServiceError", Msg, nil)
            end
        end)
    end)
end

task.spawn(function()
    pcall(function()
        SendWebhook("StoryFarm Started", {
            { name = "Time",    value = os.date("%Y-%m-%d %H:%M:%S"), inline = true },
            { name = "PlaceId", value = tostring(game.PlaceId),       inline = true },
        }, 3447003)
    end)
end)

UserInputService.InputBegan:Connect(function(Input, GameProcessed)
    if GameProcessed then return end
    if Input.KeyCode == Enum.KeyCode.PageDown then
        Running = not Running
        print("[StoryFarm] " .. (Running and "Enabled" or "Disabled"))
    end
end)

local function IsCharValid()
    return Character and Character.Parent
        and Humanoid and Humanoid.Parent and Humanoid.Health > 0
        and HRP and HRP.Parent
end

local function IsActionBlocked()
    if not IsCharValid() then return true end
    for _, Name in ipairs(BLOCKING_STATES) do
        if Character:FindFirstChild(Name) then return true end
    end
    if workspace:FindFirstChild("Cutscene")    then return true end
    if workspace:FindFirstChild("GameFinished") then return true end
    return false
end

local function GetMatchStats()
    local MatchConfig  = workspace:FindFirstChild("MatchConfig")
    if not MatchConfig then return nil end
    local PlayersStats = MatchConfig:FindFirstChild("PlayersStats")
    if not PlayersStats then return nil end
    local ok, Decoded  = pcall(HttpService.JSONDecode, HttpService, PlayersStats.Value)
    if not ok or type(Decoded) ~= "table" then return nil end
    return Decoded[LocalPlayer.Name]
end

local function GetData()
    local Data     = LocalPlayer:FindFirstChild("Data")
    if not Data then return nil end
    local Level    = Data:FindFirstChild("BattlepassLevel")
    local Rebirths = Data:FindFirstChild("Rebirths")
    local Coins    = Data:FindFirstChild("Coins")
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
    local Assets  = ReplicatedStorage:FindFirstChild("Assets")
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

-- Root-part resolver
local function ResolveRoot(Model)
    return Model:FindFirstChild("HumanoidRootPart")
        or Model.PrimaryPart
        or Model:FindFirstChild("Torso")
        or Model:FindFirstChild("UpperTorso")
        or Model:FindFirstChild("Head")
        or Model:FindFirstChildWhichIsA("BasePart")
end

-- Health resolver (returns the object, not the value)
local function ResolveHealth(Model)
    local Config = Model:FindFirstChild("Config")
    if Config then
        local H = Config:FindFirstChild("Health")
        if H and (H:IsA("IntValue") or H:IsA("NumberValue")) then return H end
    end
    local Direct = Model:FindFirstChild("Health")
    if Direct and (Direct:IsA("IntValue") or Direct:IsA("NumberValue")) then return Direct end
    for _, Child in ipairs(Model:GetDescendants()) do
        if (Child:IsA("IntValue") or Child:IsA("NumberValue")) and Child.Name == "Health" then
            return Child
        end
    end
    local Hum = Model:FindFirstChildOfClass("Humanoid")
    if Hum then return Hum end
    return nil
end

-- Read current HP value (handles both inverted zombie health and Humanoid)
local function GetHP(Model)
    local H = ResolveHealth(Model)
    if not H then return nil end
    if H:IsA("Humanoid") then return H.Health end
    return H.Value
end

-- ─── ZOMBIE TARGETING ───────────────────────────────────────────────────────
-- No cache. Every pick directly reads workspace.Zombies descendants.
-- If a model has been on the SkipUntil list and time expired, it gets retried
-- automatically next pick cycle.

local function GetLiveZombies()
    local Folder = workspace:FindFirstChild("Zombies")
    if not Folder then return {} end
    return Folder:GetDescendants()
end

local function PickTarget()
    if not IsCharValid() then return nil end
    local Now = tick()
    local Best, BestDist = nil, math.huge

    for _, Model in ipairs(GetLiveZombies()) do
        if not Model:IsA("Model") then continue end
        if SkipUntil[Model] and SkipUntil[Model] > Now then continue end
        local Root = ResolveRoot(Model)
        if not Root then continue end
        local Dist = (Root.Position - HRP.Position).Magnitude
        if Dist < BestDist then
            Best     = Model
            BestDist = Dist
        end
    end

    return Best
end

-- ─── MOVEMENT ───────────────────────────────────────────────────────────────

local function GoUnderground()
    if not IsCharValid() then return end
    HRP.CFrame = CFrame.new(HRP.Position.X, HRP.Position.Y - UNDERGROUND_Y, HRP.Position.Z)
    HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
end

local UnderRaycastParams = RaycastParams.new()
UnderRaycastParams.FilterType = Enum.RaycastFilterType.Exclude

local function RefreshRaycastFilter()
    local Filter = {}
    if Character then table.insert(Filter, Character) end
    for _, Name in ipairs({ "Alive", "Zombies", "Thrown", "Pets", "PET_ANCHORS" }) do
        local F = workspace:FindFirstChild(Name)
        if F then table.insert(Filter, F) end
    end
    UnderRaycastParams.FilterDescendantsInstances = Filter
end

-- Go underground beneath the lowest zombie currently visible in workspace.Zombies
local function GoUnderZombie()
    if not IsCharValid() then return false end

    local BestRoot, BestY = nil, math.huge
    for _, Model in ipairs(GetLiveZombies()) do
        if not Model:IsA("Model") then continue end
        local Root = ResolveRoot(Model)
        if Root and Root.Position.Y < BestY then
            BestRoot = Root
            BestY    = Root.Position.Y
        end
    end

    if not BestRoot then
        GoUnderground()
        return false
    end

    local Pos = BestRoot.Position
    RefreshRaycastFilter()
    local Hit    = workspace:Raycast(Pos + Vector3.new(0, 50, 0), Vector3.new(0, -2000, 0), UnderRaycastParams)
    local TargetY = Hit and (Hit.Position.Y - UNDERGROUND_Y) or (Pos.Y - UNDERGROUND_Y)

    HRP.CFrame = CFrame.new(Pos.X, TargetY, Pos.Z)
    HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
    return true
end

-- Noclip
RunService.Stepped:Connect(function()
    if not Running then return end
    if not Character or not Character.Parent then return end
    Safe("Noclip", function()
        for _, Part in ipairs(Character:GetDescendants()) do
            if Part:IsA("BasePart") then Part.CanCollide = false end
        end
    end)
end)

-- Watchdog: if Attacking gets stuck, force-clear it
task.spawn(function()
    while true do
        task.wait(1)
        if Attacking and (tick() - AttackStartTime) > ATTACK_TIMEOUT then
            print("[StoryFarm] Stuck for " .. math.floor(tick() - AttackStartTime) .. "s, force release")
            Attacking = false
            Safe("WatchdogUnstick", GoUnderground)
        end
    end
end)

-- Authoritative per-slot cooldown from server
task.spawn(function()
    Safe("CooldownHook", function()
        local Assets      = ReplicatedStorage:WaitForChild("Assets", 30)
        local Remotes     = Assets:WaitForChild("Remotes", 30)
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
    for i = 1, 3 do
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

-- Pick the position inside AOE_RADIUS that covers the most zombies
local function PickAttackCenter(Target)
    local Root = ResolveRoot(Target)
    if not Root then return nil, 0 end

    local Best      = Root.Position
    local BestCount = 1
    local Search    = (AOE_RADIUS * 2) * (AOE_RADIUS * 2)
    local Radius2   = AOE_RADIUS * AOE_RADIUS
    local Models    = GetLiveZombies()

    local Candidates = { Best }
    for _, Model in ipairs(Models) do
        if not Model:IsA("Model") then continue end
        local R = ResolveRoot(Model)
        if not R then continue end
        local Pos = R.Position
        local dx, dz = Pos.X - Best.X, Pos.Z - Best.Z
        if dx * dx + dz * dz < Search then
            table.insert(Candidates, Pos)
        end
    end

    for _, Center in ipairs(Candidates) do
        local Count = 0
        for _, Model in ipairs(Models) do
            if not Model:IsA("Model") then continue end
            local R = ResolveRoot(Model)
            if not R then continue end
            local Pos = R.Position
            local dx, dz = Pos.X - Center.X, Pos.Z - Center.Z
            if dx * dx + dz * dz <= Radius2 then Count += 1 end
        end
        if Count > BestCount then
            BestCount = Count
            Best      = Center
        end
    end

    return Best, BestCount
end

-- ─── MAIN ATTACK LOOP ───────────────────────────────────────────────────────

task.spawn(function()
    while true do
        task.wait(0.05)
        if not Running then continue end
        if Attacking then continue end
        if not IsCharValid() then task.wait(0.5) continue end

        Safe("AttackLoop", function()
            if workspace:FindFirstChild("GameFinished")
                or workspace:FindFirstChild("Cutscene")
                or workspace:FindFirstChild("SwitchingSection") then
                GoUnderZombie()
                task.wait(1)
                return
            end

            local Interact = GetInteract()
            if not Interact then return end

            local SlotName, AbilityName = GetAbilityInfo()
            if not SlotName or not AbilityName then task.wait(0.5) return end

            if IsActionBlocked() then GoUnderZombie() task.wait(0.1) return end
            if not AnySlotReady() then GoUnderZombie() task.wait(0.1) return end
            if tick() - LastDamageAt < POST_DAMAGE_LOCKOUT then GoUnderZombie() task.wait(0.1) return end

            local Target = PickTarget()
            if not Target then
                local IdleFor = tick() - LastAttackAt
                if IdleFor > 5 then
                    local MapSpawn  = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("Spawns")
                    local SpawnPart = MapSpawn and MapSpawn:FindFirstChildOfClass("Part")
                    if SpawnPart then
                        HRP.CFrame = SpawnPart.CFrame + Vector3.new(0, 5, 0)
                    else
                        HRP.CFrame = CFrame.new(HRP.Position.X, 10, HRP.Position.Z)
                    end
                    HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                    task.wait(1)
                else
                    GoUnderZombie()
                    task.wait(0.3)
                end
                CurrentTarget          = nil
                ActiveTargetHPBaseline = nil
                ActiveTargetBaselineAt = nil
                return
            end

            -- Reset HP baseline when we switch targets
            if Target ~= CurrentTarget then
                CurrentTarget          = Target
                ActiveTargetHPBaseline = GetHP(Target)
                ActiveTargetBaselineAt = tick()
            end

            Attacking       = true
            AttackStartTime = tick()
            Stats.AttacksAttempted += 1

            local Root = ResolveRoot(Target)
            if not Root or not Root.Parent then
                Stats.AttacksAborted += 1
                Attacking = false
                return
            end

            local Center, Hits = PickAttackCenter(Target)
            if not Center then
                Stats.AttacksAborted += 1
                GoUnderground()
                CurrentTarget          = nil
                ActiveTargetHPBaseline = nil
                ActiveTargetBaselineAt = nil
                Attacking = false
                return
            end

            HRP.CFrame = CFrame.new(Center.X, Center.Y, Center.Z)
            HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            task.wait(0.03)

            local HPBefore  = Humanoid and Humanoid.Health or 0
            local MaxHP     = (Humanoid and Humanoid.MaxHealth and Humanoid.MaxHealth > 0) and Humanoid.MaxHealth or 100
            local DamageCap = MaxHP * DAMAGE_ABORT_THRESHOLD
            local GraceEnd  = tick() + DAMAGE_GRACE_PERIOD

            local Deadline = tick() + ATTACK_WINDOW
            local Fired    = 0
            while tick() < Deadline do
                if not IsCharValid() then break end
                if not Target.Parent then break end

                if tick() > GraceEnd then
                    if Humanoid and (HPBefore - Humanoid.Health) >= DamageCap then
                        LastDamageAt = tick()
                        break
                    end
                end

                if IsActionBlocked() then task.wait(0.03) continue end

                local Slot = PickReadySlot()
                if not Slot then break end

                Interact:FireServer("Ability", Slot, SlotName, AbilityName, "Began")
                task.wait(0.03)
                Interact:FireServer("Ability", Slot, SlotName, AbilityName, "Released")
                LastAttackAt = tick()

                if SlotCooldownEnd[Slot] <= tick() then
                    SlotCooldownEnd[Slot] = tick() + 0.4
                end
                Fired += 1
                task.wait(0.08)
            end

            -- No-damage skip: if HP hasn't budged since we first locked onto this model, skip it
            if Fired > 0 and ActiveTargetBaselineAt and ActiveTargetHPBaseline ~= nil then
                local NowHP = GetHP(Target)
                if NowHP ~= nil then
                    if NowHP ~= ActiveTargetHPBaseline then
                        -- Damage registered — update baseline, reset timer
                        ActiveTargetHPBaseline = NowHP
                        ActiveTargetBaselineAt = tick()
                    elseif tick() - ActiveTargetBaselineAt >= NO_DAMAGE_TIMEOUT then
                        -- 10s with zero HP movement → skip for SKIP_DURATION
                        SkipUntil[Target] = tick() + SKIP_DURATION
                        print("[StoryFarm] No damage on " .. Target.Name
                            .. " for " .. NO_DAMAGE_TIMEOUT .. "s — skipping for " .. SKIP_DURATION .. "s")
                        CurrentTarget          = nil
                        ActiveTargetHPBaseline = nil
                        ActiveTargetBaselineAt = nil
                    end
                end
            end

            GoUnderZombie()
            task.wait(0.05)
            Attacking = false
        end)
    end
end)

-- ─── AUTO REBIRTH ────────────────────────────────────────────────────────────

task.spawn(function()
    while true do
        task.wait(10)
        if not Running then continue end

        Safe("AutoRebirth", function()
            if not CanRebirth() then return end
            local Data    = GetData()
            if not Data then return end
            local Interact = GetInteract()
            if not Interact then return end

            print("[StoryFarm] Rebirthing! Rebirths: " .. Data.Rebirths .. " Level: " .. Data.Level)
            Interact:FireServer("Rebirth")
            Stats.Rebirths += 1

            SendWebhook("Rebirth Performed!", {
                { name = "Rebirths", value = tostring(Data.Rebirths + 1), inline = true },
                { name = "Level",    value = tostring(Data.Level),        inline = true },
                { name = "Coins",    value = tostring(Data.Coins),        inline = true },
            }, 15844367)
        end)
    end
end)

-- ─── END-OF-MATCH ────────────────────────────────────────────────────────────

local LastEndAt = 0
local function HandleMatchEnd()
    if tick() - LastEndAt < 5 then return end
    LastEndAt = tick()

    Safe("EndScreenFired", function()
        local Data  = GetData()
        local Match = GetMatchStats()
        Stats.MatchesCompleted += 1

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
        if workspace:FindFirstChild("GameFinished") then HandleMatchEnd() end
        workspace.ChildAdded:Connect(function(Child)
            if Child.Name == "GameFinished" then HandleMatchEnd() end
        end)
        print("[StoryFarm] Watching workspace.GameFinished...")
    end)
end)

-- ─── AUTO ESCAPE ─────────────────────────────────────────────────────────────

local function GetEscapePart()
    local Map = workspace:FindFirstChild("Map")
    if not Map then return nil end

    local Train = Map:FindFirstChild("Train")
    if Train then
        local Model = Train:FindFirstChild("Model")
        if Model then
            return Model.PrimaryPart or Model:FindFirstChildWhichIsA("BasePart"), "Train"
        end
    end

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

local FireProx = fireproximityprompt
    or (syn and syn.fireproximityprompt)
    or (getgenv and getgenv().fireproximityprompt)

local FiredEscapePrompts = setmetatable({}, { __mode = "k" })

local function IsEscapePrompt(Prompt)
    if not Prompt:IsA("ProximityPrompt") then return false end
    if not Prompt.Enabled then return false end
    local Combined = string.lower(
        (Prompt.Name or "") .. " " .. (Prompt.ActionText or "") .. " " .. (Prompt.ObjectText or "")
    )
    return string.find(Combined, "escape", 1, true) ~= nil
end

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
    local Objectives = workspace:FindFirstChild("Objectives")
    if Objectives then
        for _, Inst in ipairs(Objectives:GetDescendants()) do
            if IsEscapePrompt(Inst) then return Inst end
        end
    end
    for _, Inst in ipairs(workspace:GetDescendants()) do
        if IsEscapePrompt(Inst) then return Inst end
    end
    return nil
end

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

            if FireProx then Safe("FireProx", function() FireProx(Prompt) end) end

            if not FiredEscapePrompts[Prompt] then
                FiredEscapePrompts[Prompt] = tick()
                print("[StoryFarm] Escape prompt: " .. Prompt:GetFullName()
                    .. " action='" .. (Prompt.ActionText or "")
                    .. "' object='" .. (Prompt.ObjectText or "") .. "'"
                    .. " tp=" .. (Part and Part:GetFullName() or "(no part)"))
            end
        end
    end)
end)

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

-- ─── AUTO REVIVE ─────────────────────────────────────────────────────────────

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
    TryRevive()
end

-- ─── AUTO START RAID ─────────────────────────────────────────────────────────

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

-- ─── PERIODIC STATS ──────────────────────────────────────────────────────────

task.spawn(function()
    while true do
        task.wait(STATS_INTERVAL)
        if not Running then continue end

        Safe("StatsReport", function()
            local Data      = GetData()
            local Runtime   = math.floor((tick() - Stats.StartTime) / 60)
            local LiveMatch = GetMatchStats()
            local LiveKills = (LiveMatch and type(LiveMatch.Kills) == "number") and LiveMatch.Kills or 0

            SendWebhook("Status Report", {
                { name = "Runtime",       value = Runtime .. " min",                  inline = true },
                { name = "Matches",       value = tostring(Stats.MatchesCompleted),   inline = true },
                { name = "Rebirths Done", value = tostring(Stats.Rebirths),           inline = true },
                { name = "Total Kills",   value = tostring(Stats.TotalKills + LiveKills), inline = true },
                { name = "Total Damage",  value = tostring(Stats.TotalDamage),        inline = true },
                { name = "Attacks",       value = tostring(Stats.AttacksAttempted),   inline = true },
                { name = "Aborted",       value = tostring(Stats.AttacksAborted),     inline = true },
                { name = "Coins",         value = Data and tostring(Data.Coins)    or "?", inline = true },
                { name = "Level",         value = Data and tostring(Data.Level)    or "?", inline = true },
                { name = "Rebirth",       value = Data and tostring(Data.Rebirths) or "?", inline = true },
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
                SendWebhook("Current Target", { { name = "Target", value = "(none)", inline = true } }, 10070709)
                return
            end

            local HP   = tostring(GetHP(Target) or "?")
            local Dist = "?"
            local Root = ResolveRoot(Target)
            if Root and Root.Parent and HRP and HRP.Parent then
                Dist = tostring(math.floor((Root.Position - HRP.Position).Magnitude))
            end

            SendWebhook("Current Target", {
                { name = "Name",     value = Target.Name, inline = true },
                { name = "HP",       value = HP,          inline = true },
                { name = "Distance", value = Dist,        inline = true },
            }, 3447003)
        end)
    end
end)

-- ─── CHARACTER SETUP ─────────────────────────────────────────────────────────

local function WaitForForceField(Char, Timeout)
    local Deadline = tick() + (Timeout or 5)
    while tick() < Deadline do
        if not Char or not Char.Parent then return end
        if not Char:FindFirstChildOfClass("ForceField") then return end
        task.wait(0.1)
    end
end

local HealthChangedConn = nil
local function SetupCharacter(NewCharacter)
    Safe("SetupCharacter", function()
        print("[StoryFarm] Character ready")
        Character  = NewCharacter
        Humanoid   = NewCharacter:WaitForChild("Humanoid", 10)
        HRP        = NewCharacter:WaitForChild("HumanoidRootPart", 10)
        Attacking  = false
        CurrentTarget          = nil
        ActiveTargetHPBaseline = nil
        ActiveTargetBaselineAt = nil
        SlotCooldownEnd        = { 0, 0, 0, 0 }
        LastDamageAt = 0
        LastSeenHP   = nil

        if not Humanoid or not HRP then
            print("[StoryFarm] Missing Humanoid/HRP after spawn")
            return
        end

        if HealthChangedConn then pcall(function() HealthChangedConn:Disconnect() end) end
        LastSeenHP = Humanoid.Health
        HealthChangedConn = Humanoid.HealthChanged:Connect(function(NewHP)
            if LastSeenHP and NewHP < LastSeenHP - 0.01 then LastDamageAt = tick() end
            LastSeenHP = NewHP
        end)

        HookReviveListener(NewCharacter)

        -- Walk forward to clear spawn ForceField
        Safe("WalkOutOfSpawn", function()
            local MoveTarget = HRP.Position + HRP.CFrame.LookVector * 20
            Humanoid:MoveTo(MoveTarget)
            local Done = false
            local Conn = Humanoid.MoveToFinished:Connect(function() Done = true end)
            local Deadline = tick() + 3
            while not Done and tick() < Deadline do
                if not IsCharValid() then break end
                task.wait(0.1)
            end
            pcall(function() Conn:Disconnect() end)
        end)

        WaitForForceField(NewCharacter, 5)

        if not IsCharValid() then return end
        Safe("InitialUnderground", GoUnderground)
        print("[StoryFarm] Underground, hunting")
    end)
end

LocalPlayer.CharacterAdded:Connect(SetupCharacter)
if Character and Character.Parent then task.spawn(SetupCharacter, Character) end

-- Stuck-floating recovery: if >15s with no attack while zombies exist, TP to SpawnPoint
task.spawn(function()
    while true do
        task.wait(2)
        if not Running then continue end
        if not IsCharValid() then continue end
        if workspace:FindFirstChild("GameFinished") then continue end
        if workspace:FindFirstChild("Cutscene") then continue end
        if tick() - LastAttackAt < 15 then continue end

        local Folder = workspace:FindFirstChild("Zombies")
        if not Folder or #Folder:GetDescendants() == 0 then continue end

        Safe("StuckRecovery", function()
            local Map   = workspace:FindFirstChild("Map")
            local Spawn = Map and Map:FindFirstChild("SpawnPoint")
            if Spawn and Spawn:IsA("BasePart") then
                print("[StoryFarm] Stuck for " .. math.floor(tick() - LastAttackAt) .. "s, TPing to SpawnPoint")
                HRP.CFrame = Spawn.CFrame + Vector3.new(0, 3, 0)
                HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                LastAttackAt = tick()
            end
        end)
    end
end)
