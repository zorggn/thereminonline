--- shared stuff
-- enet is cool
local enet = require("enet")

-- sounds
local voices = {}

-- snatched from https://github.com/phyber/Snippets/blob/master/Lua/base36.lua
local alphabet = {
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
  "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
  "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"
}

local function base36(num)
  -- Special case for numbers less than 36
  if num < 36 then
    return alphabet[num + 1]
  end

  -- Process large numbers now
  local result = ""
  while num ~= 0 do
    local i = num % 36
    result = alphabet[i + 1] .. result
    num = math.floor(num / 36)
  end
  return result
end

-- i think it works right
local function ip2long(ip)
  local ip = tostring(ip)
  local p1, p2, p3, p4 = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)")

  local n = p1 * 256 ^ 3 + p2 * 256 ^ 2, p3 * 256 ^ 1, p4 * 256 ^ 0

  return n
end

-- friendly names (so friendly)!
local function friendly_name(ip)
  return base36(ip2long(ip))
end

-- logging
local function log(str, ...)
  print("[" .. os.date("%Y-%m-%d %H:%M:%S") .. "] " .. str:format(...))
end

-- obvious
local function has_value(t, value)
  for _, v in pairs(t) do
    if value == v then
      return true
    end
  end

  return false
end

local function has_arg(v)
  return has_value(arg, v)
end

local headless = has_arg("--headless")
local hosting = os.getenv("USERNAME") == "unekp"--has_arg("--hosting")

-- commands
local ffi = require("ffi")
local commander = require("commander")

-- color struct
local color_struct = "typedef struct { uint8_t r, g, b; } color;"
ffi.cdef(color_struct)

commander.newCommand("notification", {
  time   = "uint8_t",
  color  = {
    type = "color",
    func = function(cdata)
      return {cdata.r, cdata.g, cdata.b}
    end
  },
  text   = {
    type = "unsigned char",
    size = 180,
    func = ffi.string
  }
})
commander.newCommand("set_generator", {
  uid    = "uint8_t",
  generator = {
    type = "unsigned char",
    size = 8,
    func = ffi.string
  }
})
commander.newCommand("play", {
  uid = "uint8_t"
})
commander.newCommand("stop", {
  uid = "uint8_t"
})
commander.newCommand("move_mouse", {
  uid = "uint8_t",
  x   = "int16_t",
  y   = "int16_t"
})
commander.newCommand("user_list", {
  count = "uint8_t",
  uids = {
    type = "uint8_t",
    size = 32,
    func = function(cdata, packet)
      local t = {}
      for i = 0, packet.count - 1 do
        table.insert(t, cdata[i])
      end

      return t
    end
  }
})

local client_commands = {}
local server_commands = {}

-- dispatches the commands
local function receive_packet(packet, peer, serverside)
  local status, command, data = pcall(commander.parse, packet)
  if not status then
    log("Received invalid packet from %s.", tostring(peer))
    return
  end

  local commands = serverside and server_commands or client_commands

  pcall(commands[command], data, peer)
end

-- sound generators
local denver = require("denver")
local my_generator = 1
local generators = {"sinus", "sawtooth", "square", "triangle"}
local generator_colors = {
  sinus = {255, 0, 0},
  sawtooth = {0, 255, 0},
  square = {0, 0, 255},
  triangle = {255, 0, 255}
}

--- this is for the client
-- enet
local server, client_host

-- user list
local players = {}
local cursors = {}

-- rules
local rules = {}

-- my fancy notification system
local notification_queue = {}

local function push_notification(text, time, color)
  table.insert(notification_queue, {
    text = text,
    spawn_time = love.timer.getTime(),
    time = time or 5,
    color = color or {0, 0, 0}
  })

  if love._version_minor >= 10 then
    love.window.requestAttention()
  end
end

-- snapper tool
local snapper_radius = 40

-- more stuff for the client
local fonts, small_font, font, big_font, game_info
if not headless then
  -- basic fonts for gui and stuff
  big_font = love.graphics.newFont("noto.ttf", 28)
  font = love.graphics.newFont("noto.ttf", 12)
  small_font = love.graphics.newFont("noto.ttf", 11)

  font:setLineHeight(1.3)

  -- font metatable
  -- it's a pretty cool snippet
  fonts = {}
  setmetatable(fonts, {
    __index = function(t, k)
      local font = rawget(t, k)
      if not font then
        font = love.graphics.newFont("noto.ttf", k)
        rawset(t, k, font)
      end

      return font
    end
  })
end

--- this is for the server
-- enet host
local server_host

-- keep the list of peers connected
local user_counter = 0
local peers = {}
local uids  = {}
local peer_generators = {}

-- list of server rules, sent to all clients
local server_rules = {}

-- notification system
local function broadcast_notification(text, time, color)
  server_host:broadcast(commander.serialize("notification", {
    text = text,
    time = time or 3,
    color = color or {80, 80, 80}
  }))
end

-- game info
local game_name = "MUSICFUCK"
local function game_info()
  local info = "it's multiplayer theremin"

  return info
end

--- commands
-- server commands
server_commands.set_generator = function(data, peer)
  local generator = has_value(generators, data.generator) and data.generator or "sinus"

  server_host:broadcast(commander.serialize("set_generator", {
    uid = uids[peer],
    generator = generator
  }))

  peer_generators[peer] = generator
end
server_commands.play = function(data, peer)
  server_host:broadcast(commander.serialize("play", {
    uid = uids[peer]
  }))
end
server_commands.stop = function(data, peer)
  server_host:broadcast(commander.serialize("stop", {
    uid = uids[peer]
  }))
end
server_commands.move_mouse = function(data, peer)
  server_host:broadcast(commander.serialize("move_mouse", {
    uid = uids[peer],
    x = data.x,
    y = data.y
  }))
end

-- client commands
client_commands.move_mouse = function(data, peer)
  if not cursors[data.uid] then return end

  cursors[data.uid].x, cursors[data.uid].y = data.x, data.y
end
client_commands.user_list = function(data)
  players = data.uids

  local new_cursors = {}
  for _, uid in ipairs(data.uids) do
    new_cursors[uid] = {
      x = cursors[uid] and cursors[uid].x or 0,
      y = cursors[uid] and cursors[uid].y or 0,
      generator = cursors[uid] and cursors[uid].generator or generators[1]
    }
  end

  cursors = new_cursors
end
client_commands.play = function(data)
  if not voices[data.uid] then return end

  voices[data.uid]:play()
end
client_commands.stop = function(data)
  if not voices[data.uid] then return end

  voices[data.uid]:stop()
end
client_commands.set_generator = function(data)
  if voices[data.uid] then
    voices[data.uid]:stop()
  end

  local voice = denver.get({
    waveform = data.generator,
    frequency = 440,
    length = 1
  })
  voice:setLooping(true)

  voices[data.uid] = voice
  cursors[data.uid].generator = data.generator
end
client_commands.notification = function(data)
  log("Received notification: %s", data.text)
  
  push_notification(data.text, data.time, data.color)
end

function love.load()
  -- sublime text console support
  io.stdout:setvbuf("no")

  -- try to set up a server
  if hosting then
    server_host = enet.host_create("0.0.0.0:9393", 32, 1)

    if not server_host then
      log("Could not set up the server.")
      hosting = false
    end

    rules = server_rules
  end

  -- connect
  if not headless then
    client_host = enet.host_create()
    server = client_host:connect(hosting and "localhost:9393" or "88.156.250.206:9393")

    love.graphics.setBackgroundColor(0, 0, 0)
    love.mouse.setVisible(false)
  end
end

local circle_halos = {}
local last_circle_halo = love.timer.getTime()
function love.draw()
  local w, h = love.graphics.getDimensions()

  -- the middle fucking thing
  local r = math.min(w, h) * 0.1
  local start_r = r

  local pitch_sum, pitch_count = 1, 1
  for uid, voice in pairs(voices) do
    pitch_sum, pitch_count = pitch_sum + voice:getPitch(), pitch_count + 1
  end

  if pitch_count > 0 then
    r = r + (pitch_sum / pitch_count) * r / 5
  end

  love.graphics.setLineStyle("smooth")
  love.graphics.setColor(0, 255, 0)
  love.graphics.circle("line", w / 2, h / 2, r)

  local time = love.timer.getTime()

  for i, halo in ipairs(circle_halos) do
    local dt = time - halo.time
    local a  = dt / (8 * 0.03)

    love.graphics.setColor(0, 255, 0, 180 - a * 180)
    love.graphics.circle("line", w / 2, h / 2, halo.r)
  end


  if time > last_circle_halo + 0.03 then
    table.insert(circle_halos, {
      time = time,
      r = r
    })

    if #circle_halos >= 8 then
      table.remove(circle_halos, 1)
    end

    last_circle_halo = time
  end

  local text = tostring(#players)
  local circle_font = fonts[math.floor(r * 1)]
  love.graphics.setFont(circle_font)
  love.graphics.setColor(0, 255, 0)
  love.graphics.print(text, (w - circle_font:getWidth(text)) / 2, (h - circle_font:getHeight()) / 2)

  -- snapper tool
  if love.keyboard.isDown("lshift", "rshift") then
    for i = 1, 30 do
      local r = i * snapper_radius
      if r > start_r then
        love.graphics.setColor(0, 255, 255, 130 - (i / 30) * 130)
        love.graphics.circle("line", w / 2, h / 2, r)
      end
    end
  end

  -- cursors
  love.graphics.setLineStyle("rough")
  for uid, cursor in pairs(cursors) do
    local rw, rh = 8, 8
    love.graphics.setColor(generator_colors[cursor.generator])
    love.graphics.rectangle((voices[uid] and voices[uid]:isPlaying()) and "fill" or "line", w / 2 - cursor.x - rw / 2, h / 2 - cursor.y - rh / 2, rw, rh)
  end

  -- notifications
  local t = love.timer.getTime()

  local th = font:getHeight() * font:getLineHeight()
  local spacing = 10
  love.graphics.setFont(font)
  for i, notification in ipairs(notification_queue) do
    local tw = font:getWidth(notification.text)
    local tx, ty = w - 10 - tw, 5 + (i - 1) * (th + spacing)
    local a = 1 - ((t - notification.spawn_time) / notification.time)

    local r, g, b = unpack(notification.color)
    love.graphics.setColor(r, g, b, 120)
    love.graphics.rectangle("fill", tx - 8, ty - 2, tw + 16, th + 2)

    love.graphics.setColor(255, 255, 255)
    love.graphics.print(notification.text, tx, ty)

    love.graphics.rectangle("fill", tx + tw, ty + th - 3, -tw * a, 1)
  end

  -- draw something if unconnected
  local state = server:state()
  if state ~= "connected" then
    state = state:upper()
    love.graphics.setColor(0, 0, 0, 160)
    love.graphics.rectangle("fill", 0, 0, w, h)

    love.graphics.setFont(big_font)
    love.graphics.setColor(255, 255, 255, 180 + math.sin(love.timer.getTime() * 3) * 75)
    love.graphics.print(state, (w - big_font:getWidth(state)) / 2, (h - big_font:getHeight()) / 2)
  end

  if love.keyboard.isDown("tab") then
    love.graphics.setColor(80, 80, 80, 130)
    love.graphics.rectangle("fill", 0, 0, 260, h)

    love.graphics.setFont(big_font)
    love.graphics.setColor(0, 0, 0)
    love.graphics.print(game_name, (260 - big_font:getWidth(game_name)) / 2 + 1, 5 + 1)
    love.graphics.setColor(255, 255, 255)
    love.graphics.print(game_name, (260 - big_font:getWidth(game_name)) / 2, 5)

    love.graphics.setColor(0, 0, 0)
    love.graphics.rectangle("fill", 5 + 1, big_font:getHeight() + 5 + 1, 260 - 10, 1)
    love.graphics.setColor(255, 255, 255)
    love.graphics.rectangle("fill", 5, big_font:getHeight() + 5, 260 - 10, 1)

    love.graphics.setFont(small_font)

    local text = game_info()
    love.graphics.setColor(0, 0, 0)
    love.graphics.printf(text, 5 + 1, 5 + big_font:getHeight() + 5 + 1, 260 - 10)

    love.graphics.setColor(255, 255, 255)
    love.graphics.printf(text, 5, 5 + big_font:getHeight() + 5, 260 - 10)
  end
end

function love.update(dt)
  -- notifications
  if not headless then
    local t = love.timer.getTime()
    for i = #notification_queue, 1, -1 do
      local notification = notification_queue[i]

      if notification.spawn_time + notification.time < t then
        table.remove(notification_queue, i)
      end
    end
  end

  -- set voice's pitches based on distance
  local min, max = 0.5, 6
  local w, h = love.graphics.getDimensions()
  for uid, cursor in pairs(cursors) do
    local dist = ((-cursor.x) ^ 2 + (-cursor.y) ^ 2) ^ .5
    local pitch = 1 / math.max(1 / max, math.min(dist / 300, 1 / min))
    if voices[uid] and voices[uid]:isPlaying() then
      voices[uid]:setPitch(pitch)
    else
      voices[uid]:setPitch(1)
    end
  end

  -- server update
  if hosting then
    while true do
      local event = server_host:service()
      if not event then break end

      if event.type == "receive" then
        receive_packet(event.data, event.peer, true)
      elseif event.type == "connect" then
        log("%s (%s) joined the paint.", tostring(event.peer), friendly_name(event.peer))
        broadcast_notification(string.format("%s joined.", friendly_name(event.peer)))

        -- into the peer table
        user_counter = user_counter + 1
        peers[user_counter] = event.peer
        uids[event.peer] = user_counter

        -- broadcast the user list
        local list = {}
        for uid, peer in pairs(peers) do
          table.insert(list, uid)
        end

        server_host:broadcast(commander.serialize("user_list", {
          count = #list,
          uids = list
        }))
      elseif event.type == "disconnect" then
        log("%s (%s) left the paint.", tostring(event.peer), friendly_name(event.peer))
        broadcast_notification(string.format("%s lefted.", friendly_name(event.peer)))

        -- stop his plays
        server_host:broadcast(commander.serialize("stop"), {
          uid = uids[event.peer]
        })

        -- remove from the peer table
        peers[uids[event.peer]] = nil

        server_host:broadcast(commander.serialize("user_list", {
          count = #list,
          uids = list
        }))
      end
    end
  end

  -- client update
  if not headless then
    while true do
      local event = client_host:service()
      if not event then break end

      if event.type == "receive" then
        receive_packet(event.data, event.peer)
      elseif event.type == "connect" then
        push_notification("hold tab for help.", 8, {255, 0, 0})
        server:send(commander.serialize("set_generator", {
          generator = generators[my_generator]
        }))
      end
    end
  end
end

function love.keypressed(key, is_repeat, scancode)
  if love._version_minor >= 10 then
    is_repeat = scancode
  end

end

local left_click = love._version_minor >= 10 and 1 or "l"
function love.mousepressed(x, y, btn)
  if btn == "wu" or btn == "wd" then
    love.wheelmoved(0, btn == "wu" and 1 or -1)
  end

  if btn == left_click then
    server:send(commander.serialize("play"))
  end
end
function love.mousereleased(x, y, btn)
  if btn == left_click then
    server:send(commander.serialize("stop"))
  end
end

function love.mousemoved(x, y, dx, dy)
  local w, h = love.graphics.getDimensions()
  local x, y = w / 2 - x, h / 2 - y

  if love.keyboard.isDown("lshift", "rshift") then
    local dist = ((-x) ^ 2 + (-y) ^ 2) ^ .5
    dist = math.floor(dist / snapper_radius + .5) * snapper_radius

    local angle = math.atan2(y, x)
    x = math.cos(angle) * dist
    y = math.sin(angle) * dist
  end

  server:send(commander.serialize("move_mouse", {
    x = x,
    y = y
  }))
end

function love.wheelmoved(x, y)
  if love.keyboard.isDown("lshift", "rshift") then
    snapper_radius = math.max(20, math.min(200, snapper_radius + y * 3))
  else
    -- i could do this with modulo but i'm too stupid
    my_generator = my_generator + y
    if my_generator > #generators then
      my_generator = 1
    elseif my_generator < 1 then
      my_generator = #generators
    end

    push_notification("generator set to " .. generators[my_generator] .. ".", 1, {0, 0, 80})


    server:send(commander.serialize("set_generator", {
      generator = generators[my_generator]
    }))
  end
end
