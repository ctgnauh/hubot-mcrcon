# Description:
#   Executes Minecraft commands over RCON
#
# Dependencies:
#   "underscore": "~1.4.4",
#   "rcon": "~0.1.5"
#
# Configuration:
#   HUBOT_MCRCON_SECRET - A secret used to encrypt RCON passwords
#
# Commands:
#   minecraft help - shows detailed help for the minecraft command
#   mc help - shows detailed help for the minecraft command
#
# Notes:
#   None
#
# Author:
#   rbergman

{object, keys} = require "underscore"
Rcon = require "rcon"
URL = require "url-parse"
{inspect} = require "util"

params = ["timeout", "secret"]
opts = object do ->
  getopt = (k) -> process.env["HUBOT_MCRCON_#{k.toUpperCase()}"]
  [k, v] for k in params when (v = getopt k) and v
opts.timeout = if opts.timeout then parseInt opts.timeout, 10 else 3000

class Crypto
  crypto = require "crypto"
  algo = "aes256"
  constructor: (@secret) ->
  encrypt: (text) ->
    cipher = crypto.createCipher algo, @secret
    cipher.update(text, "utf8", "hex") + cipher.final("hex")
  decrypt: (data) ->
    decipher = crypto.createDecipher algo, @secret
    decipher.update(data, "hex", "utf8") + decipher.final("utf8")

crypto = new Crypto opts.secret

SERVERS_KEY = "mcrcon-servers"

module.exports = (robot) ->

  if keys(opts).length is params.length
    configure robot
  else
    robot.logger.warning "MC RCON: Invalid settings: #{inspect opts}"

configure = (robot) ->

  re = ///
    (?:minecraft|mc)\s+
    (help|servers|\w+)
    (?:\s+
      (list|say|i\s+am|who\s+am\s+i|add|drop|\+|-|ops|/?\w+)
      (?:\s+(.*))?
    )?
  ///i

  robot.hear re, (res) ->
    user = res.message.user
    match = res.match
    first = match[1]
    return cmds.help res if first is "help"
    servers = robot.brain.get(SERVERS_KEY) or {}
    robot.brain.set SERVERS_KEY, servers
    return cmds.servers res, servers if first is "servers"
    server = first
    subcmd = match[2]
    subcmd = subcmd.slice 1 if subcmd?.charAt(0) is "/"
    subcmd = "list" if not subcmd?
    subcmd = subcmd.toLowerCase()
    subcmd = {"i am": "set", "who am i": "get", "+": "op", "-": "deop"}[subcmd] or subcmd
    if not servers[server] and not (subcmd in ["add", "drop"])
      return res.reply "I don't know anything about a Minecraft server named #{first}."
    args = match[3]?.split(/\s+/) or []
    return cmds[subcmd] res, user, args, server, servers if cmds[subcmd] and not (subcmd in ["help", "servers"])
    cmds.exec res, user, [subcmd].concat(args), server, servers

  userForToken = (token, res) ->
    users = usersForToken token
    if users.length is 1
      user = users[0]
    else if users.length > 1
      res.send "Be more specific, I know #{users.length} people named like that: #{(u.name for u in users).join ", "}."
    else
      res.send "Sorry, I don't recognize the user named '#{token}'."
    user

  usersForToken = (token) ->
    user = robot.brain.userForName token
    return [user] if user
    user = userForMentionName token
    return [user] if user
    robot.brain.usersForFuzzyName token

  userForMentionName = (mentionName) ->
    for id, user of robot.brain.users()
      return user if mentionName is user.mention_name

  cmds =

    help: (res, header) ->
      msg = """
        command                             who?      description 
        ----------------------------------- --------- --------------------------------
        mc help                             all       display this message
        mc servers                          all       lists known servers
        mc <server>                         all       lists logged in players
        mc <server> list                    all       lists logged in players
        mc <server> say                     all       broadcasts an in-game message
        mc <server> i am <player>           all       sets your Minecraft player name
        mc <server> who am i                all       echos your Minecraft player name
        mc <server> add <host[:port]> <pw>  all       add a Minecraft RCON server
        mc <server> drop                    owner     drop a server
        mc <server> + <chat user>           op|owner  ops a chat user
        mc <server> - <chat user>           op|owner  deops a chat user
        mc <server> ops                     all       lists chat user ops
        mc <server> <remote command>        op|owner  executes remote command
      """
      res.send (if header then header + "\n" else "") + msg

    servers: (res, servers) ->
      list = keys(servers)
        .map (name) ->
          server = servers[name]
          "#{name} @ #{server.host}:#{server.port} (#{server.owner})"
        .sort().join "\n"
      if list.length is 0
        return res.send "I don't know any Minecraft servers."
      res.send "I know about these Minecraft servers:\n#{list}"

    list: (res, user, args, server, servers) ->
      exec servers[server], "list", (err, result) ->
        return res.send String(err) if err
        result = result.replace ":",
          (if /\s0\/\d/.test result then "." else ": ")
        res.send result

    say: (res, user, args, server, servers) ->
      if args.length is 0
        return res.reply "You must have something to say!"
      player = servers[server].players?[user.name]
      name = if player then "#{player} (#{user.name})" else user.name
      exec servers[server], "say [#{name}] #{args.join ' '}", (err, result) ->
        return res.send String(err) if err
        res.reply (result or "Message sent.")

    set: (res, user, args, server, servers) ->
      return res.reply "You must provide a player name." if args.length isnt 1
      players = servers[server].players ?= {}
      player = players[user.name] = args[0]
      res.reply "Ok, you are #{player} on the server #{server}."

    get: (res, user, args, server, servers) ->
      players = servers[server].players ?= {}
      player = players[user.name]
      return res.reply "You have not set a player name on the server #{server}." if not player
      res.reply "You are #{player} on the server #{server}."

    add: (res, user, args, server, servers) ->
      # @todo can we enforce direct messaging?
      if args.length isnt 2
        return res.reply "You must specify <host:port> <password>. Use a private room!"
      url = new URL args[0]
      host = url.hostname
      port = url.port
      return res.reply "You must specify a host." if not host
      port or= "25575"
      password = crypto.encrypt args[1]
      return res.reply "You must specify a password. Use a private room!" if not password
      servers[server] = {owner: user.name, host, port, password}
      res.reply "Ok, I will remember that server."

    drop: (res, user, args, server, servers) ->
      s = servers[server]
      if not s
        return res.reply "I don't know anything about a Minecraft server named #{server}."
      if user.name isnt s.owner
        return res.reply "Only the server owner can drop it."
      delete servers[server]
      res.reply "Ok, I forgot the server #{server}."

    op: (res, user, args, server, servers) ->
      s = servers[server]
      if user.name isnt s.owner and not (user.name in s.ops)
        return res.reply "You are not authorized to op chat users."
      if args.length is 0
        return res.reply "You must specify a chat user to op."
      userToken = args.join " "
      targetUser = userForToken userToken, res
      return if not targetUser
      ops = s.ops ?= []
      if not (targetUser.name in ops) then ops.push targetUser.name
      res.send "Ok, #{targetUser.name} is an op on the server #{server}."

    deop: (res, user, args, server, servers) ->
      s = servers[server]
      if user.name isnt s.owner and not (user.name in s.ops)
        return res.reply "You are not authorized to deop chat users."
      if args.length is 0
        return res.reply "You must specify a chat user to deop."
      userToken = args.join " "
      targetUser = userForToken userToken, res
      return if not targetUser
      ops = s.ops ?= []
      if not (targetUser.name in ops)
        return res.send "I can't find the op #{targetUser.name} listed for the server #{server}."
      s.ops = (op for op in ops when op isnt targetUser.name)
      res.send "Ok, #{targetUser.name} is no longer an op on the server #{server}."

    ops: (res, user, args, server, servers) ->
      ops = servers[server].ops ?= []
      if ops.length is 0
        return res.send "The server #{server} has no chat user ops assigned."
      res.send "The server #{server} has the following chat user ops:\n#{ops.join '\n'}"

    exec: (res, user, args, server, servers) ->
      s = servers[server]
      if user.name isnt s.owner and not (user.name in s.ops)
        return res.reply "You are not authorized to execute remote commands on the server #{server}."
      exec servers[server], args.join(" "), (err, result) ->
        return res.reply String(err) if err
        # @todo better organization here; combine with list
        if args[0] is "help"
          result = result.replace /\/\w+( <)?/g, ($0) -> if $0 isnt "/help <" then "\n" + $0 else $0
        res.send result

exec = (server, cmd, callback) ->
  # we use our own timeouts here because the mcrcon one is buggy
  next = (err, result) ->
    # only way i've found to stop mcrcon timeout messages after our own timeout runs
    return if err && err.toString().indexOf("ETIMEDOUT") >= 0
    callback err, result if callback
  timeout = timer opts.timeout, next
  connected = false
  password = crypto.decrypt server.password
  rcon = Rcon server.host, server.port, password
  rcon.on "connect", ->
    timeout.cancel()
    connected = true
  rcon.on "auth", ->
    timeout = timer opts.timeout, next
    rcon.send cmd
  rcon.on "response", (str) ->
    timeout.cancel()
    result = sanitize(str) or ""
    next null, result
    callback = null
    rcon.disconnect()
  rcon.on "error", (err) ->
    timeout.cancel()
    next err
    callback = null
    rcon.disconnect() if connected
  rcon.on "end", ->
    connected = false
  rcon.connect()

class Timeout
  constructor: (ms, callback) ->
    @handle = setTimeout callback, ms
  cancel: ->
    clearTimeout @handle
    @handle = null

timer = (ms, callback) ->
  new Timeout ms, ->
    callback "The server is not responding."

sanitize = (s) ->
  # \u0000 strips buffer chars;
  # \ufffd. may be an encoding error?
  s.replace /(\u0000)|(\ufffd.)/g, -> ""
