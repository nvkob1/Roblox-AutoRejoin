AutoRejoin_Version = 105

local FileName = 'autorejoin.lua'
local URL = 'https://raw.githubusercontent.com/nvkob1/Roblox-AutoRejoin/refs/heads/main/autorejoin.lua'

local Function, Error

-- === ลองโหลดจากไฟล์ cache ก่อน เพื่อเริ่มทำงานเร็ว ===
if isfile and readfile and isfile(FileName) then
    Function, Error = loadstring(readfile(FileName), 'AutoRejoin')

    if Function then
        local Ok, Err = pcall(Function)
        if not Ok then
            warn('[AutoRejoin] Cache execute failed:', Err)
        elseif AutoRejoin then
            AutoRejoin:Connect()
        end
    end
end

-- === ดึงเวอร์ชันล่าสุดจาก GitHub ===
local Success
for i = 1, 10 do
    Success, Error = pcall(function()
        local Response = (http_request or (syn and syn.request)) {
            Method = 'GET',
            Url = URL,
        }

        if not Response.Success then
            error(('HTTP Error %s'):format(Response.StatusCode))
        end

        Function, Error = loadstring(Response.Body, 'AutoRejoin')
        if not Function then error(Error) end

        if isfile and not isfile(FileName) then
            writefile(FileName, Response.Body)
        end

        if not AutoRejoin then
            Function()
            AutoRejoin:Connect()
        end
    end)

    if Success then break else task.wait(1) end
end

if not Success and Error then
    (messagebox or print)(('AutoRejoin encountered an error while launching!\n\n%s'):format(Error))
end
