// Squirrel class to interface with the Conctr platform (http://conctr.com)

// Copyright (c) 2016 Mystic Pants Pty Ltd
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT

const CONCTR_MIN_RECONNECT_TIME = 5;

class Conctr {

    static VERSION = "1.3.0";

    // change these to consts, name them in a namespace
    static DATA_EVENT = "conctr_data";
    static LOCATION_REQ = "conctr_get_location";
    static AGENT_OPTS = "conctr_agent_options";
    static SOURCE_DEVICE = "impdevice";
    static SOURCE_AGENT = "impagent";
    static AMQP = "amqp";
    static MQTT = "mqtt";
    static MIN_TIME = 946684801; // Epoch timestamp for 00:01 AM 01/01/2000 (used for timestamp sanity check)
    static DEFAULT_LOC_INTERVAL = 3600; // One hour in seconds    
    static STREAM_TERMINATOR = "\r\n";
    static LOCAL_MODE = true;


    _api_key = null;
    _app_id = null;
    _device_id = null;
    _region = null;
    _env = null;
    _model = null;
    _rocky = null;
    _dataApiEndpoint = null;
    _pubSubEndpoints = null;

    // AMQP/MQTT vars
    _protocol = null;
    _msgQueue = null;

    // Location recording options
    _locationRecording = true;
    _locationSent = false;
    _locationTimeout = 0;
    _sendLocInterval = 0;
    _sendLocOnce = false;
    _pollingReq = null;

    _DEBUG = false;
    _LOCAL_FORWARDING = false;


    /**
     * @param  {String}  appId       Conctr application identifier
     * @param  {String}  apiKey      Application specific api key from Conctr
     * @param  {String}  model_ref   Model reference used to validate data payloads by Conctr, including the version number
     * @param  {Object}  rocky       Model reference used to validate data payloads by Conctr, including the version number
     * @param  {Table}   opts        Optional config parameters:-
     * {
     *   {Boolean} useAgentId  Flag on whether to use agent id or device id as identifier to Conctr (defaults to false)
     *   {String}  region      Which region is application in (defaults to "us-west-2")
     *   {String}  env         What Conctr environment should be used(defaults to "staging")}
     * }
     */

    constructor(appId, apiKey, model_ref, rocky, opts = {}) {


        assert(typeof appId == "string");
        assert(typeof apiKey == "string");

        _app_id = appId;
        _api_key = (apiKey.find("api:") == null) ? "api:" + apiKey : apiKey;
        _model = model_ref;
        _region = ("region" in opts) ? opts.region : "us-west-2";
        _env = ("env" in opts) ? opts.env : "staging";
        _device_id = ("useAgentId" in opts && opts.useAgentId == true) ? split(http.agenturl(), "/").pop() : imp.configparams.deviceid;
        _rocky = rocky;
        _protocol = ("protocol" in opts && opts.protocol == AMQP) ? opts.protocol : "mqtt";


        // Setup the endpoint url
        _dataApiEndpoint = _formDataEndpointUrl(_app_id, _device_id, _region, _env);
        _pubSubEndpoints = _formPubSubEndpointUrls(_app_id, _api_key, _device_id, _region, _env);

        // Set to location to defaults
        _setLocationOpts();

        // Set up agent endpoints
        _setupAgentApi(_rocky);

        // Set up msg queue
        _msgQueue = [];

        // Tell comet this to get rid of any old instances
        // Temporary workaround for an imp bug
        // publish(imp.configparams.deviceid, "", "text/dummy");
        publishToDevice(imp.configparams.deviceid, "", "text/dummy");
        // Set up listeners for device events
        device.on(DATA_EVENT, sendData.bindenv(this));
        device.on(AGENT_OPTS, _setLocationOpts.bindenv(this));

    }

    /**
     * Set device unique identifier
     * 
     * @param {String} deviceId - Unique identifier for associated device. (Defaults to imp device id)
     */
    function setDeviceId(deviceId = null) {
        _device_id = (deviceId == null) ? imp.configparams.deviceid : deviceId;
        _dataApiEndpoint = _formDataEndpointUrl(_app_id, _device_id, _region, _env);
    }


    /**
     * Sends data for persistance to Conctr
     *
     * @param  {Table or Array} payload - Table or Array containing data to be persisted
     * @param  {Function (err,response)} callback - Callback function on http resp from Conctr
     * @return {Null}
     * @throws {Exception} -
     */
    function sendData(payload, callback = null) {

        // If it's a table, make it an array
        if (typeof payload == "table") {
            payload = [payload];
        }

        // Capture all the data ids in an array
        local ids = [];
        local getLocation = true;

        if (typeof payload == "array") {

            // It's an array of tables
            foreach (k, v in payload) {
                if (typeof v != "table") {
                    throw "Conctr: Payload must contain a table or an array of tables";
                }

                if (!("_source" in v)) {
                    v._source <- SOURCE_AGENT;
                }

                // Set the model
                v._model <- _model;

                local shortTime = false;

                if (("_ts" in v) && (typeof v._ts == "integer")) {

                    // Invalid numerical timestamp? Replace it.
                    if (v._ts < MIN_TIME) {
                        shortTime = true;
                    }
                } else if (("_ts" in v) && (typeof v._ts == "string")) {

                    local isNumRegex = regexp("^[0-9]*$");

                    // check whether ts is a string of numbers only
                    local isNumerical = (isNumRegex.capture(v._ts) != null);

                    if (isNumerical == true) {
                        // Invalid string timestamp? Replace it.
                        if (v._ts.len() <= 10 && v._ts.tointeger() < MIN_TIME) {
                            shortTime = true;
                        } else if (v._ts.len() > 10 && v._ts.tointeger() / 1000 < MIN_TIME) {
                            shortTime = true;
                        }
                    }
                } else {
                    // No timestamp? Add it now.
                    v._ts <- time();
                }

                if (shortTime) {
                    server.log("Conctr: Warning _ts must be after 1st Jan 2000. Setting to imps time() function.")
                    v._ts <- time();
                }

                if ("_location" in v) {

                    // We have a location, we don't need another one
                    getLocation = false;

                    if (!_locationSent) {
                        // If we have a new location the don't request another one unti the timeout
                        _locationSent = true;
                        _locationTimeout = time() + _sendLocInterval;
                    }

                }

                // Store the ids
                if ("_id" in v) {
                    ids.push(v._id);
                    delete v._id;
                }

            }

            // Send data to Conctr
            _postToConctr(payload, _dataApiEndpoint, ids, callback);

            // Request the location
            if (getLocation) _getLocation();

        } else {
            // This is not valid input
            throw "Conctr: Payload must contain a table or an array of tables";
        }

    }

    /**
     * Sets the protocall that should be used 
     * 
     * @param   {String}    protocol Either amqp or mqtt
     * @return  {String}    current protocal after change
     */
    function setProtocol(protocol) {
        if (protocol == AMQP || protocol == MQTT) {
            _protocol = protocol;
        } else {
            server.error(protocol + " is not a valid protocol.");
        }
        _pubSubEndpoints = _formPubSubEndpointUrls(_app_id, _api_key, _device_id, _region, _env);
        return _protocol
    }

    // TODO: Include in docs : if content type is not provided the msg will be json encoded everytime. 
    // or if anything other than a string is passed we will json enc.
    /**
     * Publishes a message to a specific topic.
     * @param  {String}   topic       Topic name that message should be sent to
     * @param  {[type]}   msg         Data to be sent to be published
     * @param  {[type]}   contentType Header specifying the content type of the msg
     * @param  {Function} cb          Function called on completion of publish request
     */
    function publish(topic, msg, contentType = null, cb = null) {
        local relativeUrl = "/" + topic;
        _publish(relativeUrl, msg, contentType, cb);

    }

    /**
     * Publishes a message to a specific device.
     * @param  {String}   deviceId    Device id the message should be sent to
     * @param  {[type]}   msg         Data to be sent to be published
     * @param  {[type]}   contentType Header specifying the content type of the msg
     * @param  {Function} cb          Function called on completion of publish request
     */
    // TODO: Expiration
    function publishToDevice(deviceId, msg, contentType = null, cb = null) {
        local relativeUrl = "/dev/" + deviceId;
        _publish(relativeUrl, msg, contentType, cb);
    }

    /**
     * Publishes a message to a specific service.
     * @param  {String}   serviceName   Service that message should be sent to
     * @param  {[type]}   msg           Data to be sent to be published
     * @param  {[type]}   contentType   Header specifying the content type of the msg
     * @param  {Function} cb            Function called on completion of publish request
     */
    function publishToService(serviceName, msg, contentType = null, cb = null) {
        local relativeUrl = "/sys/" + serviceName;
        _publish(relativeUrl, msg, contentType, cb);
    }


    /**
     * Subscribe to a single/list of topics
     * @param  {Function}       cb     Function called on receipt of data
     * @param  {Array/String}   topics String or Array of string topic names to subscribe to
     */
    // TODO fix the optional callback and topic. i.e. cb should not be optional
    function subscribe(topics = [], cb = null) {

        if (typeof topics == "function") {
            cb = topics;
            topics = [];
        }
        if (typeof topics != "array") {
            topics = [topics];
        }

        local action = "subscribe";
        local headers = {};
        local payload = {};
        local chunks = "";
        local contentLength = null;
        local reqTime = time();

        // http done callback
        local _doneCb = function(resp) {
            // We dont allow non chunked requests. So if we recieve a message in this func
            // it is the last message of the steam and may contain the last chunk
            if (resp.body == null && resp.body == "") {
                _streamCb(resp.body);
            }

            local wakeupTime = 0;
            local reconnect = function() {
                subscribe(topics, cb);
            }

            if (resp.statuscode >= 200 && resp.statuscode <= 300) {
                // wake up time is 0
            } else if (resp.statuscode == 429) {
                wakeupTime = 1;
            } else {
                local conTime = time() - reqTime;
                if (conTime < CONCTR_MIN_RECONNECT_TIME) {
                    wakeupTime = CONCTR_MIN_RECONNECT_TIME - conTime;
                }
            }
            // Reconnect in a bit or now based on disconnection reason
            imp.wakeup(wakeupTime, reconnect.bindenv(this));
        };

        // Http streaming callback
        local _streamCb = function(chunk) {
            server.log("got chunk " + chunk);
            // User called unsubscribe. Close connection.
            if (_pollingReq == null) return;

            // accumulate chuncks till we get a full msg
            chunks += chunk;

            // Check whether we have received the content length yet (sent as first line of msg)
            if (contentLength == null) {
                // Sweet, we want to extract it out, itll be
                // chilling just before the /r/n lets find it
                local eos = chunks.find(STREAM_TERMINATOR);
                // Got it! 
                if (eos != null) {
                    // Pull it out
                    contentLength = chunks.slice(0, eos);
                    contentLength = contentLength.tointeger();

                    // Leave the rest of the msg
                    chunks = chunks.slice(eos + STREAM_TERMINATOR.len());
                }
                // We have recieved the full content lets be process!
            }

            if (contentLength != null && chunks.len() >= contentLength) {
                // Got a full msg, process it!
                _processData(chunks.slice(0, contentLength), cb);

                // Get any partial chunks if any and keep waiting for the end of new message
                chunks = chunks.slice(contentLength + STREAM_TERMINATOR.len());
                contentLength = null;
            }
        }

        headers["Content-Type"] <- "application/json";
        headers["Connection"] <- "keep-alive";
        headers["Transfer-encoding"] <- "chunked";
        payload["topics"] <- topics;

        // Check there isnt a current connection, close it if there is.
        if (_pollingReq) _pollingReq.cancel();

        _pollingReq = http.post(_pubSubEndpoints[action] + "/" + _device_id, headers, http.jsonencode(payload));

        // Call callback directly when not chucked response, handle chuncking in second arg to sendAsync
        _pollingReq.sendasync(_doneCb.bindenv(this), _streamCb.bindenv(this));
    }


    /**
     * Unsubscribe to a single/list of topics
     */
    // TODO boolean flag to specify whether to unsubscribe from topics as well or just close connection.
    function unsubscribe() {
        if (_pollingReq) _pollingReq.cancel();
        _pollingReq = null;
    }

    /**
     * Publishes a message to the correct url.
     * @param  {String}   relativeUrl   relative url that the message should be posted to
     * @param  {[type]}   msg           Data to be sent to be published
     * @param  {[type]}   contentType   Header specifying the content type of the msg
     * @param  {Function} cb            Function called on completion of publish request
     */
    // TODO handle non responsive http requests, using wakeup timers when there are multiple pending requests will
    // cause the agent to fail. Look for a http retry class
    function _publish(relativeUrl, msg, contentType = null, cb = null) {
        local action = "publish";
        local headers = {};
        local reqTime = time();

        if (typeof contentType == "function") {
            cb = contentType;
            contentType = null;
        }

        if (contentType == null || typeof msg != "string") {
            msg = http.jsonencode(msg);
            contentType = "application/json";
        }

        headers["Content-Type"] <- contentType;

        local request = http.post(_pubSubEndpoints[action] + relativeUrl, headers, msg);
        request.sendasync(function(resp) {
            local wakeupTime = 0;
            if (resp.statuscode >= 200 && resp.statuscode <= 300) {
                if (cb) cb(response);
            } else if (resp.statuscode == 429) {
                wakeupTime = 1;
            } else {
                local conTime = time() - reqTime;
                if (conTime < CONCTR_MIN_RECONNECT_TIME) {
                    wakeupTime = CONCTR_MIN_RECONNECT_TIME - conTime;
                }
            }
            // TODO finish the queuing system
            if (wakeupTime) {
                _retry(wakeupTime, function() {
                    _publish(relativeUrl, msg, contentType, cb);
                }.bindenv(this))
            }


        }.bindenv(this))
    }
    // TODO finish the queuing system
    function _retry(wakeupTime, func) {
        _msgQueue.push({ "wakeupTime": wakeupTime, "cb": func });
    }


    /**
     * Processes a chunk of data received via poll
     * @param  {String}   chunks String chunk of data recieved from polling request
     * @param  {Function} cb     callback to call if a full message was found within chunk
     */
    function _processData(chunks, cb) {
        local response = _decode(chunks);
        if (response.headers["content-type"] != "text/dummy") {
            imp.wakeup(0, function() {
                cb(response);
            }.bindenv(this));
        } else {
            server.log("Recieved the dummy message");
        }
        return;
    }


    /**
     * Takes an encoded msg which contains headers and content and decodes it
     * @param  {String}  encodedMsg http encoded message
     * @return {Table}   decoded Table with keys headers and body
     */
    function _decode(encodedMsg) {
        local decoded = {};
        local headerEnd = encodedMsg.find("\n\n");
        local encodedHeader = encodedMsg.slice(0, headerEnd);
        local encodedBody = encodedMsg.slice(headerEnd + "\n\n".len());
        decoded.headers <- _parseHeaders(encodedHeader);
        decoded.body <- _parseBody(encodedBody, decoded.headers);
        return decoded;
    }


    /**
     * Takes a http encoded string of header key value pairs and converts to a table of
     * @param  {String} encodedHeader http encoded string of header key value pairs
     * @return {Table}  Table of header key value pairs 
     */
    function _parseHeaders(encodedHeader) {
        local headerArr = split(encodedHeader, "\n");
        local headers = {}
        foreach (i, header in headerArr) {
            local keyValArr = split(header, ":");
            keyValArr[0] = strip(keyValArr[0]);
            if (keyValArr[0].len() > 0) {
                headers[keyValArr[0].tolower()] <- strip(keyValArr[1]);
            }
        }
        return headers;
    }


    /**
     * Takes a http encoded string of the message body and a list of headers and parses the body based on Content-Type header.
     * @param  {String}   encodedBody http encoded string of header key value pairs
     * @param  {String}   encodedBody http encoded string of header key value pairs
     * @return {Table}    Table of header key value pairs 
     */
    function _parseBody(encodedBody, headers) {

        local body = encodedBody;
        if ("content-type" in headers && headers["content-type"] == "application/json") {
            try {
                body = http.jsondecode(encodedBody);
            } catch (e) {
                server.error(e)
            }
        }
        return body;
    }


    /**
     * Posts data payload to Conctr.
     * @param  {Table}      payload    Data to be sent to Conctr
     * @param  {String}     endpoint   Url to post to
     * @param  {Array}      ids        Ids of callbacks to device
     * @param  {Function}   callback   Optional callback for result
     */
    function _postToConctr(payload, endpoint, ids = [], callback = null) {

        if (typeof ids == "function") {
            callback = ids;
            ids = [];
        }

        local headers = {};
        headers["Content-Type"] <- "application/json";

        headers["Authorization"] <- _api_key;

        // Send the payload(s) to the endpoint
        if (_DEBUG) {
            server.log(format("Conctr: sending to %s", endpoint));
            server.log(format("Conctr: %s", http.jsonencode(payload)));
        }

        local request = http.post(endpoint, headers, http.jsonencode(payload));

        request.sendasync(function(response) {
            // Parse the response
            local success = (response.statuscode >= 200 && response.statuscode < 300);
            local body = null, error = null;

            // Parse out the body and the error if we can
            if (typeof response.body == "string" && response.body.len() > 0) {
                try {
                    body = http.jsondecode(response.body)

                    if ("error" in body) error = body.error;

                } catch (e) {
                    error = e;
                }
            }

            // If we have a failure but no error message, set it
            if (success == false && error == null) {
                error = "Http Status Code: " + response.statuscode;
            }


            if (_DEBUG) {
                if (error) server.error("Conctr Error: " + http.jsonencode(error));
                else if (body) server.log("Conctr: " + http.jsonencode(body));
            }

            if (error != null) {
                server.error("Conctr Error: " + error);
            }

            // Return the result to agent cb
            if (callback) {
                callback(error, body);
            }

            // Return the result to any device cb
            if (ids.len() > 0) {
                // Send the result back to the device
                local device_result = { "ids": ids, "body": body, "error": error };
                device.send(DATA_EVENT, device_result);
            }

        }.bindenv(this));
    }

    /**
     * Sends a request to the device to send its current location (array of wifis) if conditions in current location sending opts are met. 
     * Note: device will send through using its internal sendData function, we will not wait and send location within the current payload.
     *
     */
    function _getLocation() {

        if (!_locationRecording) {

            if (_DEBUG) {
                server.log("Conctr: location recording is not enabled");
            }

            // not recording location 
            return;

        } else {

            // check new location scan conditions are met and search for proximal wifi networks
            local now = time();
            if ((_locationSent == false) || ((_sendLocOnce == false) && (_locationTimeout - now < 0))) {

                if (_DEBUG) {
                    server.log("Conctr: requesting location from device");
                }

                // Update timeout 
                _locationTimeout = time() + _sendLocInterval;

                // Update flagg to show we sent location.
                _locationSent = true;

                // Request location from device
                device.send(LOCATION_REQ, "");

            } else {
                // Conditions for new location search (using wifi networks) not met
                return;
            }
        }
    }

    /**
     * Funtion to set location recording options
     * 
     * @param opts {Table} - location recording options 
     * {
     *   {Boolean}  sendLoc - Should location be sent with data
     *   {Integer}  sendLocInterval - Duration in seconds between location updates
     *   {Boolean}  sendLocOnce - Setting to true sends the location of the device only once when the device restarts 
     *  }
     *
     * NOTE: sendLoc takes precedence over sendLocOnce. Meaning if sendLoc is set to false location will never be sent 
     *       with the data until this flag is changed.
     */
    function _setLocationOpts(opts = {}) {

        if (_DEBUG) {
            server.log("Conctr: setting agent opts to: " + http.jsonencode(opts));
        }

        _sendLocInterval = ("sendLocInterval" in opts && opts.sendLocInterval != null) ? opts.sendLocInterval : DEFAULT_LOC_INTERVAL; // Set default sendLocInterval between location updates

        _sendLocOnce = ("sendLocOnce" in opts && opts.sendLocOnce != null) ? opts.sendLocOnce : false;
        _locationRecording = ("sendLoc" in opts && opts.sendLoc != null) ? opts.sendLoc : _locationRecording;
        _locationSent = false;
    }

    /**
     * Sets up endpoints for this agent
     * @param  {Object} rocky Instantiated instance of the Rocky class
     */
    function _setupAgentApi(rocky) {
        server.log("set up agent endpoints");
        rocky.post("/conctr/claim", _handleClaimReq.bindenv(this));
    }

    /**
     * Handles device claim response from Conctr
     * @param  {Object} context Rocky context
     */
    function _handleClaimReq(context) {


        if (!("consumer_jwt" in context.req.body)) {
            return _sendResponse(context, 401, { "error": "'consumer_jwt' is a required paramater for this request" });
        }

        _claimDevice(_app_id, _device_id, context.req.body.consumer_jwt, _region, _env, function(err, resp) {
            if (err != null) {
                return _sendResponse(context, 400, { "error": err });
            }
            server.log("Conctr: Device claimed");
            _sendResponse(context, 200, resp);
        });

    }

    /**
     * Send a response using rocky
     * 
     * @param  {Object}  context    Rocky context
     * @param  {Integer} code       Http status code to send 
     * @param  {Table}   obj        Data to send
     */
    function _sendResponse(context, code, obj = {}) {
        context.send(code, obj)
    }

    /**
     * Claims a device for a consumer
     *
     * @param  {String} appId
     * @param  {String} deviceId
     * @param  {String} consumer_jwt 
     * @param  {String} region
     * @param  {String} env
     * @param  {Function} cb
     */
    function _claimDevice(appId, deviceId, consumer_jwt, region, env, cb = null) {

        local _claimEndpoint = format("https://api.%s.conctr.com/admin/apps/%s/devices/%s/claim", env, appId, deviceId);
        local payload = {};

        payload["consumer_jwt"] <- consumer_jwt;

        _postToConctr(payload, _claimEndpoint, cb)
    }

    /**
     * Forms and returns the insert data API endpoint for the current device and Conctr application
     *
     * @param  {String} appId
     * @param  {String} deviceId
     * @param  {String} region
     * @param  {String} env
     * @return {String} url endpoint that will accept the data payload
     */
    function _formDataEndpointUrl(appId, deviceId, region, env) {

        // This is the temporary value of the data endpoint.
        return format("https://api.%s.conctr.com/data/apps/%s/devices/%s", env, appId, deviceId);

        // The data endpoint is made up of a region (e.g. us-west-2), an environment (production/core, staging, dev), an appId and a deviceId.
        // return format("https://api.%s.%s.conctr.com/data/apps/%s/devices/%s", region, env, appId, deviceId);
    }


    /**
     * Forms and returns the insert data API endpoint for the current device and Conctr application
     *
     * @param  {String} appId
     * @param  {String} apiKey
     * @param  {String} deviceId
     * @param  {String} region
     * @param  {String} env
     * @return {String} url endpoint that will accept the data payload
     */
    function _formPubSubEndpointUrls(appId, apiKey, deviceId, region, env) {

        local pubSubActions = ["subscribe", "publish"];
        local ngrokID = "92ed6e26";
        local endpoints = {};
        foreach (idx, action in pubSubActions) {
            if (!LOCAL_MODE) {
                endpoints[action] <- format("https://api.%s.conctr.com/comet/%s/%s/%s/%s", env, _protocol, action, appId, apiKey);
            } else {
                endpoints[action] <- format("http://%s.ngrok.io/comet/%s/%s/%s/%s", ngrokID, _protocol, action, appId, apiKey);
            }
            // The data endpoint is made up of a region (e.g. us-west-2), an environment (production/core, staging, dev), an appId and a deviceId.
            // return format("https://api.%s.%s.conctr.com/data/apps/%s/devices/%s", region, env, appId, deviceId);
        }
        return endpoints;
    }
}