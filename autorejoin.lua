AutoRejoin_Version = 105

local AutoRejoin = {}

local HttpService = game:GetService('HttpService')
local Players     = game:GetService('Players')
local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    repeat LocalPlayer = Players.LocalPlayer task.wait() until LocalPlayer
    task.wait(0.5)
end

-- ===== CONFIG =====
local AUTOREJOIN_HOST       = 'localhost:5242'
local AUTOREJOIN_PATH       = '/AutoRejoin'
local PING_INTERVAL         = 1     -- ส่ง ping ทุกกี่วินาที
local RECONNECT_DELAY       = 5     -- รอกี่วินาทีก่อน reconnect
local PING_TIMEOUT          = 15    -- ถ้าไม่ได้ข้อความอะไรเลยเกินกี่วิ ถือว่าขาด
-- ====================

-- ===== WebSocket =====
local WSConnect = syn and syn.websocket.connect or
    (Krnl and (function()
        repeat task.wait() until Krnl.WebSocket and Krnl.WebSocket.connect
        return Krnl.WebSocket.connect
    end)()) or
    WebSocket and WebSocket.connect

if not WSConnect then
    if messagebox then
        messagebox(('AutoRejoin: Your exploit (%s) is not supported')
            :format(identifyexecutor and identifyexecutor() or 'UNKNOWN'))
    end
    return
end

-- ===== Signal =====
local Signal = {}
do
    Signal.__index = Signal

    function Signal.new()
        return setmetatable({ _Event = Instance.new('BindableEvent') }, Signal)
    end

    function Signal:Connect(fn)
        assert(typeof(fn) == 'function', 'function expected')
        return self._Event.Event:Connect(fn)
    end

    function Signal:Fire(...)   self._Event:Fire(...) end
    function Signal:Wait()      return self._Event.Event:Wait() end

    function Signal:Disconnect()
        if self._Event then self._Event:Destroy() end
    end
end

-- ===== State =====
AutoRejoin.Connected       = Signal.new()
AutoRejoin.Disconnected    = Signal.new()
AutoRejoin.MessageReceived = Signal.new()
AutoRejoin.Connections     = {}
AutoRejoin.Commands        = {}

AutoRejoin.IsConnected    = false
AutoRejoin.Terminated     = false
AutoRejoin.LastPong       = 0
AutoRejoin.PingCount      = 0
AutoRejoin.PongCount      = 0
AutoRejoin.PingTask       = nil
AutoRejoin.WatchdogTask   = nil

-- ===== Send =====
function AutoRejoin:Send(Command, Payload)
    assert(self.Socket, 'websocket is nil')
    assert(self.IsConnected, 'websocket not connected')
    assert(typeof(Command) == 'string', 'Command must be a string')

    if Payload then
        assert(typeof(Payload) == 'table', 'Payload must be a table')
    end

    local Message = HttpService:JSONEncode({
        Name = Command,
        Payload = Payload,
    })

    return self.Socket:Send(Message)
end

-- ===== Ping loop =====
function AutoRejoin:_startPingLoop()
    if self.PingTask then return end

    self.PingTask = task.spawn(function()
        while self.IsConnected and not self.Terminated do
            local Ok, Err = pcall(function()
                self:Send('ping')
            end)

            if not Ok then
                warn('[AutoRejoin] ping failed:', Err)
                self.IsConnected = false
                break
            end

            self.PingCount += 1

            -- ถ้าถึงทุก ๆ 30 ครั้ง ให้ log สถิติ
            if self.PingCount % 30 == 0 then
                print(('[AutoRejoin] Ping #%d | Pong #%d | last pong %.1fs ago')
                    :format(self.PingCount, self.PongCount, os.clock() - self.LastPong))
            end

            task.wait(PING_INTERVAL)
        end

        self.PingTask = nil
    end)
end

-- ===== Watchdog: ตรวจว่า server ตอบกลับบ้างไหม =====
function AutoRejoin:_startWatchdog()
    if self.WatchdogTask then return end

    self.LastPong = os.clock()

    self.WatchdogTask = task.spawn(function()
        while self.IsConnected and not self.Terminated do
            task.wait(1)

            local Elapsed = os.clock() - self.LastPong
            if Elapsed > PING_TIMEOUT then
                warn(('[AutoRejoin] No response for %.1fs, reconnecting...'):format(Elapsed))
                self.IsConnected = false
                break
            end
        end
        self.WatchdogTask = nil
    end)
end

-- ===== Connect =====
function AutoRejoin:Connect(Host, Bypass)
    if not Bypass and self.IsConnected then
        return 'Already connected'
    end

    Host = Host or AUTOREJOIN_HOST

    while not self.Terminated do
        -- cleanup เก่า
        for _, c in pairs(self.Connections) do c:Disconnect() end
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

        local Ok, Socket = pcall(WSConnect, Url)
        if not Ok then
            warn('[AutoRejoin] Connect failed:', Socket, '| retry in', RECONNECT_DELAY, 's')
            task.wait(RECONNECT_DELAY)
            continue
        end

        self.Socket = Socket
        self.IsConnected = true
        self.PingCount = 0
        self.PongCount = 0
        self.LastPong = os.clock()

        -- ข้อความที่เข้ามา
        table.insert(self.Connections, Socket.OnMessage:Connect(function(Message)
            self.LastPong = os.clock()
            self.PongCount += 1

            -- ตอบกลับ pong ถ้า server ส่ง pong มา
            if Message == 'pong' then
                return
            end

            self.MessageReceived:Fire(Message)
        end))

        table.insert(self.Connections, Socket.OnClose:Connect(function()
            print('[AutoRejoin] Socket closed')
            self.IsConnected = false
            self.Disconnected:Fire()
        end))

        self.Connected:Fire()
        print('[AutoRejoin] ✅ Connected')

        -- เริ่ม ping loop + watchdog
        self:_startPingLoop()
        self:_startWatchdog()

        -- รอจนกว่าจะขาดการเชื่อมต่อ
        while self.IsConnected and not self.Terminated do
            task.wait(0.5)
        end

        -- cleanup ก่อนวนรอบใหม่
        if self.PingTask then task.cancel(self.PingTask); self.PingTask = nil end
        if self.WatchdogTask then task.cancel(self.WatchdogTask); self.WatchdogTask = nil end

        if self.Terminated then break end

        print(('[AutoRejoin] Reconnecting in %ds...'):format(RECONNECT_DELAY))
        task.wait(RECONNECT_DELAY)
    end
end

-- ===== Stop =====
function AutoRejoin:Stop()
    self.Terminated = true
    self.IsConnected = false
    self.Disconnected:Fire()

    if self.PingTask then task.cancel(self.PingTask); self.PingTask = nil end
    if self.WatchdogTask then task.cancel(self.WatchdogTask); self.WatchdogTask = nil end

    if self.Socket then
        pcall(function() self.Socket:Close() end)
    end
end

-- ===== Commands =====
function AutoRejoin:AddCommand(Name, fn)    self.Commands[Name] = fn end
function AutoRejoin:RemoveCommand(Name)    self.Commands[Name] = nil end
function AutoRejoin:OnButtonClick(Name, fn) self:AddCommand('ButtonClicked:' .. Name, fn) end

function AutoRejoin:Echo(Content)   self:Send('Echo',   { Content = Content }) end
function AutoRejoin:Log(...)
    local T = {}
    for _, v in pairs{ ... } do table.insert(T, tostring(v)) end
    self:Send('Log', { Content = table.concat(T, ' ') })
end

-- ===== Command dispatcher =====
AutoRejoin.MessageReceived:Connect(function(Message)
    local S = Message:find(' ')

    if S then
        local Command, Rest = Message:sub(1, S - 1):lower(), Message:sub(S + 1)

        if AutoRejoin.Commands[Command] then
            local Ok, Err = pcall(AutoRejoin.Commands[Command], Rest)
            if not Ok then AutoRejoin:Log(('Error `%s`: %s'):format(Command, Err)) end
        end
    elseif AutoRejoin.Commands[Message] then
        local Ok, Err = pcall(AutoRejoin.Commands[Message], Message)
        if not Ok then AutoRejoin:Log(('Error `%s`: %s'):format(Message, Err)) end
    end
end)

-- ===== Default commands =====
do
    AutoRejoin:AddCommand('execute', function(Message)
        local Function, Error = loadstring(Message)
        if not Function then
            AutoRejoin:Log(Error)
            return
        end

        local Env = getfenv(Function)
        Env.Player = LocalPlayer
        Env.print = function(...)
            local T = {}
            for _, v in pairs{ ... } do table.insert(T, tostring(v)) end
            AutoRejoin:Log(table.concat(T, ' '))
        end
        if newcclosure then Env.print = newcclosure(Env.print) end

        local Ok, Err = pcall(Function)
        if not Ok then AutoRejoin:Log(Err) end
    end)

    AutoRejoin:AddCommand('rejoin', function()
        game:GetService('TeleportService'):TeleportToPlaceInstance(game.PlaceId, game.JobId)
    end)

    AutoRejoin:AddCommand('ping', function()
        AutoRejoin:Send('pong')
    end)
end

-- ===== Export =====
local GEnv = getgenv()
GEnv.AutoRejoin = AutoRejoin

if not AutoRejoin_Version then
    AutoRejoin:Connect()
end
