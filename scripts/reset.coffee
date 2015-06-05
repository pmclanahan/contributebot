module.exports = (robot) ->

  is_authorized = (res) ->
    if robot.auth.hasRole res.message.user, 'contributejson'
      true
    else
      res.reply "Sorry. You must have permission to do this thing."
      false

  robot.respond /contributejson reset$/i, (res) ->
    unless is_authorized res
      return

    # reset data w/o clearing known nicks
    robot.brain.data.contributebot.data = {}
    robot.brain.data.contributebot.channels = {}
    res.reply "done"
