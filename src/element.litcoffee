# Element - cascading element tree

## Class Element

    debug = require('debug')('yang:element')
    delegate = require 'delegates'
    Emitter = require('events').EventEmitter
    Emitter.defaultMaxListeners = 100
    
    class Element

## Class-level methods

      @property: (prop, desc) ->
        Object.defineProperty @prototype, prop, desc

### use (elements...)

      @use: ->
        res = [].concat(arguments...)
          .filter (x) -> x?
          .map (elem) =>
            exists = Element::match.call this, elem.kind, elem.tag
            if exists?
              console.warn @error "use: already loaded '#{elem.kind}/#{elem.tag}'"
              return exists
            Element::merge.call this, elem
        return switch 
          when res.length > 1  then res
          when res.length is 1 then res[0]
          else undefined

      @error: (msg, ctx=this) ->
        res = new Error msg
        res.name = 'ElementError'
        res.context = ctx
        return res

## Main constructor

      constructor: (@kind, @tag, source={}) ->
        unless @kind?
          throw @error "must supply 'kind' to create a new Element"
        unless source instanceof Object
          throw @error "must supply 'source' as an object"

        Object.defineProperties this,
          parent: value: null, writable: true
          origin: value: null, writable: true
          source: value: source, writable: true
          state:  value: {}, writable: true
          emitter: value: new Emitter

      delegate @prototype, 'emitter'
        .method 'emit'
        .method 'once'
        .method 'on'

      delegate @prototype, 'source'
        .getter 'scope'
        .getter 'construct'

### Computed Properties

      @property 'trail',
        get: ->
          mark = @kind
          mark += "(#{@tag})" if @tag? and @source.argument not in [ 'value', 'text' ]
          return mark unless @parent instanceof Element
          return "#{@parent.trail}/#{mark}"

      @property 'root',
        get: -> switch
          when @parent instanceof Element then @parent.root
          when @origin instanceof Element then @origin.root
          else this

      @property 'node',
        get: -> @construct instanceof Function

      @property 'elements',
        get: ->
          (v for k, v of this when k not in [ 'parent', 'origin', 'tag' ]).reduce ((a,b) -> switch
            when b instanceof Element then a.concat b
            when b instanceof Array
              a.concat b.filter (x) -> x instanceof Element
            else a
          ), []

      @property 'nodes', get: -> @elements.filter (x) -> x.node is true
      @property 'attrs', get: -> @elements.filter (x) -> x.node is false
      @property '*',     get: -> @nodes
      @property '..',    get: -> @parent

## Instance-level methods

### clone

      clone: ->
        @debug "cloning #{@kind}:#{@tag} with #{@elements.length} elements"
        copy = (new @constructor @kind, @tag, @source).extends @elements.map (x) =>
          c = x.clone()
          c.parent = x.parent unless x.parent is this
          return c
        copy.state  = @state
        copy.origin = @origin ? this
        return copy

### extends (elements...)

This is the primary mechanism for defining sub-elements to become part
of the element tree

      extends: ->
        elems = ([].concat arguments...).filter (x) -> x? and !!x
        return this unless elems.length > 0
        elems.forEach (expr) => @merge expr
        @emit 'change', elems...
        return this

### merge (element)

This helper method merges a specific Element into current Element
while performing `@scope` validations.

      merge: (elem, opts={}) ->
        unless elem instanceof Element
          throw @error "cannot merge invalid element into Element", elem

        elem.parent ?= this

        _merge = (item) ->
          if opts.append is true or item.tag not in @tags
            @push item
            true
          else if opts.replace is true
            for x, i in this when x.tag is item.tag
              @splice i, 1, item
              break
            true
          else false

        unless @scope?
          unless @hasOwnProperty elem.kind
            @[elem.kind] = elem
            return elem

          unless Array.isArray @[elem.kind]
            exists = @[elem.kind]
            @[elem.kind] = [ exists ]
            Object.defineProperty @[elem.kind], 'tags',
              get: (-> @map (x) -> x.tag ).bind @[elem.kind]
              
          unless _merge.call @[elem.kind], elem
            throw @error "constraint violation for '#{elem.kind} #{elem.tag}' - cannot define more than once"

          return elem

        unless elem.kind of @scope
          if elem.scope?
            @debug @scope
            throw @error "scope violation - invalid '#{elem.kind}' extension found"
          else
            @scope[elem.kind] = '*' # this is hackish...

        switch @scope[elem.kind]
          when '0..n', '1..n', '*'
            unless @hasOwnProperty elem.kind
              @[elem.kind] = []
              Object.defineProperty @[elem.kind], 'tags',
                get: (-> @map (x) -> x.tag ).bind @[elem.kind]
            unless _merge.call @[elem.kind], elem
              throw @error "constraint violation for '#{elem.kind} #{elem.tag}' - already defined"
          when '0..1', '1'
            unless @hasOwnProperty elem.kind
              @[elem.kind] = elem
            else if opts.replace is true
              @[elem.kind] = elem
            else
              throw @error "constraint violation for '#{elem.kind}' - cannot define more than once"
          else
            throw @error "unrecognized scope constraint defined for '#{elem.kind}' with #{@scope[elem.kind]}"

        return elem

### update (element)

This alternative form of [merge](#merge-element) performs conditional
merge based on existence check. It is considered *safer* alternative
to direct [merge](#merge-element) call.

      # performs conditional merge based on existence
      update: (elem) ->
        unless elem instanceof Element
          throw @error "cannot update a non-Element into an Element", elem

        #@debug "update with #{elem.kind}/#{elem.tag}"
        exists = Element::match.call this, elem.kind, elem.tag
        return @merge elem unless exists?

        #@debug "update #{exists.kind} in-place for #{elem.elements.length} elements"
        exists.update target for target in elem.elements
        return exists

      # Looks for matching Elements using kind and tag
      # Direction: up the hierarchy (towards root)
      lookup: (kind, tag) ->
        res = switch
          when this not instanceof Object then undefined
          when this instanceof Element then @match kind, tag
          else Element::match.call this, kind, tag
        res ?= switch
          when @origin? then Element::lookup.apply @origin, arguments
          when @parent? then Element::lookup.apply @parent, arguments
          else Element::match.call @constructor, kind, tag
        return res

      # Looks for matching Elements using YPATH notation
      # Direction: down the hierarchy (away from root)
      locate: (ypath) ->
        return unless ypath?
        if typeof ypath is 'string'
          @debug "locate: #{ypath}"
          ypath = ypath.replace /\s/g, ''
          if (/^\//.test ypath) and this isnt @root
            return @root.locate ypath
          [ key, rest... ] = ypath.split('/').filter (e) -> !!e
        else
          @debug "locate: #{ypath.join('/')}"
          [ key, rest... ] = ypath
        return this unless key?

        match = switch
          when key is '..' then @match key
          else @match '*', key

        return switch
          when rest.length is 0 then match
          else match?.locate rest

      # Looks for a matching Element(s) in immediate sub-elements
      match: (kind, tag) ->
        return unless kind? and @[kind]?
        return @[kind] unless tag?

        match = @[kind]
        match = [ match ] unless match instanceof Array
        return match if tag is '*'

        for elem in match when elem instanceof Element
          key = if elem.tag? then elem.tag else elem.kind
          return elem if tag is key
        return undefined

      error: @error
      debug: (msg) -> switch typeof msg
        when 'object' then debug? msg
        else debug? "[#{@trail}] #{msg}"

### toJSON

Converts the Element into a JS object

      toJSON: (opts={ tag: true, extended: false }) ->
        #@debug "converting #{@kind} toJSON with #{@elements.length}"
        sub =
          @elements
            .filter (x) => opts.extended or x.parent is this
            .reduce ((a,b) ->
              for k, v of b.toJSON()
                if a[k] instanceof Object
                  a[k][kk] = vv for kk, vv of v if v instanceof Object
                else
                  a[k] = v
              return a
            ), {}
        if opts.tag
          "#{@kind}": switch
            when Object.keys(sub).length > 0
              if @tag? then "#{@tag}": sub else sub
            when @tag instanceof Object then "#{@tag}"
            else @tag
        else sub

## Export Element Class

    module.exports = Element
