if AutoRejoin then AutoRejoin:Stop() end

if not game:IsLoaded() then
    task.delay(60, function()
        if NoShutdown then return end

        if not game:IsLoaded() then
            return game:Shutdown()
        end

        local Code = game:GetService'GuiService':GetErrorCode().Value

        if Code >= Enum.ConnectionError.DisconnectErrors.Value then
            return game:Shutdown()
        end
    end)

    game.Loaded:Wait()
end

-- ===== CONFIG =====
local AUTOREJOIN_HOST = 'localhost:5242'
local AUTOREJOIN_PATH = '/AutoRejoin'
-- ====================

local AutoRejoin = {}

local WSConnect = syn and syn.websocket.connect or
    (Krnl and (function() repeat task.wait() until Krnl.WebSocket and Krnl.WebSocket.connect return Krnl.WebSocket.connect end)()) or
    WebSocket and WebSocket.connect

if not WSConnect then
    if messagebox then
        messagebox(('AutoRejoin encountered an error while launching!\n\n%s'):format(
            'Your exploit (' .. (identifyexecutor and identifyexecutor() or 'UNKNOWN') .. ') is not supported'),
            'Roblox Account Manager', 0)
    end
    return
end

local TeleportService = game:GetService'TeleportService'
local InputService    = game:GetService'UserInputService'
local HttpService     = game:GetService'HttpService'
local RunService      = game:GetService'RunService'
local GuiService      = game:GetService'GuiService'
local Players         = game:GetService'Players'
local LocalPlayer     = Players.LocalPlayer
if not LocalPlayer then
    repeat LocalPlayer = Players.LocalPlayer task.wait() until LocalPlayer
    task.wait(0.5)
end

local UGS = UserSettings():GetService'UserGameSettings'
local OldVolume = UGS.MasterVolume

LocalPlayer.OnTeleport:Connect(function(State)
    if State == Enum.TeleportState.Started and AutoRejoin.IsConnected then
        AutoRejoin:Stop()
    end
end)

-- ===================== Signal =====================
local Signal = {}
do
    Signal.__index = Signal

    function Signal.new()
        local self = setmetatable({ _BindableEvent = Instance.new'BindableEvent' }, Signal)
        return self
    end

    function Signal:Connect(Callback)
        assert(typeof(Callback) == 'function', 'function expected, got ' .. typeof(Callback))
        return self._BindableEvent.Event:Connect(Callback)
    end

    function Signal:Fire(...)
        self._BindableEvent:Fire(...)
    end

    function Signal:Wait()
        return self._BindableEvent.Event:Wait()
    end

    function Signal:Disconnect()
        if self._BindableEvent then
            self._BindableEvent:Destroy()
        end
    end
end

-- ===================== AutoRejoin Core =====================
do
    local BTN_CLICK = 'ButtonClicked:'

    AutoRejoin.Connected       = Signal.new()
    AutoRejoin.Disconnected    = Signal.new()
    AutoRejoin.MessageReceived = Signal.new()

    AutoRejoin.Commands    = {}
    AutoRejoin.Connections = {}

    AutoRejoin.ShutdownTime            = 45
    AutoRejoin.ShutdownOnTeleportError = true

    function AutoRejoin:Send(Command, Payload)
        assert(self.Socket ~= nil, 'websocket is nil')
        assert(self.IsConnected, 'websocket not connected')
        assert(typeof(Command) == 'string', 'Command must be a string, got ' .. typeof(Command))

        if Payload then
            assert(typeof(Payload) == 'table', 'Payload must be a table, got ' .. typeof(Payload))
        end

        local Message = HttpService:JSONEncode {
            Name = Command,
            Payload = Payload
        }

        self.Socket:Send(Message)
    end

    function AutoRejoin:SetAutoRelaunch(Enabled)
        self:Send('SetAutoRelaunch', { Content = Enabled and 'true' or 'false' })
    end

    function AutoRejoin:SetPlaceId(PlaceId)
        self:Send('SetPlaceId', { Content = PlaceId })
    end

    function AutoRejoin:SetJobId(JobId)
        self:Send('SetJobId', { Content = JobId })
    end

    function AutoRejoin:Echo(Message)
        self:Send('Echo', { Content = Message })
    end

    function AutoRejoin:Log(...)
        local T = {}
        for _, Value in pairs{ ... } do
            table.insert(T, tostring(Value))
        end
        self:Send('Log', { Content = table.concat(T, ' ') })
    end

    function AutoRejoin:CreateElement(ElementType, Name, Content, Size, Margins, Table)
        assert(typeof(Name) == 'string', 'string expected on argument #1, got ' .. typeof(Name))
        assert(typeof(Content) == 'string', 'string expected on argument #2, got ' .. typeof(Content))
        assert(Name:find'%W' == nil, 'argument #1 cannot contain whitespace')

        if Size then
            assert(typeof(Size) == 'table' and #Size == 2,
                'table with 2 arguments expected on argument #3, got ' .. typeof(Size))
        end
        if Margins then
            assert(typeof(Margins) == 'table' and #Margins == 4,
                'table with 4 arguments expected on argument #4, got ' .. typeof(Margins))
        end

        local Payload = {
            Name    = Name,
            Content = Content,
            Size    = Size and table.concat(Size, ','),
            Margin  = Margins and table.concat(Margins, ','),
        }

        if Table then
            for Index, Value in pairs(Table) do
                Payload[Index] = Value
            end
        end

        self:Send(ElementType, Payload)
    end

    function AutoRejoin:CreateButton(...)   return self:CreateElement('CreateButton', ...)   end
    function AutoRejoin:CreateTextBox(...)  return self:CreateElement('CreateTextBox', ...)  end
    function AutoRejoin:CreateLabel(...)    return self:CreateElement('CreateLabel', ...)    end

    function AutoRejoin:CreateNumeric(Name, Value, DecimalPlaces, Increment, Size, Margins)
        return self:CreateElement('CreateNumeric', Name, tostring(Value), Size, Margins,
            { DecimalPlaces = DecimalPlaces, Increment = Increment })
    end

    function AutoRejoin:NewLine()
        return self:Send('NewLine')
    end

    function AutoRejoin:GetText(Name)
        return self:WaitForMessage('ElementText:', 'GetText', { Name = Name })
    end

    function AutoRejoin:SetRelaunch(Seconds)
        self:Send('SetRelaunch', { Seconds = Seconds })
    end

    function AutoRejoin:WaitForMessage(Header, Message, Payload)
        if Message then
            task.defer(self.Send, self, Message, Payload)
        end

        local Msg
        while true do
            Msg = self.MessageReceived:Wait()
            if Msg:sub(1, #Header) == Header then
                break
            end
        end

        return Msg:sub(#Header + 1)
    end

    function AutoRejoin:Connect(Host, Bypass)
        if not Bypass and self.IsConnected then
            return 'Ignoring connection request, AutoRejoin is already connected'
        end

        Host = Host or AUTOREJOIN_HOST

        while true do
            for _, Connection in pairs(self.Connections) do
                Connection:Disconnect()
            end
            table.clear(self.Connections)

            if self.IsConnected then
                self.IsConnected = false
                self.Socket = nil
                self.Disconnected:Fire()
            end

            if self.Terminated then break end

            local Url = ('ws://%s%s?name=%s&id=%s&jobId=%s'):format(
                Host,
                AUTOREJOIN_PATH,
                LocalPlayer.Name,
                LocalPlayer.UserId,
                game.JobId
            )

            print('[AutoRejoin] Connecting to:', Url)

            local Success, Socket = pcall(WSConnect, Url)
            if not Success then
                warn('[AutoRejoin] Connect failed:', Socket)
                task.wait(12)
                continue
            end

            self.Socket = Socket
            self.IsConnected = true

            table.insert(self.Connections, Socket.OnMessage:Connect(function(Message)
                self.MessageReceived:Fire(Message)
            end))

            table.insert(self.Connections, Socket.OnClose:Connect(function()
                self.IsConnected = false
                self.Disconnected:Fire()
            end))

            self.Connected:Fire()

            while self.IsConnected do
                local Success, Error = pcall(self.Send, self, 'ping')
                if not Success or self.Terminated then break end
                task.wait(1)
            end
        end
    end

    function AutoRejoin:Stop()
        self.IsConnected = false
        self.Terminated = true
        self.Disconnected:Fire()

        if self.Socket then
            pcall(function() self.Socket:Close() end)
        end
    end

    function AutoRejoin:AddCommand(Name, Function)
        self.Commands[Name] = Function
    end

    function AutoRejoin:RemoveCommand(Name)
        self.Commands[Name] = nil
    end

    function AutoRejoin:OnButtonClick(Name, Function)
        self:AddCommand(BTN_CLICK .. Name, Function)
    end

    AutoRejoin.MessageReceived:Connect(function(Message)
        local S = Message:find(' ')

        if S then
            local Command, Rest = Message:sub(1, S - 1):lower(), Message:sub(S + 1)

            if AutoRejoin.Commands[Command] then
                local Success, Error = pcall(AutoRejoin.Commands[Command], Rest)
                if not Success and Error then
                    AutoRejoin:Log(('Error with command `%s`: %s'):format(Command, Error))
                end
            end
        elseif AutoRejoin.Commands[Message] then
            local Success, Error = pcall(AutoRejoin.Commands[Message], Message)
            if not Success and Error then
                AutoRejoin:Log(('Error with command `%s`: %s'):format(Message, Error))
            end
        end
    end)
end

-- ===================== Default Commands =====================
do
    AutoRejoin:AddCommand('execute', function(Message)
        local Function, Error = loadstring(Message)

        if Function then
            local Env = getfenv(Function)
            Env.Player = LocalPlayer
            Env.print = function(...)
                local T = {}
                for _, Value in pairs{ ... } do
                    table.insert(T, tostring(Value))
                end
                AutoRejoin:Log(table.concat(T, ' '))
            end

            if newcclosure then Env.print = newcclosure(Env.print) end

            local S, E = pcall(Function)
            if not S then AutoRejoin:Log(E) end
        else
            AutoRejoin:Log(Error)
        end
    end)

    AutoRejoin:AddCommand('teleport', function(Message)
        local S = Message:find(' ')
        local PlaceId = S and Message:sub(1, S - 1) or Message
        local JobId   = S and Message:sub(S + 1)

        if JobId then
            TeleportService:TeleportToPlaceInstance(tonumber(PlaceId), JobId)
        else
            TeleportService:Teleport(tonumber(PlaceId))
        end
    end)

    AutoRejoin:AddCommand('rejoin', function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId)
    end)

    AutoRejoin:AddCommand('mute', function()
        if (UGS.MasterVolume - OldVolume) > 0.01 then
            OldVolume = UGS.MasterVolume
        end
        UGS.MasterVolume = 0
    end)

    AutoRejoin:AddCommand('unmute', function()
        UGS.MasterVolume = OldVolume
    end)

    AutoRejoin:AddCommand('performance', function(Message)
        if _PERF then return end

        _PERF = true
        _TARGETFPS = 8

        if Message and tonumber(Message) then
            _TARGETFPS = tonumber(Message)
        end

        local OldLevel = settings().Rendering.QualityLevel

        RunService:Set3dRenderingEnabled(false)
        settings().Rendering.QualityLevel = 1

        InputService.WindowFocused:Connect(function()
            RunService:Set3dRenderingEnabled(true)
            settings().Rendering.QualityLevel = OldLevel
            setfpscap(60)
        end)

        InputService.WindowFocusReleased:Connect(function()
            OldLevel = settings().Rendering.QualityLevel
            RunService:Set3dRenderingEnabled(false)
            settings().Rendering.QualityLevel = 1
            setfpscap(_TARGETFPS)
        end)

        setfpscap(_TARGETFPS)
    end)

    -- ===== Auto Rejoin ล้วน ๆ =====
    AutoRejoin:AddCommand('autorejoin', function(Message)
        local Seconds = tonumber(Message) or 300
        AutoRejoin:SetRelaunch(Seconds)
        AutoRejoin:Log('Auto rejoin set to ' .. Seconds .. 's')
    end)
end

-- ===================== Connections =====================
do
    GuiService.ErrorMessageChanged:Connect(function()
        if NoShutdown then return end

        local Code = GuiService:GetErrorCode().Value

        if Code >= Enum.ConnectionError.DisconnectErrors.Value then
            if not AutoRejoin.ShutdownOnTeleportError and Code > Enum.ConnectionError.PlacelaunchOtherError.Value then
                return
            end

            task.delay(AutoRejoin.ShutdownTime, game.Shutdown, game)
        end
    end)
end

-- ===================== Export =====================
local GEnv = getgenv()
GEnv.AutoRejoin = AutoRejoin
GEnv.performance = AutoRejoin.Commands.performance

if not AutoRejoin_Version then
    AutoRejoin:Connect()
end
