Spine       = require "spine"
errify      = require "errify"
Relations   = require "./relations"
{loadModel} = Relations


arraysMatch = (arrays...) ->
  match = String arrays.pop()
  return false for array in arrays when (String array) isnt match
  true

isEmpty = (obj) ->
  return false for own key of obj
  true


class Collection extends Relations.Classes.BaseCollection
  select: (cb) ->
    @model.select (rec) =>
      @associated(rec) and cb(rec)


class Instance extends Relations.Classes.Instance
  find: (cb = ->) ->
    unless @record[@fkey]
      cb "no foreign key"
      false
    else
      @model.find @record[@fkey], cb

  update: (value, cb = ->) ->
    ideally = errify cb
    unless value instanceof @model
      value = new @model value
    await value.save ideally defer() if value.isNew()

    @record[@fkey] = value and value.id
    @record.save cb


class Singleton extends Relations.Classes.Singleton
  find: (cb = ->) ->
    @record.id and @model.findByAttribute @fkey, @record.id, cb

  update: (value, cb = ->) ->
    unless value instanceof @model
      value = @model.fromJSON(value)

    value[@fkey] = @record.id
    value.save cb


Async =
  findCached: -> Spine.Model.find.apply this, arguments

  belongsTo: (model, name, fkey) ->
    parent = @
    unless name?
      model = loadModel model, parent
      name  = model.className.toLowerCase()
      name  = singularize underscore name
    fkey ?= "#{name}_id"

    association = (record) ->
      model = loadModel model, parent
      new Instance {name, model, record, fkey}

    @::[name] = (value, cb = ->) ->
      if typeof value is "function"
        cb    = value
        value = null

      if value?
        association(@).update value, cb
      else
        association(@).find cb

    @attributes.push fkey

  hasOne: (model, name, fkey) ->
    parent = @
    unless name?
      model = loadModel model, parent
      name = model.className.toLowerCase()
      name = singularize underscore name
    fkey ?= "#{underscore(@className)}_id"

    association = (record) ->
      model = loadModel model, parent
      new Singleton {name, model, record, fkey}

    @::[name] = (value, cb) ->
      association(@).update value, cb if value?
      association(@).find cb



AsyncHelpers =
  diff: ->
    return this if @isNew()
    attrs = @attributes()
    orig  = @constructor.findCached @id
    diff  = {}
    for key, value of attrs
      origkey = orig[key]
      origkey = orig[key]() if typeof origkey is "function"
      if Array.isArray value
        diff[key] = value unless arraysMatch origkey, value
      else
        diff[key] = value unless origkey is value

    return null if isEmpty diff
    diff



Spine.Model.extend.call Relations, Async
Spine.Model.extend Relations
Spine.Model.include AsyncHelpers

Relations.Classes.Collection = Collection
Relations.Classes.Instance   = Instance
Spine.Model.Relations        = Relations
module?.exports              = Relations
