// Copyright (c) 2017 Mystic Pants Pty Ltd
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT

#require "Rocky.class.nut:1.3.0"
#require "PrettyPrinter.class.nut:1.0.1"

#include "libs/conctr.agent.nut"
#include "include/configPage.html"
#include "include/conctr_api_key.nut"
#include "include/defaults.nut"

const DEFAULT_POLLFREQ1 = 172800;
const DEFAULT_POLLFREQ2 = 86400
const DEFAULT_POLLFREQ3 = 18000;
const DEFAULT_POLLFREQ4 = 3600;
const DEFAULT_POLLFREQ5 = 900;

class environmentSensor {

    _savedData = null;
    _rocky = null;

    constructor(rocky) {

    	_rocky = rocky;

        local initialData = server.load();
        if (!("temperature" in initialData)) {

            // Set the default values and save them to persistant storage
            _savedData = {
                reading = {
                    "temperature": null,
                    "humidity": null,
                    "pressure": null,
                    "battery": null,
                    "acceleration_x": null,
                    "acceleration_y": null,
                    "acceleration_z": null
                },

                config = {

                    "pollFreq1": DEFAULT_POLLFREQ1,
                    "pollFreq2": DEFAULT_POLLFREQ2,
                    "pollFreq3": DEFAULT_POLLFREQ3,
                    "pollFreq4": DEFAULT_POLLFREQ4,
                    "pollFreq5": DEFAULT_POLLFREQ5,
                    "ledBlueEnabled": true,
                    "ledGreenEnabled": true,
                    "green": 0,
                    "blue": 0,
                    "tapSensitivity": 2,
                    "tapEnabled": true
                }
            }
            server.save(_savedData);

        } else {

            _savedData = initialData;

        }

		// Set up the agent API - just return standard web page HTML string
		_rocky.get("/", function(context) {
		    context.send(200, format(htmlString, http.agenturl(), http.agenturl()));
		});

		    // Request for data from /state endpoint
		_rocky.get("/state", function(context) {
		    context.send(200, _savedData);
		});

		// Config submission at the /config endpoint
		_rocky.post("/config", function(context) {		 
		    setConfig(context.req.body)
		    context.send(200, "OK");
		});

		// The device is online and ready
		device.on("ready", function(msg) {
		    device.send("config", _savedData);
		});

		// Register the function to handle data messages from the device. Send Ready.
		device.on("reading", postReading.bindenv(this));		

    }


    // Updates the in-memory and persistant data table
    function setConfig(newconfig) {
        if (typeof newconfig == "table") {
            foreach (k, v in newconfig) {
            	if (typeof v == "string") {
            		if (v.tolower() == "true") v = true;
            		else (v.tolower() == "false") v = false;
            		else v = v.tointeger();
            	}
                _savedData.config[k] <- v;
            }
            return server.save(_savedData);
        } else {
            return false;
        }
    }


    // Send readings to Conctr
    function postReading(reading) {
        conctr.sendData(reading, function(err, response) {
            if (err) {
                server.error("Conctr sendData: " + err);
            } else {
                server.log("Conctr data sent: " + response.statusCode);
            }
        }.bindenv(this));
    }


}



// START OF PROGRAM
rocky <- Rocky();
pp <- PrettyPrinter(null, false);
print <- pp.print.bindenv(pp);
conctr <- Conctr(APP_ID, API_KEY, MODEL, api);
envSensor <- environmentSensor(rocky);

