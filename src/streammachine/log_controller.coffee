_u = require "underscore"
winston = require "winston"
fs = require "fs"
path = require "path"
strftime = require("prettydate").strftime

module.exports = class LogController
    DefaultOptions:
        foo: 'bar'
        
    CustomLevels:
        error:          50
        request:        40
        interaction:    30
        debug:          10
        
    constructor: (config) ->
                            
        transports = []
        
        # -- stdout -- #
        
        if config.stdout
            console.log "adding Console transport"
            transports.push new (winston.transports.Console)
                level:      config.stdout?.level        || "debug"
                colorize:   config.stdout?.colorize     || false
                timestamp:  config.stdout?.timestamp    || false
        
        # -- JSON -- #
        
        if config.json?.file
            # set up JSON logging via Bunyan
            transports.push new (winston.transports.File)
                level:      config.json.level || "interaction"
                timestamp:  true
                filename:   config.json.file
                json:       true
        
        # -- W3C -- #
        
        if config.w3c?.file
            # set up W3C-format logging
            transports.push new LogController.W3CLogger
                level:      config.w3c.level || "request"
                filename:   config.w3c.file
        
        # -- Remote -- #
        
        # create a winston logger for this instance
        @logger = new (winston.Logger) transports:transports, levels:@CustomLevels, rewriters:[@RequestRewriter]
        @logger.extend(@)
        
    #----------
    
    # returns a logger that will automatically merge in the given data
    child: (opts={}) -> new LogController.Child(@,opts)
    
    #----------
    
    RequestRewriter: (level,msg,meta) ->
        if meta?.req
            req = meta.req
            
            meta.req = 
                method:         req.method
                url:            req.url
                headers:        req.headers
                remoteAddress:  req.connection.remoteAddress
                remotePort:     req.connection.remotePort
                        
        meta

    #----------
    
    class @Child
        constructor: (@parent,@opts) ->
            _u(['log', 'profile', 'startTimer'].concat(Object.keys(@parent.logger.levels))).each (k) =>
                @[k] = (args...) => 
                    if _u.isObject(args[args.length-1])
                        args[args.length-1] = _u.extend {}, args[args.length-1], @opts
                    else
                        args.push @opts
                    
                    @parent[k].apply @, args
                    
    #----------
    
    class @W3CLogger extends winston.Transport
        name: "w3c"
        
        constructor: (options) ->
            super(options)
            
            @options = options
            @_opening = false
            
            @queued = []
            
            process.addListener "SIGHUP", =>
                # re-open our log file
                console.log "w3c reloading log file"
                @close()
                @open()
                
        #----------
        
        log: (level,msg,meta,cb) ->
            #console.log "in w3c logger with ", level, msg, meta, cb
            
            # for a valid w3c log, level should == "request", meta.
            logline = "#{meta.ip} #{meta.ip} #{strftime(meta.time,"%F %T")} #{meta.path} 200 #{escape(meta.ua)} #{meta.bytes} #{meta.seconds}\n"
            
            if @file
                # make sure there aren't any queued writes
                unless _u(@queued).isEmpty
                    q = @queued
                    @queued = []
                    @file.write line for line in q
                
                # now write this line
                @file.write logline
                cb null, true
                
            else
                @open (err) =>
                    
                @queued.push logline
                cb null, true
        
        #----------
        
        open: (cb) ->
            if @_opening
                # we're already trying to open.  return an error so we queue the message
                cb?(true)
                return true
            
            # otherwise, open the file
            @_opening = true
                        
            initFile = true
            if path.existsSync @options.filename
                # existing file...  don't write headers, just open so we can 
                # start appending
                initFile = false
                
            @file = fs.createWriteStream @options.filename
            
            @file.once "open", (err) =>   
                console.log "w3c log open with ", err
                if initFile
                    # write our initial w3c lines
                    @file.write "#Software: StreamMachine\n#Version: 0.1.0\n#Fields: c-ip date time cs-uri-stem c-status cs(User-Agent) sc-bytes x-duration\n"

                @once "flush", =>
                    @_opening = false
                    console.log "w3c open complete"
                    cb?(false)
                    
                @flush()
                            
        #----------
            
        close: (cb) ->
            @file?.end()
            @file = null
            
        #----------
        
        flush: ->
            _u(@queued).each (l) => process.nextTick => @file.write(l)
            @queued.length = 0
            console.log "w3c finished flushing"
            @file.once "drain", => @emit "flush"