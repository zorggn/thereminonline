local commander = {}

local ffi = require("ffi")

local counter = 1
local commands = {}
local pointers = {}
local types = {}

-- create packet_type struct
do
  local struct = "typedef struct { uint8_t type; } packet_type;"
  ffi.cdef(struct)

  pointers.packet_type = ffi.typeof("packet_type*")
end

function commander.newCommand(command, fields)
  local cfields = {}
  for key, field_data in pairs(fields) do
    if type(field_data) == "string" then
      table.insert(cfields, string.format("%s %s;", field_data, key))
    else
      table.insert(cfields, string.format("%s %s%s;", field_data.type, key, field_data.size and ("[" .. field_data.size .. "]") or ""))
    end
  end

  local struct = string.format("typedef struct {uint8_t type; %s} %s;", table.concat(cfields, " "), command)
  ffi.cdef(struct)

  pointers[command] = ffi.typeof(command .. "*")

  commands[command] = {
    command = command,
    type    = counter,
    fields  = fields,
    struct  = ffi.typeof(command),
    pointer = ffi.typeof(command .. "*")
  }
  types[counter] = commands[command]

  counter = counter + 1
end

function commander.parse(data)
  -- decode as packet_type, check what the type actually is
  local header = ffi.cast(pointers.packet_type, data)[0]
  assert(header, "tried to parse a packet with no header")
  assert(header.type, "tried to parse a packet with no type")

  local command = types[header.type]
  assert(command, "received invalid command type")

  local cdata = ffi.cast(command.pointer, data)[0]

  local data = {}
  for key, field_data in pairs(command.fields) do
    if type(field_data) == "table" and field_data.func then
      if field_data.func ~= ffi.string then
        data[key] = field_data.func(cdata[key], cdata)
      else
        data[key] = field_data.func(cdata[key])
      end
    else
      data[key] = cdata[key]
    end
  end

  return command.command, data
end

function commander.serialize(command, t)
  local command = commands[command]
  assert(command, "invalid command")

  t = t or {}
  assert(type(t) == "table", "argument #2 needs to be a table")

  t.type = command.type

  local object = ffi.new(command.struct, t)

  return ffi.string(ffi.cast("const char*", object), ffi.sizeof(object))
end

return commander
