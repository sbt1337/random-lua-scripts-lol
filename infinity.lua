-- InfinityFarm v2.0
-- TP to zombies, M1 + ability spam, auto card pick, wave skip, auto revive
-- Executor: Delta (100% UNC)

local Players     = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer

-- ── Webhooks ──────────────────────────────────────────────────────────────────
local WEBHOOK     = "https://discord.com/api/webhooks/1371564289376366592/CrY0XxM93cxB2jC0iUPimz0VBPt3VNRHRqBqbQBkaDhLvs9kl1KNg88OaqujCxEF6OXV"
local LOG_WEBHOOK = "https://discord.com/api/webhooks/1504232139749720074/D_Oe_5gwVDguw2eUeqZbKvpmxBLeajcEZxClzS4tvyAyS80zlL3iOLHsrpOTXUsh_gdu"
local RAW_URL     = "https://raw.githubusercontent.com/sbt1337/random-lua-scripts-lol/refs/heads/main/infinity.lua"

-- ── State ─────────────────────────────────────────────────────────────────────
local Running = true

-- ── Remotes ───────────────────────────────────────────────────────────────────
local Assets         = game:GetService("ReplicatedStorage"):WaitForChild("Assets")
local Remotes        = Assets:WaitForChild("Remotes")
local Requests       = Assets:WaitForChild("Requests")
local Interact       = Remotes:WaitForChild("Interact")
local UsedAbility    = Remotes:WaitForChild("UsedAbility")
local DrawCardRemote = Remotes:WaitForChild("DrawCard")
local FuncInteract   = Requests:WaitForChild("FuncInteract")
local Utils          = require(Assets:WaitForChild("Modules"):WaitForChild("Utils"))

-- ── Character ─────────────────────────────────────────────────────────────────
local Character, HRP, Humanoid

local function RefreshChar()
    Character = LocalPlayer.Character
    if not Character then return false end
    HRP       = Character:FindFirstChild("HumanoidRootPart")
    Humanoid  = Character:FindFirstChildOfClass("Humanoid")
    return HRP ~= nil
end

RefreshChar()
LocalPlayer.CharacterAdded:Connect(function(C)
    Character = C
    HRP       = C:WaitForChild("HumanoidRootPart")
    Humanoid  = C:WaitForChild("Humanoid")
end)

local function IsCharValid()
    return Character and Character.Parent
        and HRP and HRP.Parent
        and Humanoid and Humanoid.Health > 0
end

-- ── Ability + Gadget info ─────────────────────────────────────────────────────
local ShowcasingSlot, ShowcasingAbility
local GadgetSlotKey, GadgetName

local function RefreshAbility()
    local Data = LocalPlayer:FindFirstChild("Data")
    local AS   = Data and Data:FindFirstChild("AbilitySlots")
    if not AS then return end
    local ok, Decoded = pcall(function() return Utils.Decode(AS.Value) end)
    if not ok then return end
    for Key, Slot in pairs(Decoded) do
        if Slot and Slot.Showcasing then
            ShowcasingSlot    = Key
            ShowcasingAbility = Slot.Name
            return
        end
    end
end

local function RefreshGadget()
    local Data = LocalPlayer:FindFirstChild("Data")
    local GS   = Data and Data:FindFirstChild("GadgetSlots")
    if not GS then return end
    local ok, Decoded = pcall(function() return Utils.Decode(GS.Value) end)
    if not ok then return end
    for Key, Slot in pairs(Decoded) do
        if Slot and Slot.Equipped then
            GadgetSlotKey = Key
            GadgetName    = Slot.Name
            return
        end
    end
end

RefreshAbility()
RefreshGadget()
task.spawn(function()
    local Data = LocalPlayer:WaitForChild("Data")
    local AS   = Data:WaitForChild("AbilitySlots")
    local GS   = Data:WaitForChild("GadgetSlots")
    AS:GetPropertyChangedSignal("Value"):Connect(RefreshAbility)
    GS:GetPropertyChangedSignal("Value"):Connect(RefreshGadget)
end)

-- ── Cooldowns ─────────────────────────────────────────────────────────────────
local SlotEnd   = { Z = 0, X = 0, C = 0, V = 0 }
local GadgetEnd = 0

UsedAbility.OnClientEvent:Connect(function(_, Duration, _, SlotKey)
    if SlotKey and SlotEnd[SlotKey] ~= nil then
        SlotEnd[SlotKey] = tick() + (Duration or 0)
    end
end)

local function FireGadget()
    if not GadgetSlotKey or not GadgetName then return end
    if tick() < GadgetEnd then return end
    Interact:FireServer("Gadget", GadgetSlotKey, GadgetName, "Began")
    task.wait(0.08)
    Interact:FireServer("Gadget", GadgetSlotKey, GadgetName, "Released")
    GadgetEnd = tick() + 1  -- soft lock 1s; server will enforce true CD via meter
end

local SlotNums = { Z = 1, X = 2, C = 3, V = 4 }

local function FireAbility(Key)
    if not ShowcasingSlot or not ShowcasingAbility then return end
    Interact:FireServer("Ability", SlotNums[Key], ShowcasingSlot, ShowcasingAbility, "Began")
    task.wait(0.08)
    Interact:FireServer("Ability", SlotNums[Key], ShowcasingSlot, ShowcasingAbility, "Released")
    SlotEnd[Key] = tick() + 0.3
end

-- ── Stats ─────────────────────────────────────────────────────────────────────
local Stats = { M1 = 0, Abilities = 0, Revives = 0, Cards = 0, StartTime = tick() }

-- ── Logging ───────────────────────────────────────────────────────────────────
local LogBuffer, LogLock = {}, false
local _print = print
print = function(...)
    _print(...)
    local msg = os.date("%H:%M:%S") .. " " .. table.concat({...}, " ")
    table.insert(LogBuffer, msg)
    if #LogBuffer > 200 then table.remove(LogBuffer, 1) end
end

task.spawn(function()
    while true do
        task.wait(3)
        if LogLock or #LogBuffer == 0 then continue end
        LogLock = true
        local Snap = LogBuffer ; LogBuffer = {}
        LogLock = false
        pcall(function()
            HttpService:RequestAsync({
                Url = LOG_WEBHOOK, Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = HttpService:JSONEncode({
                    username = "InfinityFarm",
                    content  = "```\n" .. table.concat(Snap, "\n"):sub(1, 1900) .. "\n```"
                })
            })
        end)
    end
end)

-- ── Webhook ───────────────────────────────────────────────────────────────────
local WHThrottle = {}
local function SendWebhook(Title, Fields, Color)
    pcall(function()
        HttpService:RequestAsync({
            Url = WEBHOOK, Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode({
                username = "InfinityFarm",
                embeds = {{ title = Title, color = Color or 3066993, fields = Fields }}
            })
        })
    end)
end

local function SendError(Label, Err)
    local Now = tick()
    if WHThrottle[Label] and Now - WHThrottle[Label] < 30 then return end
    WHThrottle[Label] = Now
    SendWebhook("Error: " .. Label, {
        { name = "Error", value = "```" .. tostring(Err):sub(1, 900) .. "```", inline = false }
    }, 15158332)
end

local function Safe(Label, Fn)
    local ok, err = xpcall(Fn, function(e) return e .. "\n" .. debug.traceback() end)
    if not ok then
        print("[InfinityFarm] Error in " .. Label .. ": " .. tostring(err))
        SendError(Label, err)
    end
end

-- ── Reload GUI ────────────────────────────────────────────────────────────────
local function MakeReloadButton()
    -- Clean up any leftover from previous run
    local old = LocalPlayer.PlayerGui:FindFirstChild("InfinityFarmGUI")
    if old then old:Destroy() end

    local sg = Instance.new("ScreenGui")
    sg.Name           = "InfinityFarmGUI"
    sg.ResetOnSpawn   = false
    sg.IgnoreGuiInset = true
    sg.Parent         = LocalPlayer.PlayerGui

    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(0, 150, 0, 38)
    btn.Position         = UDim2.new(0.5, -75, 0.5, -19)
    btn.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
    btn.TextColor3       = Color3.fromRGB(255, 75, 75)
    btn.Font             = Enum.Font.GothamBold
    btn.TextSize         = 14
    btn.Text             = "⟳  RELOAD FARM"
    btn.BorderSizePixel  = 0
    btn.Parent           = sg
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)

    local stroke = Instance.new("UIStroke", btn)
    stroke.Color     = Color3.fromRGB(255, 75, 75)
    stroke.Thickness = 1.2

    btn.MouseButton1Click:Connect(function()
        Running = false
        print("[InfinityFarm] Reloading...")
        sg:Destroy()
        task.wait(0.3)
        loadstring(game:HttpGet(RAW_URL))()
    end)
end

MakeReloadButton()

-- ── Anti-AFK ──────────────────────────────────────────────────────────────────
LocalPlayer.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
    print("[InfinityFarm] Anti-AFK fired")
end)

-- ── Zombie picker ─────────────────────────────────────────────────────────────
local function IsAlive(Model)
    if not Model or not Model.Parent then return false end
    local Config = Model:FindFirstChild("Config")
    local Health = Config and Config:FindFirstChild("Health")
    return Health and Health.Value > 0
end

local function PickNearest()
    local ZF = workspace:FindFirstChild("Zombies")
    if not ZF or not IsCharValid() then return nil end
    local Best, BestDist = nil, math.huge
    local Pos = HRP.Position
    for _, M in ipairs(ZF:GetChildren()) do
        if IsAlive(M) then
            local R = M:FindFirstChild("HumanoidRootPart")
            if R then
                local D = (R.Position - Pos).Magnitude
                if D < BestDist then Best, BestDist = M, D end
            end
        end
    end
    return Best
end

-- ── Auto Card Selection ───────────────────────────────────────────────────────
-- Priority: ExtraLife (+1 Life) → Wealth (+5% Coins/EXP) → Damage (+5% DMG) → random
local CARD_PRIORITY = { "ExtraLife", "Wealth", "Damage" }

DrawCardRemote.OnClientEvent:Connect(function(Action, Cards)
    -- Log raw event so we can diagnose format issues
    print("[InfinityFarm] DrawCard event: action=" .. tostring(Action)
        .. " cards=" .. tostring(Cards and #Cards or "nil"))
    if Cards then
        for i, C in ipairs(Cards) do
            print("[InfinityFarm]   card[" .. i .. "] = " .. tostring(C and C.CardName or "?")
                .. " lvl=" .. tostring(C and C.Level or "?"))
        end
    end

    if Action ~= "Draw" or not Cards or #Cards == 0 then return end

    task.spawn(function()
        task.wait(0.6)

        -- Build offered set
        local Offered = {}
        for _, Card in ipairs(Cards) do
            if Card.CardName then Offered[Card.CardName] = true end
        end

        -- Pick by priority
        local Pick = nil
        for _, Want in ipairs(CARD_PRIORITY) do
            if Offered[Want] then Pick = Want break end
        end
        if not Pick then Pick = Cards[1].CardName end

        print("[InfinityFarm] Selecting card: " .. tostring(Pick))
        local ok, err = pcall(function()
            FuncInteract:InvokeServer("DrawCard", Pick)
        end)
        if not ok then
            print("[InfinityFarm] Card invoke failed: " .. tostring(err))
        else
            Stats.Cards += 1
            print("[InfinityFarm] Card picked: " .. tostring(Pick))
        end
    end)
end)

-- ── Wave skip ─────────────────────────────────────────────────────────────────
task.spawn(function()
    while Running do
        task.wait(0.5)
        Safe("WaveSkip", function()
            if workspace:GetAttribute("InfiniteStarting") then
                Interact:FireServer("VoteSkipInfinite")
            end
        end)
    end
end)

-- ── Auto revive ───────────────────────────────────────────────────────────────
task.spawn(function()
    while Running do
        task.wait(0.5)
        Safe("AutoRevive", function()
            local C = LocalPlayer.Character
            if C and C:GetAttribute("CanRevive") then
                Interact:FireServer("Revive")
                Stats.Revives += 1
                print("[InfinityFarm] Revived")
            end
        end)
    end
end)

-- ── Attack loop ───────────────────────────────────────────────────────────────
local LastM1 = 0

task.spawn(function()
    while Running do
        task.wait(0.05)
        Safe("AttackLoop", function()
            if workspace:GetAttribute("Intermission") then task.wait(0.3) return end
            if not IsCharValid() then task.wait(0.5) return end
            if not ShowcasingAbility then RefreshAbility() task.wait(0.5) return end

            local Target = PickNearest()
            if not Target then task.wait(0.3) return end

            local Root = Target:FindFirstChild("HumanoidRootPart")
            if not Root then return end

            -- TP directly onto the zombie if too far
            if (HRP.Position - Root.Position).Magnitude > 8 then
                HRP.CFrame = CFrame.new(Root.Position)
                HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                task.wait(0.05)
            end

            -- M1 (server-enforced ~0.4s CD)
            local Now = tick()
            if Now - LastM1 >= 0.42 then
                Interact:FireServer("M1", ShowcasingAbility, workspace:GetServerTimeNow())
                LastM1 = Now
                Stats.M1 += 1
            end

            -- Ability rotation Z → X → C (one per tick to keep M1 tight)
            for _, Key in ipairs({ "Z", "X", "C" }) do
                if tick() >= SlotEnd[Key] then
                    FireAbility(Key)
                    Stats.Abilities += 1
                    task.wait(0.05)
                    break
                end
            end

            -- Gadget (E) — fire whenever meter allows
            FireGadget()
        end)
    end
end)

-- ── Heartbeat every 30s ───────────────────────────────────────────────────────
task.spawn(function()
    while Running do
        task.wait(30)
        Safe("Heartbeat", function()
            local W    = workspace:GetAttribute("WavesPassed") or 0
            local Up   = math.floor(tick() - Stats.StartTime)
            local ZF   = workspace:FindFirstChild("Zombies")
            local Alive = 0
            if ZF then for _, M in ipairs(ZF:GetChildren()) do if IsAlive(M) then Alive += 1 end end end
            print(string.format("[Heartbeat] wave=%d alive=%d m1=%d abil=%d revives=%d cards=%d up=%dm",
                W, Alive, Stats.M1, Stats.Abilities, Stats.Revives, Stats.Cards, math.floor(Up/60)))
        end)
    end
end)

-- ── Stats webhook every 30 min ────────────────────────────────────────────────
task.spawn(function()
    while Running do
        task.wait(1800)
        Safe("StatsWebhook", function()
            local W  = workspace:GetAttribute("WavesPassed") or 0
            local Up = math.floor(tick() - Stats.StartTime)
            SendWebhook("Infinity Stats", {
                { name = "Wave",      value = tostring(W),                                                      inline = true },
                { name = "Uptime",    value = math.floor(Up/3600).."h "..math.floor((Up%3600)/60).."m",        inline = true },
                { name = "M1 Fired",  value = tostring(Stats.M1),                                               inline = true },
                { name = "Abilities", value = tostring(Stats.Abilities),                                         inline = true },
                { name = "Revives",   value = tostring(Stats.Revives),                                           inline = true },
                { name = "Cards",     value = tostring(Stats.Cards),                                             inline = true },
                { name = "Ability",   value = tostring(ShowcasingAbility),                                       inline = true },
            }, 3066993)
        end)
    end
end)

-- ── Startup ───────────────────────────────────────────────────────────────────
task.spawn(function()
    task.wait(2)
    RefreshAbility()
    RefreshGadget()
    local W = workspace:GetAttribute("WavesPassed") or 0
    SendWebhook("InfinityFarm v2 Started", {
        { name = "Wave",    value = tostring(W),                 inline = true },
        { name = "Ability", value = tostring(ShowcasingAbility), inline = true },
        { name = "Slot",    value = tostring(ShowcasingSlot),    inline = true },
        { name = "Gadget",  value = tostring(GadgetName),        inline = true },
    }, 3066993)
    print("[InfinityFarm] v2 started | ability=" .. tostring(ShowcasingAbility)
        .. " gadget=" .. tostring(GadgetName))
end)
