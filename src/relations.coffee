Spine     = require "spine"
{isArray} = Array


class BaseCollection extends Spine.Class
  constructor: (options = {}) ->
    for key, value of options
      @[key] = value

  first: ->
    @all()[0]

  last: ->
    @all()[-1..]

  create: (record, options) ->
    newRecord = @model.create record, options
    (@add newRecord) if newRecord


class Collection extends BaseCollection
  add: (fItem) ->
    fItem[@fkey] = @record.id
    fItem.save()

  remove: (fItem) ->
    fItem = @find(fItem) if typeof fItem is 'string'
    fItem.destroy()

  all: ->
    @model.select (rec) => @associated(rec)

  find: (id) ->
    records = @select (rec) =>
      "#{rec.id}" is "#{id}"
    throw('Unknown record') unless records[0]
    records[0]

  findAllByAttribute: (name, value) ->
    @model.select (rec) =>
      @associated(rec) and rec[name] is value

  findByAttribute: (name, value) ->
    @findAllByAttribute(name, value)[0]

  select: (cb) ->
    @model.select (rec) =>
      @associated(rec) and cb(rec)

  refresh: (values) ->
    delete @model.records[record.id] for record in @all()
    records = @model.fromJSON(values)

    records = [records] unless isArray(records)

    for record in records
      record.newRecord = false
      record[@fkey] = @record.id
      @model.records[record.id] = record

    @model.trigger('refresh', @model.cloneArray(records))

  # Private

  associated: (record) ->
    record[@fkey] is @record.id


class O2MCollection extends BaseCollection
  add: (item, save = true) ->
    if isArray(item)
      @add i, false for i in item
    else
      item = @model.find item unless item instanceof @model
      @record[@lkey].push item[@fkey]
    @record.save() if save

  remove: (item) ->
    item = @model.find item unless item instanceof @model
    @record[@lkey].splice (@record[@lkey].indexOf item[@fkey]), 1
    @record.save()

  all: ->
    (@model.find lkey for lkey in @record[@lkey])

  find: (id) ->
    id in @record[@lkey] and @model.find id or throw 'Unknown record'


class M2MCollection extends BaseCollection
  add: (item, save = true) ->
    if isArray(item)
      @add i, false for i in item

    else
      item = @model.find item unless item instanceof @model
      hub = new @Hub()
      if @left_to_right
        hub["#{@rev_name}_id"] = @record.id
        hub["#{@name}_id"] = item.id

      else
        hub["#{@rev_name}_id"] = item.id
        hub["#{@name}_id"] = @record.id
    hub.save() if save

  remove: (item) ->
    i.destroy() for i in @Hub.select (item) =>
      @associated(item)

  _link: (items) ->
    items.map (item) =>
      if @left_to_right then return @model.find item["#{@name}_id"]
      else return @model.find item["#{@rev_name}_id"]

  all: ->
    @_link @Hub.select (item) =>
      @associated(item)

  find: (id) ->
    records = @Hub.select (rec) =>
      @associated(rec, id)

    throw 'Unknown record' unless records[0]
    @_link(records)[0]

  associated: (record, id) ->
    if @left_to_right
      return false unless record["#{@rev_name}_id"] is @record.id
      return record["#{@rev_name}_id"] is id if id

    else
      return false unless record["#{@name}_id"] is @record.id
      return record["#{@name}_id"] is id if id

    true


class Instance extends Spine.Class
  constructor: (options = {}) ->
    for key, value of options
      @[key] = value

  find: ->
    @model.find @record[@fkey]

  update: (value) ->
    unless value instanceof @model
      value = new @model(value)
    value.save if value.isNew()

    @record[@fkey] = value and value.id
    @record.save()


class Singleton extends Spine.Class
  constructor: (options = {}) ->
    for key, value of options
      @[key] = value

  find: ->
    @record.id and @model.findByAttribute(@fkey, @record.id)

  update: (value) ->
    unless value instanceof @model
      value = @model.fromJSON(value)

    value[@fkey] = @record.id
    value.save()


singularize = (str) ->
  str.replace(/s$/, '')

underscore = (str) ->
  str.replace(/::/g, '/')
     .replace(/([A-Z]+)([A-Z][a-z])/g, '$1_$2')
     .replace(/([a-z\d])([A-Z])/g, '$1_$2')
     .replace(/(-|\.)/g, '_')
     .toLowerCase()

loadModel = (model, parent) ->
  if typeof model is 'string'
    model = require(model)
    model.bind 'error', (record, msg) => parent.trigger 'error', record, msg, model.className
    if typeof model.loadSpineDB is 'function'
      model.bindSpineDB().fetch()
  model


Relations =
  __filter: (args, revert=false) ->
    (rec) ->
      q = !!revert
      for key, value of args
        return q unless rec[key] is value
      !q

  filter: (args) ->  @select @__filter args
  exclude: (args) -> @select @__filter args, true

  oneToMany: (model, name, fkey) ->
    parent = @
    unless name?
      model = loadModel model, parent
      name = model.className.toLowerCase()
      name = singularize underscore name

    lkey = "#{name}_ids"
    unless lkey in @attributes
      @attributes.push lkey

    fkey ?= 'id'

    association = (record, model) ->
      model = loadModel model, parent
      record[lkey] = [] unless record[lkey]
      new O2MCollection {lkey, fkey, record, model}

    @::["#{name}s"] = (value) ->
      association(@, model)

  hasMany: (model, name, fkey) ->
    parent = @
    unless name?
      model = loadModel model, parent
      name = model.className.toLowerCase()
      name = singularize underscore name
    fkey ?= "#{underscore(this.className)}_id"

    association = (record) ->
      model = loadModel model, parent
      new Collection(
        name: name, model: model,
        record: record, fkey: fkey
      )

    @::["#{name}s"] = (value) ->
      association(@).refresh(value) if value?
      association(@)

  belongsTo: (model, name, fkey) ->
    parent = @
    unless name?
      model = loadModel model, parent
      name = model.className.toLowerCase()
      name = singularize underscore name
    fkey ?= "#{name}_id"

    association = (record) ->
      model = loadModel model, parent
      new Instance(
        name: name, model: model,
        record: record, fkey: fkey
      )

    @::[name] = (value) ->
      if value?
        association(@).update(value)
      else
        association(@).find()

    @attributes.push(fkey)

  hasOne: (model, name, fkey) ->
    parent = @
    unless name?
      model = loadModel model, parent
      name = model.className.toLowerCase()
      name = singularize underscore name
    fkey ?= "#{underscore(@className)}_id"

    association = (record) ->
      model = loadModel model, parent
      new Singleton(
        name: name, model: model,
        record: record, fkey: fkey
      )

    @::[name] = (value) ->
      association(@).update(value) if value?
      association(@).find()

  foreignKey: (model, name, rev_name) ->
    parent = @
    unless name?
      model = loadModel model, parent
      name = model.className.toLowerCase()
      name = singularize underscore name

    unless rev_name?
      rev_name = @className.toLowerCase()
      rev_name = singularize underscore rev_name
      rev_name = "#{rev_name}s"

    @belongsTo name, model
    model.hasMany rev_name, @

  manyToMany: (model, name, rev_name) ->
    parent = @
    unless name?
      model = loadModel model, parent
      name = model.className.toLowerCase()
      name = singularize underscore name

    unless rev_name?
      rev_name = @className.toLowerCase()
      rev_name = singularize underscore rev_name
      rev_name = "#{rev_name}s"
    rev_model = @

    local = typeof model.loadLocal is 'function' or typeof rev_model.loadLocal is 'function'
    tigerDB = typeof model.loadSpineDB is 'function' or typeof rev_model.loadSpineDB is 'function'

    class Hub extends Spine.Model
      @extend Spine.Model.Local if local
      @extend Spine.Model.SpineDB if tigerDB
      @configure "_#{rev_name}_to_#{name}", "#{@rev_name}_id", "#{@name}_id"

    Hub.fetch() if local or tigerDB

    Hub.foreignKey rev_model, "#{rev_name}"
    Hub.foreignKey model,     "#{name}"

    association = (record, model, left_to_right) ->
      model = loadModel model, parent
      new M2MCollection {name, rev_name, record, model, Hub: Hub, left_to_right}

    rev_model::["#{name}s"] = (value) ->
      association(@, model, true)

    model::["#{rev_name}s"] = (value) ->
      association(@, rev_model, false)


Spine.Model.extend Relations
Relations.Classes     =
  BaseCollection:       BaseCollection
  Collection:           Collection
  O2MCollection:        O2MCollection
  M2MCollection:        M2MCollection
  Instance:             Instance
  Singleton:            Singleton
Relations.loadModel   = loadModel
Spine.Model.Relations = Relations
module?.exports       = Relations
