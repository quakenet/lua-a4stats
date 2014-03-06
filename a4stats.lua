-- Copyright (C) 2013-2014 Gunnar Beutner
--
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

-- TODO:
-- frontend
-- clean up topics/kicks periodically

local BOTNICK = "a4stats"
local BOTACCOUNT = "a4stats"
local BOTACCOUNTID = 0

local a4_bot
local a4_channels = {}
local a4_channelstate = {}

function onload()
  onconnect()
end

function onconnect()
  a4_bot = irc_localregisteruserid(BOTNICK, "a4stats", "channel.statistics", "Channel statistics service", BOTACCOUNT, BOTACCOUNTID, "+ikXr", statshandler)
  a4_sync_channels()
end

function irctolowerasciic(code)
  if code >= 65 and code <= 94 then
    code = code + 32
  end
  return code
end

function irctolowerascii(string)
  local codes = {}
  for i = 1, #string do
    table.insert(codes, irctolowerasciic(string.byte(string, i)))
  end
  return string.char(unpack(codes))
end

function a4_maskhost(host)
  local nickname, username, hostname
  local fullmask = {}

  local _, posnick = string.find(host, "!", 1, true)
  if posnick then
    nickname = string.sub(host, 1, posnick - 1)
  end

  -- determine username
  local _, posuser = string.find(host, "@", 1, true)
  if posuser then
    username = string.sub(host, posnick + 1, posuser - 1)
  end

  username = string.gsub(username, "~", "*")

  -- determine host from that user + 1 = host
  hostname = string.sub(host, posuser + 1)

  table.insert(fullmask, "*!")
  table.insert(fullmask, username)
  table.insert(fullmask, "@")
  
  -- determine if the host has 2 or more dots in it (long hostname or ip)
  local _, count = string.gsub(hostname, "%.", "")

  if count >= 2 then
    local ip = string.match(hostname, "%d+.%d+.%d+.")
    if ip then
      hostname = ip .. "*"
    else
      local _, first = string.find(hostname, "%.")
      hostname = "*" .. string.sub(hostname, first)
    end
  end
  
  table.insert(fullmask, hostname)

  
  return table.concat(fullmask)
end

function onnterfacer(command, ...)
  if command == "enable_channel" then
    local channel = ...

    if a4_is_stats_channel(channel) then
      return 30, "Already on that channel"
    end

    a4_int_enable_channel(channel)

    return 0, "OK"
  elseif command == "disable_channel" then
    local channel = ...

    if not a4_is_stats_channel(channel) then
      return 30, "Not on that channel"
    end

    a4_int_disable_channel(channel)

    return 0, "OK"
  elseif command == "getcomchans" then
    local account = ...
    local numerics = { irc_getuserbyauth(account) }

    local channels = {}

    for channel, _ in pairs(a4_channels) do
      local found = false

      for _, numeric in pairs(numerics) do
        if numeric and irc_nickonchan(numeric, channel) then
          found = true   
          break
        end
      end

      if found then
        table.insert(channels, channel)
      end
    end
 
    return 0, channels
  elseif command == "chanmsg" then
    local channel, message = ...

    if not a4_is_stats_channel(channel) then
      return 31, "Invalid channel"
    end

    irc_localchanmsg(a4_bot, channel, message)

    return 0, "OK"
  end
end

function a4_is_stats_channel(channel)
  return irc_nickonchan(a4_bot, channel)
end

function a4_getchannelid(channel)
  return a4_channels[irctolowerascii(channel)]
end

function a4_sync_channels()
  a4_fetch_channels("a4_fetch_channel_cb", {})
end

function a4_fetch_channel_cb(id, name, active, uarg)
  if not a4_channelstate[name] then
    a4_channelstate[name] = { skitzocounter = 0 }
  end

  if active == 1 then
    a4_join_channel(id, name)
  elseif a4_is_stats_channel(name) then
    a4_part_channel(name)
  end
end

function a4_join_channel(id, channel)
  irc_localjoin(a4_bot, channel)
  a4_channels[irctolowerascii(channel)] = id
end

function a4_int_enable_channel(channel)
  a4_enable_channel(channel)
  a4_fetch_channels("a4_fetch_channel_cb", {})
end

function a4_part_channel(channel)
  irc_localpart(a4_bot, channel)
  a4_channels[irctolowerascii(channel)] = nil
end

function a4_int_disable_channel(channel, part)
  a4_disable_channel(channel)
  a4_fetch_channels("a4_fetch_channel_cb", {})
end

function a4_notice(numeric, text)
  irc_localnotice(a4_bot, numeric, text)
end

function statshandler(target, revent, ...)
  if revent == "irc_onchanmsg" then
    local numeric, channel, message = ...

    channel = irctolowerascii(channel)

    if not a4_is_stats_channel(channel) then
      return
    end

    a4_log_msg(channel, numeric, message)
  end
end

function a4_rb_new(count)
  local result = { offset = 1, data = {} }

  for k=1,count do
    result.data[k] = { 0, 0 }
  end

  return result
end

function a4_rb_add(rb, numeric)
  local offset = rb.offset
  rb.offset = rb.offset + 1
  if rb.offset > table.getn(rb.data) then
    rb.offset = 1
  end
  rb.data[offset] = { numeric, os.time() }
end

function a4_rb_list(rb, newer_than)
  local result = {}
  for _, v in pairs(rb.data) do
    if v[2] > newer_than then
      result[table.concat(v[1], '\0')] = v[1]
    end
  end
  return result
end

function a4_log_msg(channel, numeric, message)
  if not a4_is_stats_channel(channel) then
    return
  end

  a4_fetch_user(a4_getchannelid(channel), a4_getaccount(numeric), a4_getaccountid(numeric), "a4_log_msg_async", { channel, numeric, message})
end

function a4_log_msg_async(seen, quotereset, uarg)
  local channel = uarg[1]
  local numeric = uarg[2]
  local message = uarg[3]

  local smileyhappy = {":)", ":-)", ":p", ":-p", ":P", ":-P", ":D", ":-D", ":}", ":-}", ":]", ":-]", ";)", ";-)", ";p", ";-p", ";P", ";-P", ";D", ";-D", ";}", ";-}", ";]", ";-]"}
  local smileysad = {":(", ":-(", ":c", ":-c", ":C", ":-C", ":[", ":-[", ":{", ":-{", ";(", ";-(", ";c", ";-c", ";C", ";-C", ";[", ";-[", ";{", ";-{"}
  local foulmessage = {"fuck", "fick", "bitch", "shit", "cock", "dick", "stfu"}

  updates = {}
  a4_touchuser(updates, numeric)

  local hour = math.floor(os.time() / 3600) % 24

  if os.time() - seen > 600 then
    rating_delta = 120
  else
    rating_delta = os.time() - seen
  end

  table.insert(updates, "rating = rating + " .. rating_delta)

  -- relations
  if not a4_channelstate[channel]["lastmsgs"] then
    a4_channelstate[channel]["lastmsgs"] = a4_rb_new(10)
  end

  a4_rb_add(a4_channelstate[channel]["lastmsgs"], { a4_getaccount(numeric), a4_getaccountid(numeric) })

  for _, k in pairs(a4_rb_list(a4_channelstate[channel]["lastmsgs"], os.time() - 120)) do
    if a4_getaccount(numeric) ~= k[1] or a4_getaccountid(numeric) ~= k[2] then
      a4_update_relation(a4_getchannelid(channel), a4_getaccount(numeric), a4_getaccountid(numeric), k[1], k[2])
    end
  end

  -- do skitzo checking
  if a4_channelstate[channel]["skitzonumeric"] == numeric then
    a4_channelstate[channel]["skitzocounter"] = a4_channelstate[channel]["skitzocounter"] + 1

    if a4_channelstate[channel]["skitzocounter"] > 4 then
      table.insert(updates, "skitzo = skitzo + 1")
      a4_channelstate[channel]["skitzocounter"] = 0
    end
  else
    a4_channelstate[channel]["skitzonumeric"] = numeric
    a4_channelstate[channel]["skitzocounter"] = 0
  end

  local action = false
  local ctcp_command, ctcp_param = string.match(message, "\1(%a+) ([^\1]+)\1")
  if ctcp_command then
    if ctcp_command == "ACTION" then
      action = true
      message = ctcp_param
      table.insert(updates, "actions = actions + 1")
      table.insert(updates, "last = '" .. a4_escape_string("ACTION " .. message) .. "'")

      local slaps = false
      local targetnumeric
      for nick in string.gmatch(message,'%S+') do
        targetnumeric = irc_fastgetnickbynick(nick, { nickpusher.numeric })

        if targetnumeric then

          if irc_nickonchan(targetnumeric, channel) then
            if not slaps then
              slaps = true
              table.insert(updates, "slaps = slaps + 1")
            end

            local slapped = {}
            table.insert(slapped, "slapped = slapped + 1")
            table.insert(slapped, "highlights = highlights + 1")

            a4_update_user(a4_getchannelid(channel), a4_getaccount(targetnumeric), a4_getaccountid(targetnumeric), slapped)   
          end
        end

        a4_add_line(channel, hour)
        a4_update_user(a4_getchannelid(channel), a4_getaccount(numeric), a4_getaccountid(numeric), updates)

        return
      end
    else
      return
    end
  end

  local targetnumeric
  for nick in string.gmatch(message,'%S+') do
    targetnumeric = irc_fastgetnickbynick(nick, { nickpusher.numeric })

    if targetnumeric then

      if irc_nickonchan(targetnumeric, channel) then    
        local highlight = { "highlights = highlights + 1" }

        a4_update_user(a4_getchannelid(channel), a4_getaccount(targetnumeric), a4_getaccountid(targetnumeric), highlight)          
      end
    end
  end

  if quotereset == 0 or (os.time() - quotereset > 7200 and math.random(100) > 70 and string.len(message) > 20 and string.len(message) < 200) then
    if action then
      quote = "* " .. irc_fastgetnickbynumeric(numeric, { nickpusher.nick }) .. " " .. message
    else
      quote = message
    end

    table.insert(updates, "quote = '" .. a4_escape_string(quote) .. "'")
    table.insert(updates, "quotereset = " .. os.time())
  end

  for _, s in pairs(smileyhappy) do
    if string.find(message, s, 1, true) then
      table.insert(updates, "mood_happy = mood_happy + 1")
      break
    end
  end

  for _, s in pairs(smileysad) do
    if string.find(message, s, 1, true) then
      table.insert(updates, "mood_sad = mood_sad + 1")
      break
    end
  end

  for _, s in pairs(foulmessage) do
    if string.find(message, s, 1, true) then
      table.insert(updates, "foul = foul + 1")
      break
    end
  end

  if string.sub(message, string.len(message)) == "?" then
    table.insert(updates, "questions = questions + 1")
  end

  if string.sub(message, string.len(message)) == "!" then
    table.insert(updates, "yelling = yelling + 1")
  end

  local hour = math.floor(os.time() / 3600) % 24
  table.insert(updates, "h" .. hour .. " = h" .. hour .. " + 1")

  table.insert(updates, "lines = lines + 1")

  table.insert(updates, "chars = chars + " .. string.len(message))

  local _, count = string.gsub(message, " ", "")
  table.insert(updates, "words = words + " .. count + 1)

  local _, count = string.gsub(message, "[A-Z!?]", "")
  table.insert(updates, "caps = caps + " .. count)

  table.insert(updates, "last = '" .. a4_escape_string("TEXT " .. message) .. "'")

  a4_add_line(channel, hour)
  a4_update_user(a4_getchannelid(channel), a4_getaccount(numeric), a4_getaccountid(numeric), updates)
end

function a4_getaccountid(numeric)
  local nickid = irc_fastgetnickbynumeric(numeric, { nickpusher.accountid })

  if nickid then
    return nickid
  else
    return 0
  end
end

function a4_getaccount(numeric)
  local nick = irc_getnickbynumeric(numeric)

  if nick.accountid then
    id = nick.account
  else
    local fullhost = a4_maskhost(irc_getvisiblehostmask(numeric))
    id = fullhost
  end

  return id
end

function a4_touchuser(updates, numeric)
  local nick = irc_fastgetnickbynumeric(numeric, { nickpusher.nick })

  table.insert(updates, "accountid = '" .. a4_getaccountid(numeric) .. "'")
  table.insert(updates, "curnick = '" .. a4_escape_string(nick) .. "'")
  table.insert(updates, "seen = " .. os.time())
end

function irc_ontopic(channel, numeric, message)
  if not numeric then
    return
  end

  channel = irctolowerascii(channel)

  if not a4_is_stats_channel(channel) then
    return
  end

  updates = {}
  a4_touchuser(updates, numeric)
  table.insert(updates, "last = '" .. a4_escape_string("TOPIC " .. message) .. "'")
  a4_update_user(a4_getchannelid(channel), a4_getaccount(numeric), a4_getaccountid(numeric), updates)

  a4_add_topic(a4_getchannelid(channel), message, a4_getaccount(numeric), a4_getaccountid(numeric))
end

function irc_onop(channel, numeric, victimnumeric)
  if not numeric then
    return
  end

  channel = irctolowerascii(channel)

  if not a4_is_stats_channel(channel) then
    return
  end

  local victim = irc_getnickbynumeric(victimnumeric)

  updates = {}
  a4_touchuser(updates, numeric)
  table.insert(updates, "ops = ops + 1")
  table.insert(updates, "last = '" .. a4_escape_string("MODE +o " .. victim.nick) .. "'")
  a4_update_user(a4_getchannelid(channel), a4_getaccount(numeric), a4_getaccountid(numeric), updates);
end

function irc_ondeop(channel, numeric, victimnumeric)
  if not numeric then
    return
  end

  channel = irctolowerascii(channel)

  if not a4_is_stats_channel(channel) then
    return
  end

  local victim = irc_fastgetnickbynumeric(victimnumeric, { nickpusher.nick })

  updates = {}
  a4_touchuser(updates, numeric)
  table.insert(updates, "deops = deops + 1")
  table.insert(updates, "last = '" .. a4_escape_string("MODE -o " .. victim) .. "'")
  a4_update_user(a4_getchannelid(channel), a4_getaccount(numeric), a4_getaccountid(numeric), updates);
end

function irc_onkickall(channel, kicked_numeric, kicker_numeric, message)
  irc_onkick(channel, kicked_numeric, kicker_numeric, message)
end

function irc_onkick(channel, kicked_numeric, kicker_numeric, message)
  channel = irctolowerascii(channel)

  if not a4_is_stats_channel(channel) then
    return
  end

  if a4_bot == kicked_numeric then
    a4_int_remove_channel(channel)
    return
  end

  updates = {}
  a4_touchuser(updates, kicker_numeric)
  table.insert(updates, "kicks = kicks + 1")
  table.insert(updates, "last = '" .. a4_escape_string("KICK " .. irc_fastgetnickbynumeric(kicked_numeric, { nickpusher.nick }) .. " " .. message) .. "'")
  a4_update_user(a4_getchannelid(channel), a4_getaccount(kicker_numeric), a4_getaccountid(kicker_numeric), updates);

  updates = {}
  a4_touchuser(updates, kicked_numeric)
  table.insert(updates, "kicked = kicked + 1")
  table.insert(updates, "last = '" .. a4_escape_string("KICKED " .. irc_fastgetnickbynumeric(kicker_numeric, { nickpusher.nick }) .. " " .. message) .. "'")
  a4_update_user(a4_getchannelid(channel), a4_getaccount(kicked_numeric), a4_getaccountid(kicked_numeric), updates);

  a4_add_kick(a4_getchannelid(channel), a4_getaccount(kicker_numeric), a4_getaccountid(kicker_numeric), a4_getaccount(kicked_numeric), a4_getaccountid(kicked_numeric), message)
end

function irc_onpart(channel, numeric, message)
  channel = irctolowerascii(channel)

  if not a4_is_stats_channel(channel) then
    return
  end

  if not message then
    message = ""
  end

  updates = {}
  a4_touchuser(updates, numeric)
  table.insert(updates, "last = '" .. a4_escape_string("PART " .. message) .. "'")
  a4_update_user(a4_getchannelid(channel), a4_getaccount(numeric), a4_getaccountid(numeric), updates)
end

function irc_onprequit(numeric)
  for channel, _ in pairs(a4_channels) do
    if irc_nickonchan(numeric, channel) then
      updates = {}
      a4_touchuser(updates, numeric)
      table.insert(updates, "last = 'QUIT'")
      a4_update_user(a4_getchannelid(channel), a4_getaccount(numeric), a4_getaccountid(numeric), updates)
    end
  end
end

function irc_onrename(numeric, oldnick)
  for channel, _ in pairs(a4_channels) do
    if irc_nickonchan(numeric, channel) then
      updates = {}
      a4_touchuser(updates, numeric)
      table.insert(updates, "last = 'NICK'")
      a4_update_user(a4_getchannelid(channel), a4_getaccount(numeric), a4_getaccountid(numeric), updates)
    end
  end
end
