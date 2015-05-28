# Description:
#   Welcome new potential contributors when they enter your IRC channel.
#   Channel and message based on data in your contribute.json file.
#
# Configuration:
#   HUBOT_CONTRIBUTE_WELCOME_WAIT: seconds to wait after a new user joins (default 60)
#
# Commands:
#   User must have the "contributejson" role via the hubot-auth script.
#
#   list contributejson: List the urls the bot currently knows.
#   add contributejson <url>: Add a contribute.json URL to the list and join the channel in the file.
#   rm contributejson <url>: Remove a contribute.json URL from the list and leave the channel.

contribute_json_valid = (data) ->
  true if data? and data.name? and data.description? and data.participate?.irc?

get_irc_channel = (data) ->
  # take contribute.json data and return IRC channel
  # just for irc.mozilla.org so far
  irc_url = data.participate.irc
  return irc_url.substring irc_url.indexOf('#'), irc_url.length


class ContributeBot
  constructor: (@robot, @welcome_wait) ->
    @newcomers = {}
    @brain = null
    joined_channels = false

    @robot.brain.on 'loaded', =>
      robot.brain.data.contributebot ||= {}
      robot.brain.data.contributebot.data ||= {}
      robot.brain.data.contributebot.channels ||= {}
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

  welcome_newcomer: (res) =>
    {user, room} = res.message
    data = @get_channel_data(room)
    contacts = data.participate['irc-contacts']?.join(', ')
    res.reply "Hi there! Welcome to #{room} where we discuss #{data.name}: #{data.description}.
               We're happy you're here!"
    res.send "I just wanted to say hi since it appears no one is active at the moment."
    if contacts?
      res.send "The project leads (#{contacts}) will be around at some point and will have
                the answers to questions you may have, so feel free to ask if you have any."
    else
      res.send "There are people around who can answer questions you may have,
                but aren't always paying attention to IRC. Just ask any time
                and someone will get back to you when they can."
    res.send "Until then you can check out our docs (#{data.participate.docs})
              to see if you'd like to help."
    if data.bugs.mentored?
      res.send "We also have a list of mentored bugs that you may be
                interested in seeing: #{data.bugs.mentored}"
    res.reply "Thanks again for stopping by! I've been a hopefully helpful bot,
               and I won't bug you again."

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

    @robot.logger.debug "joining channels"
    for channel in Object.keys @brain.channels
      @robot.logger.debug "- joining #{channel}"
      @robot.adapter.join channel
      @robot.logger.info "Joined #{channel}"

    @joined_channels = true

  init_listeners: ->
    self = @

    # only for IRC
    @robot.adapter.bot.addListener 'names', (channel, nicks) ->
      self.brain.users[channel] ||= []
      for nick in Object.keys nicks
        unless nick in self.brain.users[channel]
          self.brain.users[channel].push nick
          self.robot.logger.debug "Added #{nick} to #{channel} list."

    @robot.adapter.bot.addListener 'nick', (old_nick, new_nick, channels, message) ->
      for channel in channels
        if channel of self.brain.users
          self.brain.users[channel].push new_nick

    # someone has entered the room
    # let's greet them in a minute
    @robot.enter (res) ->
      if res.message.user.name is self.robot.name
        if res.message.room in process.env.HUBOT_IRC_ROOMS.split ","
          # bot has registered
          self.join_channels()
        return

      # only a channel for which we have data
      unless res.message.room of self.brain.channels
        return

      user = self.robot.brain.userForName(res.message.user.name)
      if user.name in self.brain.users[res.message.room]
        self.robot.logger.debug "Already know #{user.name}"
        return

      user.newbe_timeout = setTimeout () ->
        self.welcome_newcomer res
      , self.welcome_wait * 1000

      self.newcomers[res.message.room] ||= []
      self.newcomers[res.message.room].push user

    @robot.hear /./, (res) ->
      # if there is any chatter don't welcome @newcomers
      if self.newcomers[res.message.room]?.length
        for user in self.newcomers[res.message.room]
          clearTimeout user.newbe_timeout if user.newbe_timeout?

        self.newcomers[res.message.room] = []

    @robot.respond /list contributejson$/i, (res) ->
      unless self.is_authorized(res)
        return

      if Object.keys(self.brain.data).length > 0
        res.reply "Sure. Here ya go:"
        res.send "- #{cj_url}" for own cj_url, x of self.brain.data
      else
        res.reply "Sorry. Empty list."

    @robot.respond /rm contributejson (http.+)$/i, (res) ->
      unless self.is_authorized(res)
        return

      cj_url = res.match[1].trim().toLowerCase()
      if cj_url of self.brain.data
        irc_channel = get_irc_channel(self.brain.data[cj_url])
        self.robot.adapter.part(irc_channel)
        res.reply "Left #{irc_channel}"
        delete self.brain.data[cj_url]
        delete self.brain.channels[irc_channel]
        res.reply "Done."
      else
        res.reply "Don't see that one. Check the spelling?"

    @robot.respond /update contributejson (http.+)$/i, (res) ->
      unless self.is_authorized(res)
        return

      cj_url = res.match[1].trim().toLowerCase()
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
        else
          self.robot.logger.debug "Invalid contribute data: %j", data
          res.reply "Something has gone wrong. Check the logs."

    @robot.respond /add contributejson (http.+)$/i, (res) ->
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
  new ContributeBot robot, welcome_wait
