--
-- Project: wiola
-- User: Konstantin Burkalev
-- Date: 16.03.14
--

require "debug.var_dump"

local _M = {
    _VERSION = '0.5.1',
}

_M.__index = _M

setmetatable(_M, {
    __call = function (cls, ...)
        return cls.new(...)
    end })

local wamp_features = {
    agent = "wiola/Lua v0.5.1",
    roles = {
        broker = {
            features = {
                subscriber_blackwhite_listing = true,
                publisher_exclusion = true,
                publisher_identification = true
            }
        },
        dealer = {
            features = {
                caller_identification = true,
                progressive_call_results = true,
                call_canceling = true,
                call_timeout = true
            }
        }
    }
}

-- Redis connection configuration
local redisConf = {
    host = "unix:/tmp/redis.sock",
    port = nil,
    db = nil
}

-- Wiola Runtime configuration
local wiolaConf = {
    callerIdentification = "auto",   -- auto | never | always
    cookieAuth = {
        authType = "none",          -- none | static | dynamic
        cookieName = "wampauth",
        staticCredentials = nil, --{
            -- "user1", "user2:password2", "secretkey3"
        --},
        authCallback = nil
    },
    wampCRA = {
        authType = "none",          -- none | static | dynamic
        staticCredentials = nil, --{
            -- { authid = "user1", authrole = "userRole1", secret="secret1" },
            -- { authid = "user2", authrole = "userRole2", secret="secret2" }
        --},
        challengeCallback = nil,
        authCallback = nil
    }
}

local WAMP_MSG_SPEC = {
    HELLO = 1,
    WELCOME = 2,
    ABORT = 3,
    CHALLENGE = 4,
    AUTHENTICATE = 5,
    GOODBYE = 6,
    ERROR = 8,
    PUBLISH = 16,
    PUBLISHED = 17,
    SUBSCRIBE = 32,
    SUBSCRIBED = 33,
    UNSUBSCRIBE = 34,
    UNSUBSCRIBED = 35,
    EVENT = 36,
    CALL = 48,
    CANCEL = 49,
    RESULT = 50,
    REGISTER = 64,
    REGISTERED = 65,
    UNREGISTER = 66,
    UNREGISTERED = 67,
    INVOCATION = 68,
    INTERRUPT = 69,
    YIELD = 70
}

--
-- Create a new instance
--
-- returns wiola instance
--
function _M.new()
    local self = setmetatable({}, _M)
    return self
end

-- Generate unique Id
function _M:_getRegId()
    local regId
    local time = self.redis:time()

--    math.randomseed( os.time() ) -- Precision - only seconds, which is not acceptable
    math.randomseed( time[1] * 1000000 + time[2] )

    repeat
--        regId = math.random(9007199254740992)
        regId = math.random(100000000000000)
    until self.redis:sismember("wiolaIds", regId)

    return regId
end

-- Validate uri for WAMP requirements
function _M:_validateURI(uri)
    local m, err = ngx.re.match(uri, "^([0-9a-zA-Z_]{2,}\\.)*([0-9a-zA-Z_]{2,})$")
    ngx.log(ngx.DEBUG, '_validateURI: ', uri, ' ', m == nil, ' ', err)
    if not m or string.find(uri, 'wamp') == 1 then
        return false
    else
        return true
    end
end

--
-- Configure Wiola
--
-- config - Configuration table with possible options:
--          {
--              redis = {
--                  host = string - redis host or unix socket (default: "unix:/tmp/redis.sock"),
--                  port = number - redis port in case of network use (default: nil),
--                  db = number - redis database to select (default: nil)
--              },
--              callerIdentification = string - Disclose caller identification?
--                                              Possible values: auto | never | always. (default: "auto")
--          }
--
function _M:configure(config)
    if config.redis then

        if config.redis.host ~= nil then
            redisConf.host = config.redis.host
        end

        if config.redis.port ~= nil then
            redisConf.port = config.redis.port
        end

        if config.redis.db ~= nil then
            redisConf.db = config.redis.db
        end
    end

    if config.callerIdentification ~= nil then
        wiolaConf.callerIdentification = config.callerIdentification
    end

    if config.cookieAuth then

        if config.cookieAuth.authType ~= nil then
            wiolaConf.cookieAuth.authType = config.cookieAuth.authType
        end

        if config.cookieAuth.cookieName ~= nil then
            wiolaConf.cookieAuth.cookieName = config.cookieAuth.cookieName
        end

        if config.cookieAuth.staticCredentials ~= nil then
            wiolaConf.cookieAuth.staticCredentials = config.cookieAuth.staticCredentials
        end

        if config.cookieAuth.authCallback ~= nil then
            wiolaConf.cookieAuth.authCallback = config.cookieAuth.authCallback
        end
    end

    if config.wampCRA then

        if config.wampCRA.authType ~= nil then
            wiolaConf.wampCRA.authType = config.wampCRA.authType
        end

        if config.wampCRA.staticCredentials ~= nil then
            wiolaConf.wampCRA.staticCredentials = config.wampCRA.staticCredentials
        end

        if config.wampCRA.authCallback ~= nil then
            wiolaConf.wampCRA.authCallback = config.wampCRA.authCallback
        end
    end
end

--
-- Setup Redis connection
--
-- returns connection flag, error description
--
function _M:setupRedis()
    local redisOk, redisErr

    local redisLib = require "resty.redis"
    self.redis = redisLib:new()

    if redisConf.port == nil then
        redisOk, redisErr = self.redis:connect(redisConf.host)
    else
        redisOk, redisErr = self.redis:connect(redisConf.host, redisConf.port)
    end

    if redisOk and redisConf.db ~= nil then
        self.redis:select(redisConf.db)
    end

    return redisOk, redisErr
end

--
-- Add connection to wiola
--
-- sid - nginx session connection ID
-- wampProto - chosen WAMP protocol
--
-- returns WAMP session registration ID, connection data type
--
function _M:addConnection(sid, wampProto)
    local regId = self:_getRegId()
    local wProto, dataType

    self.redis:sadd("wiolaIds",regId)

    if wampProto == nil or wampProto == "" then
        wampProto = 'wamp.2.json'   -- Setting default protocol for encoding/decodig use
    end

    if wampProto == 'wamp.2.msgpack' then
        dataType = 'binary'
    else
        dataType = 'text'
    end

    self.redis:hmset("wiSes" .. regId,
        { connId = sid,
        sessId = regId,
        isWampEstablished = 0,
--        realm = nil,
--        wamp_features = nil,
        wamp_protocol = wampProto,
        dataType = dataType }
    )

    return regId, dataType
end

--
-- Remove connection from wiola
--
-- regId - WAMP session registration ID
--
function _M:removeConnection(regId)
    local session = self.redis:array_to_hash(self.redis:hgetall("wiSes" .. regId))

--    var_dump(session)

    ngx.log(ngx.DEBUG, "Removing session: ", regId)

    local subscriptions = self.redis:array_to_hash(self.redis:hgetall("wiRealm" .. session.realm .. "Subs"))


    for k, v in pairs(subscriptions) do
        self.redis:srem("wiRealm" .. session.realm .. "Sub" .. k .. "Sessions", regId)
        if self.redis:scard("wiRealm" .. session.realm .. "Sub" .. k .. "Sessions") == 0 then
            self.redis:del("wiRealm" .. session.realm .. "Sub" .. k .. "Sessions")
            self.redis:hdel("wiRealm" .. session.realm .. "Subs",k)
            self.redis:hdel("wiRealm" .. session.realm .. "RevSubs",v)
        end
    end

    local rpcs = self.redis:array_to_hash(self.redis:hgetall("wiSes" .. regId .. "RPCs"))

    for k, v in pairs(rpcs) do
        self.redis:srem("wiRealm" .. session.realm .. "RPCs",k)
        self.redis:del("wiRPC" .. k)
    end

    self.redis:del("wiSes" .. regId .. "RPCs")
    self.redis:del("wiSes" .. regId .. "RevRPCs")

    self.redis:srem("wiRealm" .. session.realm .. "Sessions", regId)
    if self.redis:scard("wiRealm" .. session.realm .. "Sessions") == 0 then
        self.redis:srem("wiolaRealms",session.realm)
    end

    self.redis:del("wiSes" .. regId .. "Data")
    self.redis:del("wiSes" .. regId)
    self.redis:srem("wiolaIds",regId)
end

-- Prepare data for sending to client
function _M:_putData(session, data)
    local dataObj

    if session.wamp_protocol == 'wamp.2.msgpack' then
        local mp = require 'MessagePack'
        dataObj = mp.pack(data)
    else --if session.wamp_protocol == 'wamp.2.json'
        local json = require "rapidjson"
        dataObj = json.encode(data)
    end

    ngx.log(ngx.DEBUG, "Preparing data for client: ", dataObj)

    self.redis:rpush("wiSes" .. session.sessId .. "Data", dataObj)
end

-- Publish event to sessions
function _M:_publishEvent(sessIds, subId, pubId, details, args, argsKW)
    -- WAMP SPEC: [EVENT, SUBSCRIBED.Subscription|id, PUBLISHED.Publication|id, Details|dict]
    -- WAMP SPEC: [EVENT, SUBSCRIBED.Subscription|id, PUBLISHED.Publication|id, Details|dict, PUBLISH.Arguments|list]
    -- WAMP SPEC: [EVENT, SUBSCRIBED.Subscription|id, PUBLISHED.Publication|id, Details|dict, PUBLISH.Arguments|list, PUBLISH.ArgumentKw|dict]

    ngx.log(ngx.DEBUG, "Publish events, sessions to notify: ", #sessIds)

    local data
    if not args and not argsKW then
        data = { WAMP_MSG_SPEC.EVENT, subId, pubId, details }
    elseif args and not argsKW then
        data = { WAMP_MSG_SPEC.EVENT, subId, pubId, details, args }
    else
        data = { WAMP_MSG_SPEC.EVENT, subId, pubId, details, args, argsKW }
    end

    for k, v in ipairs(sessIds) do
        local session = self.redis:array_to_hash(self.redis:hgetall("wiSes" .. v))
        self:_putData(session, data)
    end
end

--
-- Receive data from client
--
-- regId - WAMP session registration ID
-- data - data, received through websocket
--
function _M:receiveData(regId, data)
    local session = self.redis:array_to_hash(self.redis:hgetall("wiSes" .. regId))
    session.isWampEstablished = tonumber(session.isWampEstablished)
    local json = require "rapidjson"
    local dataObj

--    var_dump(session)

    if session.wamp_protocol == 'wamp.2.msgpack' then
        local mp = require 'MessagePack'
        dataObj = mp.unpack(data)
    else --if session.wamp_protocol == 'wamp.2.json'
        dataObj = json.decode(data)
    end

--    var_dump(dataObj)

    ngx.log(ngx.DEBUG, "Cli regId: ", regId, " Received data. WAMP msg Id: ", dataObj[1])

    -- Analyze WAMP message ID received
    if dataObj[1] == WAMP_MSG_SPEC.HELLO then   -- WAMP SPEC: [HELLO, Realm|uri, Details|dict]
        if session.isWampEstablished == 1 then
            -- Protocol error: received second hello message - aborting
            -- WAMP SPEC: [GOODBYE, Details|dict, Reason|uri]
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        else
            local realm = dataObj[2]
            if self:_validateURI(realm) then
                session.isWampEstablished = 1
                session.realm = realm
                session.wampFeatures = json.encode(dataObj[3])
                self.redis:hmset("wiSes" .. regId, session)

                if self.redis:sismember("wiolaRealms",realm) == 0 then
                    ngx.log(ngx.DEBUG, "No realm ", realm, " found. Creating...")
                    self.redis:sadd("wiolaRealms",realm)
                end

                self.redis:sadd("wiRealm" .. realm .. "Sessions", regId)

                -- WAMP SPEC: [WELCOME, Session|id, Details|dict]
                self:_putData(session, { WAMP_MSG_SPEC.WELCOME, regId, wamp_features })
            else
                -- WAMP SPEC: [ABORT, Details|dict, Reason|uri]
                self:_putData(session, { WAMP_MSG_SPEC.ABORT, setmetatable({}, { __jsontype = 'object' }), "wamp.error.invalid_uri" })
            end
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.ABORT then   -- WAMP SPEC: [ABORT, Details|dict, Reason|uri]
        -- No response is expected
    elseif dataObj[1] == WAMP_MSG_SPEC.GOODBYE then   -- WAMP SPEC: [GOODBYE, Details|dict, Reason|uri]
        if session.isWampEstablished == 1 then
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.goodbye_and_out" })
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.ERROR then
        -- WAMP SPEC: [ERROR, REQUEST.Type|int, REQUEST.Request|id, Details|dict, Error|uri]
        -- WAMP SPEC: [ERROR, REQUEST.Type|int, REQUEST.Request|id, Details|dict, Error|uri, Arguments|list]
        -- WAMP SPEC: [ERROR, REQUEST.Type|int, REQUEST.Request|id, Details|dict, Error|uri, Arguments|list, ArgumentsKw|dict]
        if session.isWampEstablished == 1 then
            if dataObj[2] == WAMP_MSG_SPEC.INVOCATION then
                -- WAMP SPEC: [ERROR, INVOCATION, INVOCATION.Request|id, Details|dict, Error|uri]
                -- WAMP SPEC: [ERROR, INVOCATION, INVOCATION.Request|id, Details|dict, Error|uri, Arguments|list]
                -- WAMP SPEC: [ERROR, INVOCATION, INVOCATION.Request|id, Details|dict, Error|uri, Arguments|list, ArgumentsKw|dict]

                local invoc = self.redis:array_to_hash(self.redis:hgetall("wiInvoc" .. dataObj[3]))
                local callerSess = self.redis:array_to_hash(self.redis:hgetall("wiSes" .. invoc.callerSesId))
                invoc.CallReqId = tonumber(invoc.CallReqId)

                if #dataObj == 6 then
                    -- WAMP SPEC: [ERROR, CALL, CALL.Request|id, Details|dict, Error|uri, Arguments|list]
                    self:_putData(callerSess, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.CALL, invoc.CallReqId, setmetatable({}, { __jsontype = 'object' }), dataObj[5], dataObj[6] })
                elseif #dataObj == 7 then
                    -- WAMP SPEC: [ERROR, CALL, CALL.Request|id, Details|dict, Error|uri, Arguments|list, ArgumentsKw|dict]
                    self:_putData(callerSess, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.CALL, invoc.CallReqId, setmetatable({}, { __jsontype = 'object' }), dataObj[5], dataObj[6], dataObj[7] })
                else
                    -- WAMP SPEC: [ERROR, CALL, CALL.Request|id, Details|dict, Error|uri]
                    self:_putData(callerSess, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.CALL, invoc.CallReqId, setmetatable({}, { __jsontype = 'object' }), dataObj[5] })
                end

                self.redis:del("wiInvoc" .. dataObj[3])
            end
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.PUBLISH then
        -- WAMP SPEC: [PUBLISH, Request|id, Options|dict, Topic|uri]
        -- WAMP SPEC: [PUBLISH, Request|id, Options|dict, Topic|uri, Arguments|list]
        -- WAMP SPEC: [PUBLISH, Request|id, Options|dict, Topic|uri, Arguments|list, ArgumentsKw|dict]
        if session.isWampEstablished == 1 then
            if self:_validateURI(dataObj[4]) then
                local pubId = self:_getRegId()
                local ss = {}
                local tmpK = "wiSes" .. regId .. "TmpSetK"
                local tmpL = "wiSes" .. regId .. "TmpSetL"

                self.redis:sdiffstore(tmpK, "wiRealm" .. session.realm .. "Sub" .. dataObj[4] .. "Sessions")

                if dataObj[3].eligible then -- There is eligible list
                    ngx.log(ngx.DEBUG, "PUBLISH: There is eligible list")
                    for k, v in ipairs(dataObj[3].eligible) do
                        self.redis:sadd(tmpL, v)
                    end

                    self.redis:sinterstore(tmpK, tmpK, tmpL)
                    self.redis:del(tmpL)
                end

                if dataObj[3].eligible_authid then -- There is eligible authid list
                    ngx.log(ngx.DEBUG, "PUBLISH: There is eligible authid list")

                    for k, v in ipairs(self.redis:smembers(tmpK)) do
                        local s = self.redis:array_to_hash(self.redis:hgetall("wiSes" .. v))

                        for i=1, #dataObj[3].eligible_authid do
                            if s.wampFeatures.authid == dataObj[3].eligible_authid[i] then
                                self.redis:sadd(tmpL, s.sessId)
                            end
                        end
                    end

                    self.redis:sinterstore(tmpK, tmpK, tmpL)
                    self.redis:del(tmpL)
                end

                if dataObj[3].eligible_authrole then -- There is eligible authrole list
                    ngx.log(ngx.DEBUG, "PUBLISH: There is eligible authrole list")

                    for k, v in ipairs(self.redis:smembers(tmpK)) do
                        local s = self.redis:array_to_hash(self.redis:hgetall("wiSes" .. v))

                        for i=1, #dataObj[3].eligible_authrole do
                            if s.wampFeatures.authrole == dataObj[3].eligible_authrole[i] then
                                self.redis:sadd(tmpL, s.sessId)
                            end
                        end
                    end

                    self.redis:sinterstore(tmpK, tmpK, tmpL)
                    self.redis:del(tmpL)
                end

                if dataObj[3].exclude then -- There is exclude list
                    ngx.log(ngx.DEBUG, "PUBLISH: There is exclude list")
                    for k, v in ipairs(dataObj[3].exclude) do
                        self.redis:sadd(tmpL, v)
                    end

                    self.redis:sdiffstore(tmpK, tmpK, tmpL)
                    self.redis:del(tmpL)
                end

                if dataObj[3].exclude_authid then -- There is exclude authid list
                    ngx.log(ngx.DEBUG, "PUBLISH: There is exclude authid list")

                    for k, v in ipairs(self.redis:smembers(tmpK)) do
                        local s = self.redis:array_to_hash(self.redis:hgetall("wiSes" .. v))

                        for i=1, #dataObj[3].exclude_authid do
                            if s.wampFeatures.authid == dataObj[3].exclude_authid[i] then
                                self.redis:sadd(tmpL, s.sessId)
                            end
                        end
                    end

                    self.redis:sdiffstore(tmpK, tmpK, tmpL)
                    self.redis:del(tmpL)
                end

                if dataObj[3].exclude_authrole then -- There is exclude authrole list
                    ngx.log(ngx.DEBUG, "PUBLISH: There is exclude authrole list")

                    for k, v in ipairs(self.redis:smembers(tmpK)) do
                        local s = self.redis:array_to_hash(self.redis:hgetall("wiSes" .. v))

                        for i=1, #dataObj[3].exclude_authrole do
                            if s.wampFeatures.authrole == dataObj[3].exclude_authrole[i] then
                                self.redis:sadd(tmpL, s.sessId)
                            end
                        end
                    end

                    self.redis:sdiffstore(tmpK, tmpK, tmpL)
                    self.redis:del(tmpL)
                end

                if dataObj[3].exclude_me == nil or dataObj[3].exclude_me == true then
                    self.redis:sadd(tmpL, regId)
                    self.redis:sdiffstore(tmpK, tmpK, tmpL)
                    self.redis:del(tmpL)
                end

                ss = self.redis:smembers(tmpK)
                self.redis:del(tmpK)

                local details = {}

                if dataObj[3].disclose_me ~= nil and dataObj[3].disclose_me == true then
                    details.publisher = regId
                end

                local subId = tonumber(self.redis:hget("wiRealm" .. session.realm .. "Subs", dataObj[4]))
                if subId then
                    self:_publishEvent(ss, subId, pubId, details, dataObj[5], dataObj[6])

                    if dataObj[3].acknowledge and dataObj[3].acknowledge == true then
                        -- WAMP SPEC: [PUBLISHED, PUBLISH.Request|id, Publication|id]
                        self:_putData(session, { WAMP_MSG_SPEC.PUBLISHED, dataObj[2], pubId })
                    end
                end
            else
                self:_putData(session, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.PUBLISH, dataObj[2], setmetatable({}, { __jsontype = 'object' }), "wamp.error.invalid_uri" })
            end
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.SUBSCRIBE then   -- WAMP SPEC: [SUBSCRIBE, Request|id, Options|dict, Topic|uri]
        if session.isWampEstablished == 1 then
            if self:_validateURI(dataObj[4]) then
                local subscriptionId = tonumber(self.redis:hget("wiRealm" .. session.realm .. "Subs", dataObj[4]))

                if not subscriptionId then
                    subscriptionId = self:_getRegId()
                    self.redis:hset("wiRealm" .. session.realm .. "Subs", dataObj[4], subscriptionId)
                    self.redis:hset("wiRealm" .. session.realm .. "RevSubs", subscriptionId, dataObj[4])
                end

                ngx.log(ngx.DEBUG, "SUBSCRIBE: subscriptionId: ", subscriptionId)
                self.redis:sadd("wiRealm" .. session.realm .. "Sub" .. dataObj[4] .. "Sessions",regId)

                -- WAMP SPEC: [SUBSCRIBED, SUBSCRIBE.Request|id, Subscription|id]
                self:_putData(session, { WAMP_MSG_SPEC.SUBSCRIBED, dataObj[2], subscriptionId })
            else
                self:_putData(session, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.SUBSCRIBE, dataObj[2], setmetatable({}, { __jsontype = 'object' }), "wamp.error.invalid_uri" })
            end
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.UNSUBSCRIBE then   -- WAMP SPEC: [UNSUBSCRIBE, Request|id, SUBSCRIBED.Subscription|id]
        if session.isWampEstablished == 1 then
            local subscr = self.redis:hget("wiRealm" .. session.realm .. "RevSubs", dataObj[3])
            local isSesSubscrbd = self.redis:sismember("wiRealm" .. session.realm .. "Sub" .. subscr .. "Sessions", regId)
            if isSesSubscrbd ~= ngx.null then
                self.redis:srem("wiRealm" .. session.realm .. "Sub" .. subscr .. "Sessions", regId)
                if self.redis:scard("wiRealm" .. session.realm .. "Sub" .. subscr .. "Sessions") == 0 then
                    self.redis:del("wiRealm" .. session.realm .. "Sub" .. subscr .. "Sessions")
                    self.redis:hdel("wiRealm" .. session.realm .. "Subs",subscr)
                    self.redis:hdel("wiRealm" .. session.realm .. "RevSubs",dataObj[3])
                end

                -- WAMP SPEC: [UNSUBSCRIBED, UNSUBSCRIBE.Request|id]
                self:_putData(session, { WAMP_MSG_SPEC.UNSUBSCRIBED, dataObj[2] })
            else
                self:_putData(session, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.UNSUBSCRIBE, dataObj[2], setmetatable({}, { __jsontype = 'object' }), "wamp.error.no_such_subscription" })
            end
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.CALL then
        -- WAMP SPEC: [CALL, Request|id, Options|dict, Procedure|uri]
        -- WAMP SPEC: [CALL, Request|id, Options|dict, Procedure|uri, Arguments|list]
        -- WAMP SPEC: [CALL, Request|id, Options|dict, Procedure|uri, Arguments|list, ArgumentsKw|dict]
        if session.isWampEstablished == 1 then
            if self:_validateURI(dataObj[4]) then
                if self.redis:sismember("wiRealm" .. session.realm .. "RPCs", dataObj[4]) == 0 then
                    -- WAMP SPEC: [ERROR, CALL, CALL.Request|id, Details|dict, Error|uri]
                    self:_putData(session, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.CALL, dataObj[2], setmetatable({}, { __jsontype = 'object' }), "wamp.error.no_suitable_callee" })
                else
                    local regInfo = self.redis:array_to_hash(self.redis:hgetall("wiRPC" .. dataObj[4]))
                    local callee = tonumber(regInfo.calleeSesId)
                    local tmpK = "wiSes" .. regId .. "TmpSet"

                    local details = setmetatable({}, { __jsontype = 'object' })

                    if wiolaConf.callerIdentification == "always" or
                       (wiolaConf.callerIdentification == "auto" and
                       ((dataObj[3].disclose_me ~= nil and dataObj[3].disclose_me == true) or
                        (regInfo.disclose_caller == true))) then
                        details.caller = regId
                    end

                    if dataObj[3].receive_progress ~= nil and dataObj[3].receive_progress == true then
                        details.receive_progress = true
                    end

                    local calleeSess = self.redis:array_to_hash(self.redis:hgetall("wiSes" .. callee))
                    local rpcRegId = tonumber(self.redis:hget("wiSes" .. callee .. "RPCs", dataObj[4]))
                    local invReqId = self:_getRegId()

                    if dataObj[3].timeout ~= nil and
                       dataObj[3].timeout > 0 and
                       calleeSess.wampFeatures.callee.features.call_timeout == true and
                       calleeSess.wampFeatures.callee.features.call_canceling == true then

                        -- Caller specified Timeout for CALL processing and callee support this feature
                        local function callCancel(premature, calleeSess, invReqId)

                            local details = setmetatable({}, { __jsontype = 'object' })

                            -- WAMP SPEC: [INTERRUPT, INVOCATION.Request|id, Options|dict]
                            self:_putData(calleeSess, { WAMP_MSG_SPEC.INTERRUPT, invReqId, details })
                        end

                        local ok, err = ngx.timer.at(dataObj[3].timeout, callCancel, calleeSess, invReqId)

                        if not ok then
                            ngx.log(ngx.ERR, "failed to create timer: ", err)
                        end
                    end

                    self.redis:hmset("wiInvoc" .. invReqId, "CallReqId", dataObj[2], "callerSesId", regId)
                    self.redis:hmset("wiCall" .. dataObj[2], "callerSesId", session.sessId, "calleeSesId", calleeSess.sessId, "wiInvocId", invReqId)

                    if #dataObj == 5 then
                        -- WAMP SPEC: [INVOCATION, Request|id, REGISTERED.Registration|id, Details|dict, CALL.Arguments|list]
                        self:_putData(calleeSess, { WAMP_MSG_SPEC.INVOCATION, invReqId, rpcRegId, details, dataObj[5] })
                    elseif #dataObj == 6 then
                        -- WAMP SPEC: [INVOCATION, Request|id, REGISTERED.Registration|id, Details|dict, CALL.Arguments|list, CALL.ArgumentsKw|dict]
                        self:_putData(calleeSess, { WAMP_MSG_SPEC.INVOCATION, invReqId, rpcRegId, details, dataObj[5], dataObj[6] })
                    else
                        -- WAMP SPEC: [INVOCATION, Request|id, REGISTERED.Registration|id, Details|dict]
                        self:_putData(calleeSess, { WAMP_MSG_SPEC.INVOCATION, invReqId, rpcRegId, details })
                    end
                end
            else
                self:_putData(session, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.CALL, dataObj[2], setmetatable({}, { __jsontype = 'object' }), "wamp.error.invalid_uri" })
            end
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.REGISTER then   -- WAMP SPEC: [REGISTER, Request|id, Options|dict, Procedure|uri]
        if session.isWampEstablished == 1 then
            if self:_validateURI(dataObj[4]) then
                if self.redis:sismember("wiRealm" .. session.realm .. "RPCs", dataObj[4]) == 1 then
                    self:_putData(session, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.REGISTER, dataObj[2], setmetatable({}, { __jsontype = 'object' }), "wamp.error.procedure_already_exists" })
                else
                    local registrationId = self:_getRegId()

                    self.redis:sadd("wiRealm" .. session.realm .. "RPCs", dataObj[4])
                    self.redis:hmset("wiRPC" .. dataObj[4], "calleeSesId", regId)
                    if dataObj[3].disclose_caller ~= nil and dataObj[3].disclose_caller == true then
                        self.redis:hmset("wiRPC" .. dataObj[4], "disclose_caller", true)
                    end
                    self.redis:hset("wiSes" .. regId .. "RPCs", dataObj[4], registrationId)
                    self.redis:hset("wiSes" .. regId .. "RevRPCs", registrationId, dataObj[4])

                    -- WAMP SPEC: [REGISTERED, REGISTER.Request|id, Registration|id]
                    self:_putData(session, { WAMP_MSG_SPEC.REGISTERED, dataObj[2], registrationId })
                end
            else
                self:_putData(session, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.REGISTER, dataObj[2], setmetatable({}, { __jsontype = 'object' }), "wamp.error.invalid_uri" })
            end
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.UNREGISTER then   -- WAMP SPEC: [UNREGISTER, Request|id, REGISTERED.Registration|id]
        if session.isWampEstablished == 1 then
            local rpc = self.redis:hget("wiSes" .. regId .. "RevRPCs", dataObj[3])
            if rpc ~= ngx.null then
                self.redis:hdel("wiSes" .. regId .. "RPCs", rpc)
                self.redis:hdel("wiSes" .. regId .. "RevRPCs", dataObj[3])
                self.redis:del("wiRPC" .. rpc)
                self.redis:srem("wiRealm" .. session.realm .. "RPCs",rpc)

                -- WAMP SPEC: [UNREGISTERED, UNREGISTER.Request|id]
                self:_putData(session, { WAMP_MSG_SPEC.UNREGISTERED, dataObj[2] })
            else
                self:_putData(session, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.UNREGISTER, dataObj[2], setmetatable({}, { __jsontype = 'object' }), "wamp.error.no_such_registration" })
            end
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.YIELD then
        -- WAMP SPEC: [YIELD, INVOCATION.Request|id, Options|dict]
        -- WAMP SPEC: [YIELD, INVOCATION.Request|id, Options|dict, Arguments|list]
        -- WAMP SPEC: [YIELD, INVOCATION.Request|id, Options|dict, Arguments|list, ArgumentsKw|dict]
        if session.isWampEstablished == 1 then
            local invoc = self.redis:array_to_hash(self.redis:hgetall("wiInvoc" .. dataObj[2]))
            invoc.CallReqId = tonumber(invoc.CallReqId)
            local callerSess = self.redis:array_to_hash(self.redis:hgetall("wiSes" .. invoc.callerSesId))

            local details = setmetatable({}, { __jsontype = 'object' })

            if dataObj[3].progress ~= nil and dataObj[3].progress == true then
                details.progress = true
            else
                self.redis:del("wiInvoc" .. dataObj[2])
                self.redis:del("wiCall" .. invoc.CallReqId)
            end

            if #dataObj == 4 then
                -- WAMP SPEC: [RESULT, CALL.Request|id, Details|dict, YIELD.Arguments|list]
                self:_putData(callerSess, { WAMP_MSG_SPEC.RESULT, invoc.CallReqId, details, dataObj[4] })
            elseif #dataObj == 5 then
                -- WAMP SPEC: [RESULT, CALL.Request|id, Details|dict, YIELD.Arguments|list, YIELD.ArgumentsKw|dict]
                self:_putData(callerSess, { WAMP_MSG_SPEC.RESULT, invoc.CallReqId, details, dataObj[4], dataObj[5] })
            else
                -- WAMP SPEC: [RESULT, CALL.Request|id, Details|dict]
                self:_putData(callerSess, { WAMP_MSG_SPEC.RESULT, invoc.CallReqId, details })
            end
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.CANCEL then
        -- WAMP SPEC: [CANCEL, CALL.Request|id, Options|dict]
        if session.isWampEstablished == 1 then

            local wiCall = self.redis:array_to_hash(self.redis:hgetall("wiCall" .. dataObj[2]))
            wiCall.calleeSesId = tonumber(wiCall.calleeSesId)
            local calleeSess = self.redis:array_to_hash(self.redis:hgetall("wiSes" .. wiCall.calleeSesId))

            if calleeSess.wampFeatures.callee.features.call_canceling == true then
                local details = setmetatable({}, { __jsontype = 'object' })

                if dataObj[3].mode ~= nil then
                    details.mode = dataObj[3].mode
                end

                -- WAMP SPEC: [INTERRUPT, INVOCATION.Request|id, Options|dict]
                self:_putData(calleeSess, { WAMP_MSG_SPEC.INTERRUPT, wiCall.wiInvocId, details })
            end
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    else

    end
end

--
-- Retrieve data, available for session
--
-- regId - WAMP session registration ID
--
-- returns first WAMP message from the session data queue
--
function _M:getPendingData(regId)
    return self.redis:lpop("wiSes" .. regId .. "Data")
end

--
-- Process lightweight publish POST data from client
--
-- sid - nginx session connection ID
-- realm - WAMP Realm to operate in
-- data - data, received through POST
--
function _M:processPostData(sid, realm, data)

    ngx.log(ngx.DEBUG, "Received POST data for processing in realm ", realm, ":", data)

    local json = require "rapidjson"
    local dataObj = json.decode(data)
    local res
    local httpCode

    if dataObj[1] == WAMP_MSG_SPEC.PUBLISH then
        local regId, dataType = self.addConnection(sid, nil)

        -- Make a session legal :)
        self.redis:hset("wiSes" .. regId, "isWampEstablished", 1)
        self.redis:hset("wiSes" .. regId, "realm", realm)

        self.receiveData(regId, data)

        local cliData, cliErr = self.getPendingData(regId)
        if cliData ~= ngx.null then
            res = cliData
            httpCode = ngx.HTTP_FORBIDDEN
        else
            res = json.encode({ result = true, error = nil })
            httpCode = ngx.HTTP_OK
        end

        self.removeConnection(regId)
    else
        res = json.encode({ result = false, error = "Message type not supported" })
        httpCode = ngx.HTTP_FORBIDDEN
    end

    return res, httpCode
end

return _M
