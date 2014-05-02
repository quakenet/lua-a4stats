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

local BOTNICK = "D"
local BOTACCOUNT = "D"
local BOTACCOUNTID = 0

local a4_bot
local a4_sched = Scheduler()
local a4_channels = {}
local a4_channelstate = {}

function onload()
  onconnect()

  a4_sched:add(1800, a4_sched_check_channels)
end

function onconnect()
  a4_bot = irc_localregisteruserid(BOTNICK, "stats", "stats.quakenet.org", "Channel Statistics Service", BOTACCOUNT, BOTACCOUNTID, "+ikXr", statshandler)
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
  return a4_channels[irctolowerascii(channel)]
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
    a4_channels[irctolowerascii(name)] = id
  else
    a4_channels[irctolowerascii(name)] = nil
  end

  a4_check_channel(name)
end

function a4_int_enable_channel(channel)
  a4_enable_channel(channel)
  a4_fetch_channels("a4_fetch_channel_cb", {})
end

function a4_int_disable_channel(channel, part)
  a4_disable_channel(channel)
  a4_fetch_channels("a4_fetch_channel_cb", {})
end

function a4_sched_check_channels()
  a4_sched:add(1800, a4_sched_check_channels)
  a4_fetch_channels("a4_fetch_channel_cb", {})
end

function a4_check_channel(channel)
  local only_services = true
  for x in channelusers_iter(channel, { nickpusher.isservice }) do
    if not x[1] then
      only_services = false
      break
    end
  end

  local stats_channel = a4_is_stats_channel(channel)
  local service_onchan = irc_nickonchan(a4_bot, channel)

  if (only_services or not stats_channel) and service_onchan then
    irc_localpart(a4_bot, channel)
  elseif (not only_services and stats_channel) and not service_onchan then
    irc_localjoin(a4_bot, channel)
  end
end

function a4_notice(numeric, text)
  irc_localnotice(a4_bot, numeric, text)
end

function a4_split_message(message)
  message, _ = message:gsub("^ +", "")
  message, _ = message:gsub("  +", " ")
  message, _ = message:gsub(" +$", "")

  local tokens = {}
  for token in string.gmatch(message, "%S+") do
    table.insert(tokens, token)
  end

  return tokens
end

function a4_cmd_addchan(numeric, channel, privacy)
  if not privacy or privacy < 0 or privacy > 2 then
    privacy = 1
  end
  a4_enable_channel(channel)
  a4_set_privacy(channel, privacy)
  a4_fetch_channels("a4_fetch_channel_cb", {})
  a4_notice(numeric, "Done. Privacy = " .. privacy)
end

function a4_cmd_delchan(numeric, channel)
  a4_disable_channel(channel)
  a4_fetch_channels("a4_fetch_channel_cb", {})
  a4_notice(numeric, "Done.")
end

function a4_cmd_help(numeric)
  a4_notice(numeric, "addchan <chan> <privacy> - Privacy is 0 (public), 1 (presence), or 2 (Q known)")
  a4_notice(numeric, "delchan <chan>")
end

function statshandler(target, revent, ...)
  if revent == "irc_onchanmsg" then
    local numeric, channel, message = ...

    channel = irctolowerascii(channel)

    if not a4_is_stats_channel(channel) then
      return
    end

    a4_log_msg(channel, numeric, message)
  elseif revent == "irc_onmsg" then
    local numeric, message = ...

    if not ontlz(numeric) then
      return
    end

    local tokens = a4_split_message(message)
    local command = tokens[1]:lower()

    if not command then
      return
    end

    if command == "addchan" then
      a4_cmd_addchan(numeric, tokens[2], tonumber(tokens[3]))
    elseif command == "delchan" then
      a4_cmd_delchan(numeric, tokens[2])
    elseif command == "showcommands" or command == "help" then
      a4_cmd_help(numeric)
    end

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

  local smileyhappy = {":)", ":-)", ":p", ":-p", ":P", ":-P", ":D", ":-D", ":}", ":-}", ":]", ":-]", ";)", ";-)", ";p", ";-p", ";P", ";-P", ";D", ";-D", ";}", ";-}", ";]", ";-]"}
  local smileysad = {":(", ":-(", ":c", ":-c", ":C", ":-C", ":[", ":-[", ":{", ":-{", ";(", ";-(", ";c", ";-c", ";C", ";-C", ";[", ";-[", ";{", ";-{"}
  local foulmessage = {
    "fuck", "bitch", "shit", "cock", "dick", "stfu", "idiot", "moron", "cunt", "fag", "nigger", "prick", "retard", "twat", "wanker", "bastard", -- english
    "fick", "schlampe", "hure", "schwuchtel", "fotz", "wichs", "wix", --german
  }

  -- prepare the data we need now, numeric could be invalid in fetch_user callback
  local account = a4_getaccount(numeric)
  local accountid = a4_getaccountid(numeric)
  local nick = irc_fastgetnickbynumeric(numeric, { nickpusher.nick })
  local time = os.time()
  local hour = math.floor(time / 3600) % 24

  local updates = {}
  a4_touchuser(updates, numeric)


  -- relations
  if not a4_channelstate[channel]["lastmsgs"] then
    a4_channelstate[channel]["lastmsgs"] = a4_rb_new(10)
  end

  a4_rb_add(a4_channelstate[channel]["lastmsgs"], { account, accountid })

  for _, k in pairs(a4_rb_list(a4_channelstate[channel]["lastmsgs"], time - 120)) do
    if account ~= k[1] or accountid ~= k[2] then
      a4_update_relation(a4_getchannelid(channel), account, accountid, k[1], k[2])
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

  -- ctcp and actions are ignored, only count slaps
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
      end
    else
      -- ignore non-action CTCPs
      return
    end
  else
    table.insert(updates, "last = '" .. a4_escape_string("TEXT " .. message) .. "'")

    -- highlights, only for non-ACTIONs (those count as slaps)
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

  table.insert(updates, "h" .. hour .. " = h" .. hour .. " + 1")

  table.insert(updates, "lines = lines + 1")

  table.insert(updates, "chars = chars + " .. string.len(message))

  local _, count = string.gsub(message, " ", "")
  table.insert(updates, "words = words + " .. count + 1)

  local _, count = string.gsub(message, "[A-Z!?]", "")
  table.insert(updates, "caps = caps + " .. count)

  a4_add_line(channel, hour)

  table.insert(updates, "rating = (CASE WHEN " .. time .. " - seen > 600 THEN 120 ELSE " .. time .. " - seen END)")

  if string.len(message) > 20 and string.len(message) < 200 then
    local quote, random
    random = math.random(100)
    if action then
      quote = "* " .. nick .. " " .. message
    else
      quote = message
    end
    quote = a4_escape_string(quote)
    table.insert(updates, "quote = (CASE WHEN quotereset = 0 OR (" .. time .. " - quotereset > 7200 AND " .. random .. "> 70) THEN '" .. quote .. "' ELSE quote END)")
    table.insert(updates, "quotereset = (CASE WHEN quotereset = 0 OR (" .. time .. " - quotereset > 7200 AND " .. random .. " > 70) THEN " .. time .. " ELSE quotereset END)")
  end

  a4_update_user(a4_getchannelid(channel), account, accountid, updates)
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
  local id
  local accountid, account = irc_fastgetnickbynumeric(numeric, { nickpusher.accountid, nickpusher.authname })

  if accountid then
    id = account
  else
    id = a4_maskhost(irc_getvisiblehostmask(numeric))
  end

  return id
end

function a4_touchuser(updates, numeric)
  local nick = irc_fastgetnickbynumeric(numeric, { nickpusher.nick })

  table.insert(updates, "accountid = '" .. a4_getaccountid(numeric) .. "'")
  table.insert(updates, "curnick = '" .. a4_escape_string(nick) .. "'")
  table.insert(updates, "seen = " .. os.time())
end

function irc_onjoin(channel, numeric)
  a4_check_channel(channel)
end

function irc_ontopic(channel, numeric, message)
  if not numeric then
    return
  end

  channel = irctolowerascii(channel)

  if not a4_is_stats_channel(channel) then
    return
  end

  local updates = {}
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

  local victim = irc_fastgetnickbynumeric(victimnumeric, { nickpusher.nick })

  local updates = {}
  a4_touchuser(updates, numeric)
  table.insert(updates, "ops = ops + 1")
  table.insert(updates, "last = '" .. a4_escape_string("MODE +o " .. victim) .. "'")
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

  local updates = {}
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

  local updates = {}
  a4_touchuser(updates, kicker_numeric)
  table.insert(updates, "kicks = kicks + 1")
  table.insert(updates, "last = '" .. a4_escape_string("KICK " .. irc_fastgetnickbynumeric(kicked_numeric, { nickpusher.nick }) .. " " .. message) .. "'")
  a4_update_user(a4_getchannelid(channel), a4_getaccount(kicker_numeric), a4_getaccountid(kicker_numeric), updates);

  local updates = {}
  a4_touchuser(updates, kicked_numeric)
  table.insert(updates, "kicked = kicked + 1")
  table.insert(updates, "last = '" .. a4_escape_string("KICKED " .. irc_fastgetnickbynumeric(kicker_numeric, { nickpusher.nick }) .. " " .. message) .. "'")
  a4_update_user(a4_getchannelid(channel), a4_getaccount(kicked_numeric), a4_getaccountid(kicked_numeric), updates);

  a4_add_kick(a4_getchannelid(channel), a4_getaccount(kicker_numeric), a4_getaccountid(kicker_numeric), a4_getaccount(kicked_numeric), a4_getaccountid(kicked_numeric), message)
end

function irc_onpart(channel, numeric, message)
  channel = irctolowerascii(channel)

  if not a4_is_stats_channel(channel) or not irc_nickonchan(numeric, channel) then
    return
  end

  if not message then
    message = ""
  end

  local updates = {}
  a4_touchuser(updates, numeric)
  table.insert(updates, "last = '" .. a4_escape_string("PART " .. message) .. "'")
  a4_update_user(a4_getchannelid(channel), a4_getaccount(numeric), a4_getaccountid(numeric), updates)
end

function irc_onprequit(numeric)
  for channel, _ in pairs(a4_channels) do
    if irc_nickonchan(numeric, channel) then
      local updates = {}
      a4_touchuser(updates, numeric)
      table.insert(updates, "last = 'QUIT'")
      a4_update_user(a4_getchannelid(channel), a4_getaccount(numeric), a4_getaccountid(numeric), updates)
    end
  end
end

function irc_onrename(numeric, oldnick)
  for channel, _ in pairs(a4_channels) do
    if irc_nickonchan(numeric, channel) then
      local updates = {}
      a4_touchuser(updates, numeric)
      table.insert(updates, "last = 'NICK'")
      a4_update_user(a4_getchannelid(channel), a4_getaccount(numeric), a4_getaccountid(numeric), updates)
    end
  end
end
