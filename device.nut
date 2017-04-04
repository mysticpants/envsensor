// Import Libraries
#require "WS2812.class.nut:2.0.2"
#require "HTS221.class.nut:1.0.0"
#require "LPS22HB.class.nut:1.0.0"
#require "LIS3DH.class.nut:1.3.0"
//#require "conctr.device.class.nut:1.0.0"

//Debugging
#require "JSONEncoder.class.nut:1.0.0"
#require "PrettyPrinter.class.nut:1.0.1"



#include "conctr.device.nut"


// Constants
const LPS22HB_ADDR = 0xB8;
const LIS3DH_ADDR = 0x32;
const POLL_TIME = 900; 
const DEFAULT_POLLFREQ1 = 172800;
const DEFAULT_POLLFREQ2 = 86400
const DEFAULT_POLLFREQ3 = 18000;
const DEFAULT_POLLFREQ4 = 3600;
const DEFAULT_POLLFREQ5 = 900;
const VOLTAGE_VARIATION = 0.1;

class environmentSensor {
    currentReadings = null;
    pollRunning = false;
    configs = null;
    enabledLED = true;
    sleepTime = POLL_TIME;
    lowPowerMode = false;
    tapEnabled = true;
    tapSensitivity = 1.5;
    pollFreq1 = null;
    pollFreq2 = null;
    pollFreq3 = null;
    pollFreq4 = null;
    pollFreq5 = null;
    red = 0;
    blue = 0;
    green = 0;
    ledEnabled = null;
    localConfig = null;
    processesRunning = null;

    constructor() {
        currentReadings = {"pressure": null, "temperature": null, "humidity": null, "battery": null, "acceleration_x": null,"acceleration_y": null,"acceleration_z": null, "light": null}; 
        localConfig =  {"tapSensitivity": 2, 
                        "tapEnabled": true, 
                        "pollFreq1": DEFAULT_POLLFREQ1, 
                        "pollFreq2": DEFAULT_POLLFREQ2, 
                        "pollFreq3": DEFAULT_POLLFREQ3, 
                        "pollFreq4": DEFAULT_POLLFREQ4,
                        "pollFreq5": DEFAULT_POLLFREQ5,
                        "green": 1,
                        "blue": 1,
                        "ledBlueEnabled": true,
                        "ledGreenEnabled": true}; 
        processesRunning = 4;
    }

    function setConfig(remoteConfig) {
        if (remoteConfig == null) return;
        localConfig = remoteConfig;

        if (remoteConfig.tapEnabled == "true") {
            accel.configureClickInterrupt(false, LIS3DH.DOUBLE_CLICK, remoteConfig.tapSensitivity, 15, 10, 300);
        } else {
            // TODO: DISABLE interrupt
            //accel.configureClickInterrupt(true, LIS3DH.DOUBLE_CLICK, remoteConfig.tapSensitivity, 15, 10, 300); 
        }
        
        poll();
    }

    // Define a function to poll the pin every 0.1 seconds
    function poll() {        
        if (pollRunning) return;
        pollRunning = true;
        processesRunning = 4;
        
        accel.getAccel(function(val) {
            currentReadings.acceleration_x = val.x;
            currentReadings.acceleration_y = val.y;
            currentReadings.acceleration_z = val.z;
            server.log(format("Acceleration (G): (%0.2f, %0.2f, %0.2f)", val.x, val.y, val.z));

            decrementProcesses();
        }.bindenv(this));
        
        tempHumid.read(function(result) {
            if ("error" in result) {
                server.log("temphumiderror");
                server.error("An Error Occurred: " + result.error);
            } else {
                // This temp sensor has 0.5 accuracy so it is used for 0-40 degrees.
                currentReadings.temperature = result.temperature; 
                currentReadings.humidity = result.humidity;
                server.log(format("Current Humidity: %0.2f %s, Current Temperature: %0.2f °C", result.humidity, "%", result.temperature));
            }

            decrementProcesses();
        }.bindenv(this));
        
        pressureSensor.read(function(result) {
            if ("err" in result) {
                server.error("An Error Occurred: " + result.err);
            } else {
                // Note the temp sensor in the LPS22HB is only accurate to +-1.5 degrees. 
                // But it has an range of up to 65 degrees.
                // Hence it is used if temp is greater than 40.
                if (result.temperature > 40) currentReadings.temperature = result.temperature; 
                currentReadings.pressure = result.pressure;
                server.log(format("Current Pressure: %0.2f hPa, Current Temperature: %0.2f °C", result.pressure, result.temperature));
            }

            decrementProcesses();
        }.bindenv(this));        
        

        currentReadings.light = hardware.lightlevel()/65535.0*100;  
        server.log("Ambient Light: " + currentReadings.light + "%");   

        currentReadings.battery = getBattVoltage();  
        sleepTime = calcSleepTime(currentReadings.battery);         
       
        if (1) {
            //localConfig.ledBlueEnabled
            ledgreen.write(0); 
            ledblue.write(0); 
            // Debugging 
            hardware.pin1.configure(DIGITAL_OUT, 1);
            led.set(0, [0,255,255]).draw();

            imp.wakeup(1.0, function(){
                ledgreen.write(1); 
                ledblue.write(1); 
                // Debugging
                hardware.pin1.configure(DIGITAL_OUT, 0);

                decrementProcesses();
            }.bindenv(this));
        }

        
    }

    function postReadings() {
        agent.send("reading", currentReadings);
        wakepin.configure(DIGITAL_IN_WAKEUP);
        server.flush(3);
        server.sleepfor(sleepTime);
    }

    function getBattVoltage() {
        local firstRead = batt.read()/65535.0*hardware.voltage();
        local battVoltage = batt.read()/65535.0*hardware.voltage();
        local pollArray = [];
        if (math.abs(firstRead - battVoltage) < VOLTAGE_VARIATION) {
            return battVoltage;            
        } else {
            for (local i = 0; i<10; i++) {
                pollArray.append(batt.read()/65535.0*hardware.voltage());
            }
            return takeAverage(pollArray);
            server.log(currentReadings.battery);
        }
    }

    function decrementProcesses() {
        processesRunning--;
        if (processesRunning <= 0) {
            postReadings();
        }
    }

    function calcSleepTime(battVoltage) {
        local sleepTime;
        if (battVoltage < 0.8) {
            // Poll only once every two days
            sleepTime = localConfig.pollFreq1; 
            server.log("Battery Voltage Critical: " + battVoltage);
        } else if (battVoltage < 1.5) {
            // Poll only once every day
            sleepTime = localConfig.pollFreq2;
            server.log("Battery Voltage Low: " + battVoltage);
        } else if (battVoltage < 2.0) {
            // Poll only once every 5 hours
            sleepTime = localConfig.pollFreq3;        
            server.log("Battery Voltage Medium: " + battVoltage);
        } else if (battVoltage < 2.5) {
             // Poll only once an hour
            sleepTime = localConfig.pollFreq4;
            server.log("Battery Voltage High: " + battVoltage);
        } else {
            server.log("Battery Voltage Full: " + battVoltage);
            // Poll every 15 min
            sleepTime = localConfig.pollFreq5;
        }

        if (typeof sleepTime == "string") {
            sleepTime = sleepTime.tointeger();
        }

        // Min sleepTime of 10s, make sure we can't brick it.
        if (sleepTime < 10) sleepTime = 10;

        return sleepTime;
    }

    // function that returns an average of an array
    function takeAverage (array) {
        local sum = 0;
        local average = 0
        for (local i = 0; i < array.len(); i++) {
            sum += array[i];
        }
        average = sum/(array.len());
        return average
    }

}

// Globals
batt <- hardware.pin2;
batt.configure(ANALOG_IN);
wakepin <- hardware.pin1;
ledblue <- hardware.pin5;
ledgreen <- hardware.pin5;
ledblue.configure(DIGITAL_OUT, 1);
ledgreen.configure(DIGITAL_OUT, 1);
i2cpin <- hardware.i2c89;
i2cpin.configure(CLOCK_SPEED_400_KHZ);

accel <- LIS3DH(i2cpin, LIS3DH_ADDR);
accel.setDataRate(100);
accel.configureClickInterrupt(true, LIS3DH.DOUBLE_CLICK, 2, 15, 10, 300);
accel.configureInterruptLatching(true);
pressureSensor <- LPS22HB(i2cpin, LPS22HB_ADDR);
tempHumid <- HTS221(i2cpin);
tempHumid.setMode(HTS221_MODE.ONE_SHOT, 7);

conctr <- Conctr();
envSensor <- environmentSensor();

// DEBUGGING
pp <- PrettyPrinter(null, false);
print <- pp.print.bindenv(pp);
spi <- hardware.spi257;
spi.configure(MSB_FIRST, 7500);
led <- WS2812(spi, 1);



agent.on("config", function(config){
    envSensor.setConfig(config);
});
agent.send("ready", "ready");



