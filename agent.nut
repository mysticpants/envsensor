#require "Rocky.class.nut:1.3.0"
#require "PrettyPrinter.class.nut:1.0.1"

#include "libs/conctr.agent.nut"
#include "include/configPage.html"
#include "include/conctr_api_key.nut"

const DEFAULT_POLLFREQ1 = 172800;
const DEFAULT_POLLFREQ2 = 86400
const DEFAULT_POLLFREQ3 = 18000;
const DEFAULT_POLLFREQ4 = 3600;
const DEFAULT_POLLFREQ5 = 900;

class environmentSensor {
	savedData = {};

	constructor() {
		savedData = {"temperature": null,
				 "humidity": null,
				 "pressure": null,
				 "battery": null,
				 "acceleration_x": null,
				 "acceleration_y": null,
				 "acceleration_z": null,
				 "tapSensitivity": 2,
				 "tapEnabled": true,
				 "pollFreq1": DEFAULT_POLLFREQ1,
				 "pollFreq2": DEFAULT_POLLFREQ2,
				 "pollFreq3": DEFAULT_POLLFREQ3,
				 "pollFreq4": DEFAULT_POLLFREQ4,
				 "pollFreq5": DEFAULT_POLLFREQ5,
				 "blue": 1,
				 "green": 1,
				 "ledBlueEnabled": true,
				 "ledGreenEnabled": true}; 

		//server.save(savedData);
		if (backup.len() != 0) {
		    savedData = backup;
		} else {
		    local result = server.save(savedData);
		    if (result != 0) server.error("Could not back up data");
		}
	}
	
	function postReading(reading) {
		// Sends reading to Conctr
		conctr.sendData(reading, function(error,response) {
            server.log("Conct Data Sent");
            if(error) {
                server.error(error); 
            } else {
                server.log(response.statusCode); 
            }
        }.bindenv(this));
	}


}



// START OF PROGRAM
api <- Rocky();
pp <- PrettyPrinter(null, false);
print <- pp.print.bindenv(pp);
conctr <- Conctr(APP_ID, API_KEY, MODEL,api);
backup <- server.load();


envSens <- environmentSensor();


// Set up the agent API
api.get("/", function(context) {
    // Root request: just return standard web page HTML string
    context.send(200, format(htmlString, http.agenturl(), http.agenturl()));
});

api.get("/state", function(context) {
    // Request for data from /state endpoint
    context.send(200, { 
    	temperature = envSens.savedData.temperature, 
    	humidity = envSens.savedData.humidity, 
    	pressure = envSens.savedData.pressure, 
    	battery = envSens.savedData.battery, 
    	tapSensitivity = envSens.savedData.tapSensitivity, 
    	tapEnabled = envSens.savedData.tapEnabled, 
    	pollFreq1 = envSens.savedData.pollFreq1,
	    pollFreq2 = envSens.savedData.pollFreq2, 
	    pollFreq3 = envSens.savedData.pollFreq3, 
	    pollFreq4 = envSens.savedData.pollFreq4, 
	    pollFreq5 = envSens.savedData.pollFreq5,  
	    blue = envSens.savedData.blue, 
	    green = envSens.savedData.green 
	    ledBlueEnabled = envSens.savedData.ledBlueEnabled,
	    ledGreenEnabled = envSens.savedData.ledGreenEnabled
	    });
});

api.post("/config", function(context) {
    // Config submission at the /config endpoint
    local data = http.jsondecode(context.req.rawbody);    
    envSens.savedData.tapSensitivity = data.tapSensitivity.tointeger();
    envSens.savedData.tapEnabled = data.tapEnabled;
    envSens.savedData.pollFreq1 = data.pollFreq1.tointeger();
    envSens.savedData.pollFreq2 = data.pollFreq2.tointeger();
    envSens.savedData.pollFreq3 = data.pollFreq3.tointeger();
    envSens.savedData.pollFreq4 = data.pollFreq4.tointeger();
    envSens.savedData.pollFreq5 = data.pollFreq5.tointeger();
    envSens.savedData.blue = data.blue.tointeger();
    envSens.savedData.green = data.green.tointeger();
    envSens.savedData.ledBlueEnabled = data.ledBlueEnabled;
    envSens.savedData.ledGreenEnabled = data.ledGreenEnabled;     
    local result = server.save(envSens.savedData);
    if (result != 0) server.error("Could not back up data");
    context.send(200, "OK");
});

// Register the function to handle data messages from the device. Send Ready.
device.on("reading", envSens.postReading);
device.on("ready", function(msg) {    
    device.send("config", envSens.savedData);
});


