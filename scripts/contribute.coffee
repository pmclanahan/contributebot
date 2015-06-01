# Description:
#   Welcome new potential contributors when they enter your IRC channel.
#   Channel and message based on data in your contribute.json file.
#
#   contribute.json: http://www.contributejson.org/
#
# Configuration:
#   HUBOT_CONTRIBUTE_WELCOME_WAIT: seconds to wait after a new user joins (default 60)
#   HUBOT_CONTRIBUTE_ENABLE_CRON: set to "true" to update contribute.json data daily.
#
# Dependencies:
#   "hubot-cronjob": "^0.2.0"
#
# Commands:
#   hubot contributejson list: List the channels and contribute.json URLs known by the bot.
#   hubot contributejson add <url>: Add a contribute.json URL to the list and join the channel in the file.
#   hubot contributejson rm [url]: Remove a contribute.json URL from the list and leave the channel.
#   hubot contributejson update [url]: Update the data for the contribute.json URL or channel.
#
# Notes:
#   * Commands require the user to have the "contributejson" role via the hubot-auth script.
#   * A persistent brain store like hubot-redis-brain is highly recommended.
#
# Author:
#   pmclanahan


contribute_json_valid = (data) ->
  true if data? and data.name? and data.description? and data.participate?.irc?

get_irc_channel = (data) ->
  # take contribute.json data and return IRC channel
  # just for irc.mozilla.org so far
  irc_url = data.participate.irc
  return irc_url.substring irc_url.indexOf('#'), irc_url.length

format_nick_list = (nicks) ->
  unless Array.isArray nicks
    return nicks

  unless nicks.length > 1
    return nicks[0]

  last_nick = nicks.pop()
  return nicks.join(', ') + " and #{last_nick}"


class ContributeBot
  constructor: (@robot, @welcome_wait) ->
    @newcomers = {}
    @newcomer_timeouts = {}
    @brain = null
    @joined_channels = false

    @robot.brain.on 'loaded', =>
      robot.brain.data.contributebot ||= {}
      # URL: contribute.json data
      robot.brain.data.contributebot.data ||= {}
      # channel: contribute.json URL
      robot.brain.data.contributebot.channels ||= {}
      # channel: array of nicks
      robot.brain.data.contributebot.users ||= {}
      @brain = robot.brain.data.contributebot
      @init_listeners()

  get_channel_data: (channel) ->
    @brain.data[@brain.channels[channel]]

  is_authorized: (res) ->
    if @robot.auth.hasRole res.message.user, 'contributejson'
      true
    else
      res.reply "Sorry. You must have permission to do this thing."
      false

  welcome_newcomers: (room) =>
    reply = []
    data = @get_channel_data(room)
    nicks = format_nick_list @newcomers[room]
    delete @newcomer_timeouts[room]
    reply.push "Hi there #{nicks}. Welcome to #{room} where we discuss the #{data.name} project. " +
               "We're happy you're here!"
    reply.push "I'm just a bot, but I wanted to say hi since the channel is quiet at the moment."
    if 'irc-contacts' of data.participate
      contacts = format_nick_list data.participate['irc-contacts'][..2]
      reply.push "Some project members (like #{contacts}) will be around at some point and will have " +
                 "the answers to questions you may have, so feel free to go ahead ask if you have any."
    else
      reply.push "There are people around who can answer questions you may have, " +
                 "but aren't always paying attention to IRC. Just ask any time " +
                 "and someone will get back to you when they can."
    reply.push "Until then you can check out our docs (#{data.participate.docs}) " +
               "to see if you'd like to help."
    if data.bugs.mentored?
      reply.push "We also have a list of mentored bugs that you may be interested in: #{data.bugs.mentored}"
    reply.push "Thanks again for stopping by! I've been a hopefully helpful bot, and I won't bother you again."

    @process_room room
    reply

  get_contribute_json: (json_url, callback) ->
    @robot.http(json_url).header('Accept', 'application/json').get() (err, res, body) ->
      data = null
      if err
        @robot.logger.error "Encountered an error fetching #{json_url} :( #{err}"
        callback null
        return

      try
        data = JSON.parse(body)
      catch error
        @robot.logger.error "Ran into an error parsing JSON :("

      callback data

  join_channels: ->
    if @joined_channels
      return

    for channel in Object.keys @brain.channels
      @robot.adapter.join channel

    @joined_channels = true

  add_known_nicks: (room, nicks) =>
    @brain.users[room] ||= []
    nicks = [nicks] unless Array.isArray nicks
    for nick in nicks
      unless nick in @brain.users[room]
        @brain.users[room].push nick
        @robot.logger.debug "Added #{nick} to #{room} list."

  process_room: (room) ->
    clearTimeout @newcomer_timeouts[room]
    delete @newcomer_timeouts[room]
    @add_known_nicks(room, @newcomers[room])
    @newcomers[room] = []

  update_contribute_data: =>
    self = @
    @robot.logger.debug 'Updating all contribute data.'
    for cj_url, old_data of @brain.data
      old_channel = get_irc_channel(old_data)
      @get_contribute_json cj_url, (data) ->
        if contribute_json_valid data
          self.robot.logger.debug "Updated #{cj_url}"
          self.brain.data[cj_url] = data
          irc_channel = get_irc_channel(data)
          unless irc_channel is old_channel
            self.robot.adapter.join irc_channel
            self.robot.adapter.part old_channel
            self.brain.channels[irc_channel] = cj_url
            delete self.brain.channels[old_channel]
            delete self.brain.users[old_channel]
        else
          self.robot.logger.debug "Invalid contribute data: %j", data
          res.reply "Something has gone wrong. Check the logs."

  init_listeners: ->
    self = @

    # only for IRC
    if @robot.adapter.bot?.addListener?
      @robot.adapter.bot.addListener 'names', (room, nicks) ->
        self.add_known_nicks room, Object.keys nicks

      @robot.adapter.bot.addListener 'nick', (old_nick, new_nick, channels, message) ->
        for channel in channels
          if channel of self.brain.users
            self.add_known_nicks(channel, new_nick)

    # someone has entered the room
    # let's greet them in a minute
    @robot.enter (res) ->
      {user, room} = res.message
      if user.name is self.robot.name
        if room in process.env.HUBOT_IRC_ROOMS.split ","
          # bot has registered
          self.join_channels()
        return

      # only a channel for which we have data
      unless room of self.brain.channels
        return

      if user.name in self.brain.users[room]
        self.robot.logger.debug "Already know #{user.name}"
        return

      self.newcomers[room] ||= []
      self.newcomers[room].push user.name

      if self.newcomer_timeouts[room]?
        clearTimeout self.newcomer_timeouts[room]

      self.newcomer_timeouts[room] = setTimeout () ->
        res.send msg for msg in self.welcome_newcomers room
      , self.welcome_wait * 1000

    @robot.hear /./, (res) ->
      {user, room} = res.message
      # if there is any chatter don't welcome @newcomers
      if self.newcomer_timeouts[room]?
        # newcomers shouldn't cancel welcomes
        unless user.name in self.newcomers[room]
          self.process_room(room)

    @robot.respond /contributejson( list)?$/i, (res) ->
      unless self.is_authorized(res)
        return

      if Object.keys(self.brain.channels).length > 0
        res.send "#{room}: #{cj_url}" for own room, cj_url of self.brain.channels
      else
        res.reply "Sorry. Empty list."

    @robot.respond /contributejson (rm|remove|delete)( http.+)?$/i, (res) ->
      unless self.is_authorized(res)
        return

      if res.match[1]?
        cj_url = res.match[1].trim().toLowerCase()
      else
        cj_url = self.brain.channels[res.message.room]
        unless cj_url
          res.reply "This channel doesn't seem to have a data source."
          return

      if cj_url of self.brain.data
        irc_channel = get_irc_channel(self.brain.data[cj_url])
        self.robot.adapter.part(irc_channel)
        res.reply "Left #{irc_channel}"
        delete self.brain.data[cj_url]
        delete self.brain.channels[irc_channel]
        res.reply "Done."
      else
        res.reply "Don't see that one. Check the spelling?"

    @robot.respond /contributejson update( http.+)?$/i, (res) ->
      unless self.is_authorized(res)
        return

      if res.match[1]?
        cj_url = res.match[1].trim().toLowerCase()
      else
        cj_url = self.brain.channels[res.message.room]
        unless cj_url
          res.reply "This channel doesn't seem to have a data source."
          return

      unless cj_url of self.brain.data
        res.reply "Don't have that one. Use the `add` command if you'd like to use this URL. Thanks!"
        return

      res.send "Grabbing the data... just a moment"
      old_channel = get_irc_channel(self.brain.data[cj_url])
      self.get_contribute_json cj_url, (data) ->
        if contribute_json_valid data
          self.robot.logger.debug "Got data from #{cj_url}:"
          self.brain.data[cj_url] = data
          res.reply "Successfully updated #{cj_url}!"
          irc_channel = get_irc_channel(data)
          unless irc_channel is old_channel
            self.robot.adapter.join irc_channel
            res.reply "Joined #{irc_channel}."
            self.robot.adapter.part old_channel
            res.reply "Left #{old_channel}."
            self.brain.channels[irc_channel] = cj_url
            delete self.brain.channels[old_channel]
            delete self.brain.users[old_channel]
        else
          self.robot.logger.debug "Invalid contribute data: %j", data
          res.reply "Something has gone wrong. Check the logs."

    @robot.respond /contributejson add (http.+)$/i, (res) ->
      unless self.is_authorized(res)
        return

      cj_url = res.match[1].trim().toLowerCase()
      if cj_url of self.brain.data
        res.reply "Already got that one. Use the `update` command if you'd like fresh data. Thanks!"
        return

      res.send "Grabbing the data... just a moment"
      self.get_contribute_json cj_url, (data) ->
        if contribute_json_valid data
          self.robot.logger.debug "Got data from #{cj_url}:"
          self.brain.data[cj_url] = data
          res.reply "Successfully added #{cj_url} to my list!"
          irc_channel = get_irc_channel(data)
          self.robot.adapter.join(irc_channel)
          res.reply "Joined #{irc_channel}."
          self.brain.channels[irc_channel] = cj_url
        else
          self.robot.logger.debug "Invalid contribute data: %j", data
          res.reply "Something has gone wrong. Check the logs."

    @robot.logger.debug "Listeners attached"


module.exports = (robot) ->
  welcome_wait = process.env.HUBOT_CONTRIBUTE_WELCOME_WAIT or 60
  cb = new ContributeBot robot, welcome_wait

  if process.env.HUBOT_CONTRIBUTE_ENABLE_CRON?
    HubotCron = require 'hubot-cronjob'
    # run every midnight
    new HubotCron '0 0 0 * * *', 'America/Los_Angeles', cb.update_contribute_data
